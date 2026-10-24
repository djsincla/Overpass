import CoreLocation
import Foundation
import Observation
import SkyKit

/// Everything the user can set, saved between launches.
struct Settings: Codable, Equatable {
    var latitude: Double = 0
    var longitude: Double = 0
    var heightMeters: Double = 0
    var hasLocation = false
    var refraction = true

    var minimumAltitude: Double = 0
    var darkSkySunAltitude: Double = -6

    var cableStopAzimuth: Double = 0
    var cableMargin: Double = 5
    /// Above 90 allows pointing over the top.
    var maximumAltitudeAxis: Double = 90
    var maximumAzimuthRate: Double = 6
    var maximumAltitudeRate: Double = 6
    var pointingTolerance: Double = 0.1

    var observer: Observer {
        Observer(latitude: latitude, longitude: longitude, height: heightMeters, refraction: refraction)
    }

    var limits: MountLimits {
        var l = MountLimits()
        l.cableStopAzimuth = cableStopAzimuth
        l.cableMargin = cableMargin
        l.maximumAltitudeAxis = maximumAltitudeAxis
        l.maximumAzimuthRate = maximumAzimuthRate
        l.maximumAltitudeRate = maximumAltitudeRate
        return l
    }

    var planner: MountPlanner {
        var p = MountPlanner(limits: limits)
        p.tolerance = pointingTolerance
        return p
    }
}

/// The pass list filter, saved between launches.
struct FilterSettings: Codable, Equatable {
    var hoursAhead: Double = 24
    var minimumMaxAltitude: Double = 10
    var minimumDurationMinutes: Double = 0
    var visibleOnly = false
    var trackableOnly = false
    var maximumSecondsOffTarget: Double = 0
    var minimumSunSeparation: Double = 0
    var search = ""
    var sort = Sort.startTime

    enum Sort: String, Codable, CaseIterable, Identifiable {
        case startTime = "Start time", maxAltitude = "Highest", duration = "Longest"
        var id: Self { self }
        var passSort: PassSort {
            switch self {
            case .startTime: .startTime
            case .maxAltitude: .maxAltitude
            case .duration: .duration
            }
        }
    }
}

@MainActor @Observable
final class AppModel {
    var settings: Settings { didSet { save(settings, "settings"); if settings != oldValue { schedulePrediction() } } }
    var filter: FilterSettings { didSet { save(filter, "filter"); if filter != oldValue { schedulePrediction() } } }

    private(set) var sources: [TLESource] = []
    private(set) var sourceStatus: [String: TLESourceStatus] = [:]
    private(set) var satellites: [SatelliteTarget] = []
    private(set) var passes: [SatellitePass] = []
    private(set) var isPredicting = false
    private(set) var isRefreshing = false
    var message: String?

    private var catalog: TLECatalog?
    private var predictionTask: Task<Void, Never>?
    private let locationManager = CLLocationManager()

    /// The app's own folder. Sandboxed builds get a private container anyway; this keeps
    /// unsigned development builds out of the shared Application Support folder.
    static let storage = URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "Overpass")

    init() {
        settings = Self.load("settings") ?? Settings()
        filter = Self.load("filter") ?? FilterSettings()
        do {
            let dir = Self.storage.appending(path: "TLE")
            catalog = try TLECatalog(directory: dir)
        } catch {
            message = "Couldn't open the TLE cache: \(error.localizedDescription)"
        }
    }

    func start() async {
        await reloadFromCatalog()
        schedulePrediction()
        await refreshDue()
    }

    // MARK: TLE sources

    func refreshDue() async {
        guard let catalog else { return }
        isRefreshing = true
        await catalog.refreshDue()
        isRefreshing = false
        await reloadFromCatalog()
        schedulePrediction()
    }

    func refresh(_ id: String) async {
        guard let catalog else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await catalog.refresh(id)
        } catch TLECatalogError.tooSoon(let next) {
            message = "CelesTrak asks for at least 2 hours between downloads. Try again after \(next.formatted(date: .omitted, time: .shortened))."
        } catch {
            message = "Refresh failed: \(error.localizedDescription)"
        }
        await reloadFromCatalog()
        schedulePrediction()
    }

    func setEnabled(_ id: String, _ enabled: Bool) async {
        try? await catalog?.setEnabled(id, enabled)
        await reloadFromCatalog()
        // A newly enabled source with no cache needs downloading.
        if enabled, sourceStatus[id]?.lastRefreshed == nil { await refresh(id) }
        schedulePrediction()
    }

    func addSource(name: String, url: URL) async {
        let source = TLESource(id: "url-\(UUID().uuidString)", name: name, url: url)
        try? await catalog?.add(source)
        await refresh(source.id)
    }

    func removeSource(_ id: String) async {
        try? await catalog?.remove(id)
        await reloadFromCatalog()
        schedulePrediction()
    }

    /// Copies the picked file into the app's own storage first, so it can be re-read later
    /// without holding on to a security-scoped bookmark.
    func importFile(_ url: URL) async {
        guard let catalog else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let dir = Self.storage.appending(path: "Imported")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let copy = dir.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
            try FileManager.default.copyItem(at: url, to: copy)
            _ = try await catalog.importFile(copy, name: url.deletingPathExtension().lastPathComponent)
        } catch {
            message = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
        }
        await reloadFromCatalog()
        schedulePrediction()
    }

    private func reloadFromCatalog() async {
        guard let catalog else { return }
        sources = await catalog.sources
        sourceStatus = await catalog.status
        satellites = await catalog.satellites
    }

    // MARK: Prediction

    /// Debounced, so dragging a slider doesn't start a prediction per step.
    func schedulePrediction() {
        predictionTask?.cancel()
        predictionTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await predict()
        }
    }

    private func predict() async {
        guard settings.hasLocation, !satellites.isEmpty else {
            passes = []
            return
        }
        isPredicting = true
        defer { isPredicting = false }

        var predictor = PassPredictor(observer: settings.observer)
        predictor.minimumAltitude = settings.minimumAltitude
        predictor.darkSkySunAltitude = settings.darkSkySunAltitude

        var f = PassFilter()
        f.minimumMaxAltitude = filter.minimumMaxAltitude
        f.minimumDuration = filter.minimumDurationMinutes * 60
        f.visibility = filter.visibleOnly ? .visibleOnly : .any
        f.minimumSunSeparation = filter.minimumSunSeparation > 0 ? filter.minimumSunSeparation : nil
        f.nameContains = filter.search
        if filter.trackableOnly {
            f.mountPlanner = settings.planner
            f.maximumSecondsOffTarget = filter.maximumSecondsOffTarget
        }

        let now = Date.now
        // Include passes already in progress.
        let result = await predictor.passes(of: satellites, from: now - 15 * 60, to: now + filter.hoursAhead * 3600,
                                            filter: f, sort: filter.sort.passSort)
        guard !Task.isCancelled else { return }
        passes = result.filter { $0.end.date > now }
    }

    func plan(for pass: SatellitePass) -> MountPlan? {
        settings.planner.plan(pass.track)
    }

    // MARK: Location

    func useCurrentLocation() async {
        locationManager.requestWhenInUseAuthorization()
        do {
            for try await update in CLLocationUpdate.liveUpdates() {
                if let location = update.location {
                    settings.latitude = location.coordinate.latitude
                    settings.longitude = location.coordinate.longitude
                    settings.heightMeters = location.altitude
                    settings.hasLocation = true
                    return
                }
            }
        } catch {
            message = "Couldn't get your location: \(error.localizedDescription)"
        }
    }

    // MARK: Persistence

    private func save(_ value: some Encodable, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
