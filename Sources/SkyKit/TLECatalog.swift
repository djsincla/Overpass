import Foundation

/// Where element sets come from.
public struct TLESource: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// http(s) for downloads, file:// for local databases.
    public var url: URL
    /// How often to refresh automatically; nil means only when asked (e.g. local files).
    public var refreshInterval: TimeInterval?
    public var enabled: Bool

    public init(id: String, name: String, url: URL, refreshInterval: TimeInterval? = 12 * 3600, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.url = url
        self.refreshInterval = refreshInterval
        self.enabled = enabled
    }

    public static func celesTrak(_ group: String, name: String, enabled: Bool = false) -> TLESource {
        TLESource(id: "celestrak-\(group)", name: name, url: CelesTrak.groupURL(group), enabled: enabled)
    }

    /// Common CelesTrak groups. "visual" is on by default: the ~150 brightest, best for visual tracking.
    public static let builtIn: [TLESource] = [
        .celesTrak("visual", name: "Brightest (visual)", enabled: true),
        .celesTrak("stations", name: "Space stations", enabled: true),
        .celesTrak("last-30-days", name: "Launched in the last 30 days"),
        .celesTrak("science", name: "Science"),
        .celesTrak("weather", name: "Weather"),
        .celesTrak("amateur", name: "Amateur radio"),
        .celesTrak("starlink", name: "Starlink"),
        .celesTrak("gps-ops", name: "GPS"),
        .celesTrak("geo", name: "Geostationary"),
        .celesTrak("active", name: "All active satellites (large)"),
    ]
}

public struct TLESourceStatus: Codable, Sendable {
    public var lastRefreshed: Date?
    public var satelliteCount: Int = 0
    public var lastError: String?
}

public enum TLECatalogError: Error, Equatable {
    /// The download contained no element sets (CelesTrak answers bad requests with plain text).
    case noElementSets(String)
    case http(Int)
    /// CelesTrak asks clients not to download the same data more than once every 2 hours.
    case tooSoon(nextAllowed: Date)
}

/// A satellite and the sources that list it.
public struct CatalogEntry: Sendable {
    public let satellite: SatelliteTarget
    public var sourceIDs: Set<String>
    /// The source whose elements are in use: the newest of those that list it.
    public var sourceID: String
}

/// Loads, caches and refreshes TLE databases, merging them by catalogue number.
public actor TLECatalog {
    /// Minimum spacing between downloads of the same source.
    public static let minimumRefreshInterval: TimeInterval = 2 * 3600

    public typealias Fetcher = @Sendable (URL) async throws -> Data

    private let directory: URL
    private let fetch: Fetcher
    public private(set) var sources: [TLESource]
    public private(set) var status: [String: TLESourceStatus] = [:]
    /// Keyed by NORAD catalogue number; the newest epoch wins.
    public private(set) var entries: [String: CatalogEntry] = [:]
    private var bySource: [String: [SatelliteTarget]] = [:]

    public init(directory: URL, defaultSources: [TLESource] = TLESource.builtIn, fetch: Fetcher? = nil) throws {
        self.directory = directory
        self.fetch = fetch ?? Self.download
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let decoder = JSONDecoder()
        let loaded = (try? decoder.decode([TLESource].self, from: Data(contentsOf: directory.appending(path: "sources.json"))))
            ?? defaultSources
        var cached: [String: [SatelliteTarget]] = [:]
        for source in loaded {
            if let text = try? String(contentsOf: directory.appending(path: "\(source.id).tle"), encoding: .utf8) {
                cached[source.id] = TLEParser.parse(text)
            }
        }
        sources = loaded
        bySource = cached
        status = (try? decoder.decode([String: TLESourceStatus].self,
                                      from: Data(contentsOf: directory.appending(path: "status.json")))) ?? [:]
        entries = Self.merge(loaded, cached)
    }

    static func download(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw TLECatalogError.http(http.statusCode) }
        return data
    }

    public var satellites: [SatelliteTarget] {
        entries.values.map(\.satellite).sorted { $0.name < $1.name }
    }

    public func satellites(in sourceID: String) -> [SatelliteTarget] {
        entries.values.filter { $0.sourceIDs.contains(sourceID) }.map(\.satellite).sorted { $0.name < $1.name }
    }

    // MARK: Sources

    public func add(_ source: TLESource) throws {
        sources.removeAll { $0.id == source.id }
        sources.append(source)
        try save()
    }

    public func remove(_ id: String) throws {
        sources.removeAll { $0.id == id }
        bySource[id] = nil
        status[id] = nil
        try? FileManager.default.removeItem(at: cacheFile(id))
        entries = Self.merge(sources, bySource)
        try save()
    }

    public func setEnabled(_ id: String, _ enabled: Bool) throws {
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[i].enabled = enabled
        entries = Self.merge(sources, bySource)
        try save()
    }

    /// Imports a local TLE file (e.g. from Space-Track or another program) as a source.
    public func importFile(_ file: URL, name: String) async throws -> TLESource {
        let source = TLESource(id: "file-\(UUID().uuidString)", name: name, url: file, refreshInterval: nil)
        try await refresh(source, store: true)
        try add(source)
        return source
    }

    // MARK: Refreshing

    /// Refreshes enabled sources that are due. Failures are recorded per source, not thrown,
    /// so one bad source doesn't stop the rest; cached data is kept on failure.
    public func refreshDue(now: Date = .now) async {
        for source in sources where source.enabled {
            guard let interval = source.refreshInterval else { continue }
            let last = status[source.id]?.lastRefreshed ?? .distantPast
            if now.timeIntervalSince(last) >= max(interval, Self.minimumRefreshInterval) {
                try? await refresh(source.id, now: now)
            }
        }
    }

    public func refresh(_ id: String, now: Date = .now) async throws {
        guard let source = sources.first(where: { $0.id == id }) else { return }
        if source.url.isFileURL == false, let last = status[id]?.lastRefreshed,
           now.timeIntervalSince(last) < Self.minimumRefreshInterval {
            throw TLECatalogError.tooSoon(nextAllowed: last + Self.minimumRefreshInterval)
        }
        try await refresh(source, store: false, now: now)
    }

    private func refresh(_ source: TLESource, store: Bool, now: Date = .now) async throws {
        var s = status[source.id] ?? TLESourceStatus()
        do {
            let data = try await fetch(source.url)
            let text = String(decoding: data, as: UTF8.self)
            let satellites = TLEParser.parse(text)
            guard !satellites.isEmpty else {
                throw TLECatalogError.noElementSets(String(text.prefix(200)))
            }
            try data.write(to: cacheFile(source.id), options: .atomic)
            bySource[source.id] = satellites
            s.lastRefreshed = now
            s.satelliteCount = satellites.count
            s.lastError = nil
            status[source.id] = s
            entries = Self.merge(sources + (store ? [source] : []), bySource)
            try save()
        } catch {
            s.lastError = "\(error)"
            status[source.id] = s
            try? save()
            throw error
        }
    }

    // MARK: Storage

    private func cacheFile(_ id: String) -> URL { directory.appending(path: "\(id).tle") }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        try encoder.encode(sources).write(to: directory.appending(path: "sources.json"), options: .atomic)
        try encoder.encode(status).write(to: directory.appending(path: "status.json"), options: .atomic)
    }

    static func merge(_ sources: [TLESource], _ bySource: [String: [SatelliteTarget]]) -> [String: CatalogEntry] {
        var merged: [String: CatalogEntry] = [:]
        for source in sources where source.enabled {
            for sat in bySource[source.id] ?? [] {
                if var existing = merged[sat.noradID] {
                    existing.sourceIDs.insert(source.id)
                    merged[sat.noradID] = sat.epoch > existing.satellite.epoch
                        ? CatalogEntry(satellite: sat, sourceIDs: existing.sourceIDs, sourceID: source.id) : existing
                } else {
                    merged[sat.noradID] = CatalogEntry(satellite: sat, sourceIDs: [source.id], sourceID: source.id)
                }
            }
        }
        return merged
    }
}

extension SatelliteTarget {
    /// How old the element set is. LEO predictions drift noticeably after 2–3 days.
    public func elementAge(at date: Date = .now) -> TimeInterval { date.timeIntervalSince(epoch) }
}
