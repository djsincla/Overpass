import CoreLocation
import Foundation
import Observation
import SkyKit

enum ConnectionKind: String, Codable, CaseIterable, Identifiable {
    /// The mount's own WiFi: the normal command set. Passive and Step tracking.
    case wifi = "WiFi (Normal mode)"
    /// The mount's USB port: Special mode. Smooth tracking. On iPhone/iPad, via a TCP relay.
    case usb = "USB (Special mode)"
    var id: Self { self }
}

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

    var connection = ConnectionKind.wifi
    /// iOptron's WiFi defaults; check your mount's manual.
    var wifiHost = "10.10.100.254"
    var wifiPort = 8899
    /// Mac: the USB serial device.
    var serialPath = ""
    /// iPhone/iPad: the relay on the mount's USB port.
    var relayHost = "raspberrypi.local"
    var relayPort = 2000
    /// Special mode survives power cycles; leaving it on would stop WiFi working next time.
    var leaveSpecialModeOnDisconnect = true

    /// Night vision: the whole app in red on black, to keep dark adaptation at the eyepiece.
    var redMode = false
    /// iPhone/iPad: switch the home-screen icon to the red one as well.
    var redAppIcon = false

    var stepInterval: Double = 2
    /// From star alignment; Smooth tracking needs it.
    var alignment: AlignmentModel?
    var alignmentRMS: Double?
    var alignmentStars = 0

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
        var p = MountPlanner(limits: limits, model: alignment ?? AlignmentModel())
        p.tolerance = pointingTolerance
        return p
    }
}

/// Which passes to show, saved between launches. Which satellites is the selection.
struct FilterSettings: Codable, Equatable {
    var hoursAhead: Double = 24
    var minimumMaxAltitude: Double = 10
    var minimumDurationMinutes: Double = 0
    var visibleOnly = false
    /// Hide passes spent entirely in the Earth's shadow, and satellites in shadow right now.
    var hideEclipsed = false
    var trackableOnly = false
    var maximumSecondsOffTarget: Double = 0
    var minimumSunSeparation: Double = 0
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

struct SourceGroup: Identifiable {
    let source: TLESource
    let status: TLESourceStatus?
    let satellites: [SatelliteTarget]
    var id: String { source.id }

    /// Median element-set age; the honest single number for "how fresh is this source".
    var medianAge: TimeInterval? {
        let ages = satellites.map { $0.elementAge() }.sorted()
        return ages.isEmpty ? nil : ages[ages.count / 2]
    }
}

struct LiveObject: Identifiable {
    let id: String
    let name: String
    let position: Horizontal
    let sunlit: Bool
}

@MainActor @Observable
final class AppModel {
    var settings: Settings { didSet { save(settings, "settings"); if settings != oldValue { schedulePrediction() } } }
    var filter: FilterSettings { didSet { save(filter, "filter"); if filter != oldValue { schedulePrediction() } } }
    /// SkyObject ids ("sat:25544", "body:moon", "star:Vega"). Predictions and highlights follow these.
    var selected: Set<String> { didSet { save(Array(selected), "selectedObjects"); if selected != oldValue { schedulePrediction() } } }

    /// The pass drawn on the dome (satellite and rise time); nil means the next one.
    private var highlightedPassKey: (noradID: String, start: Date)?
    /// The object ringed on the dome. Highlighting never moves the mount.
    var highlightedObjectID: String?

    /// What the mount will track: set deliberately, and locked while tracking runs, so clicking
    /// around the sky can never redirect the mount.
    private(set) var targetObjectID: String?
    /// For a satellite, the pass being tracked: its satellite and rise time. Pass ids include the
    /// rise time to the second, which can shift slightly when predictions rerun, so match loosely.
    private(set) var targetPassKey: (noradID: String, start: Date)?
    var targetPassID: String? { targetPass?.id }

    private(set) var sources: [TLESource] = []
    private(set) var sourceStatus: [String: TLESourceStatus] = [:]
    private(set) var groups: [SourceGroup] = []
    private(set) var satellites: [SatelliteTarget] = []
    private var satelliteByID: [String: SatelliteTarget] = [:]
    private(set) var passes: [SatellitePass] = []
    private(set) var isPredicting = false
    private(set) var isRefreshing = false
    var message: String?

    let mount = MountSession()

    private var catalog: TLECatalog?
    private var predictionTask: Task<Void, Never>?
    private let locationManager = CLLocationManager()

    /// The app's own folder. Sandboxed builds get a private container anyway; this keeps
    /// unsigned development builds out of the shared Application Support folder.
    static let storage = URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "Overpass")

    init() {
        settings = Self.load("settings", default: Settings())
        filter = Self.load("filter", default: FilterSettings())
        selected = Set(Self.load("selectedObjects", default: [String]()))
        do {
            catalog = try TLECatalog(directory: Self.storage.appending(path: "TLE"))
        } catch {
            message = "Couldn't open the TLE cache: \(error.localizedDescription)"
        }
        mount.app = self
    }

    func start() async {
        await reloadFromCatalog()
        schedulePrediction()
        await refreshDue()
    }

    // MARK: Objects and selection

    func object(_ id: String) -> SkyObject? {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "sat": return satelliteByID[parts[1]].map(SkyObject.satellite)
        case "body": return SolarSystemBody(rawValue: parts[1]).map(SkyObject.body)
        case "star": return BrightStars.all.first { $0.name == parts[1] }.map(SkyObject.star)
        default: return nil
        }
    }

    var selectedObjects: [SkyObject] { selected.compactMap(object).sorted { $0.name < $1.name } }

    func isSelected(_ id: String) -> Bool { selected.contains(id) }

    func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    var highlightedObject: SkyObject? {
        highlightedObjectID.flatMap(object) ?? highlightedPass(at: .now).flatMap { object("sat:\($0.noradID)") }
    }

    /// The highlighted pass if it hasn't finished, otherwise the next one.
    func highlightedPass(at date: Date) -> SatellitePass? {
        if let key = highlightedPassKey,
           let pass = passes.first(where: { $0.noradID == key.noradID && abs($0.start.date.timeIntervalSince(key.start)) < 60 }),
           pass.end.date > date { return pass }
        return passes.filter { $0.end.date > date }.min { $0.start.date < $1.start.date }
    }

    func highlight(pass: SatellitePass) {
        highlightedPassKey = (pass.noradID, pass.start.date)
        highlightedObjectID = "sat:\(pass.noradID)"
    }

    /// Highlights an object, and for a satellite its next pass.
    func highlight(objectID: String) {
        highlightedObjectID = objectID
        if objectID.hasPrefix("sat:"), let pass = passes.first(where: { "sat:\($0.noradID)" == objectID && $0.end.date > .now }) {
            highlightedPassKey = (pass.noradID, pass.start.date)
        }
    }

    var targetObject: SkyObject? { targetObjectID.flatMap(object) }

    var targetPass: SatellitePass? {
        guard let key = targetPassKey else { return nil }
        return passes.first { $0.noradID == key.noradID && abs($0.start.date.timeIntervalSince(key.start)) < 60 }
    }

    /// Locks in the highlighted object (and its pass) as the tracking target. Refused while tracking.
    func setTargetFromHighlight() {
        guard !mount.isTracking, let object = highlightedObject else { return }
        targetObjectID = object.id
        if case .satellite(let s) = object {
            let highlighted = highlightedPass(at: .now)
            let pass = highlighted?.noradID == s.noradID ? highlighted
                : passes.first { $0.noradID == s.noradID && $0.end.date > .now }
            targetPassKey = pass.map { ($0.noradID, $0.start.date) }
        } else {
            targetPassKey = nil
        }
    }

    func setTarget(pass: SatellitePass) {
        guard !mount.isTracking else { return }
        targetObjectID = "sat:\(pass.noradID)"
        targetPassKey = (pass.noradID, pass.start.date)
    }

    func clearTarget() {
        guard !mount.isTracking else { return }
        targetObjectID = nil
        targetPassKey = nil
    }

    /// The pass a satellite is on now, or its next one.
    func currentOrNextPass(_ noradID: String, at date: Date) -> SatellitePass? {
        passes.filter { $0.noradID == noradID && $0.end.date > date }.min { $0.start.date < $1.start.date }
    }

    /// Selected objects currently above the horizon.
    func liveObjects(at date: Date) -> [LiveObject] {
        let observer = settings.observer
        let time = AstroTime(date)
        return selectedObjects.compactMap { object in
            guard let h = try? observer.look(at: object.target, time), h.altitude > 0 else { return nil }
            let sunlit: Bool = if case .satellite(let s) = object { (try? s.isSunlit(at: time)) ?? false } else { true }
            return LiveObject(id: object.id, name: object.name, position: h, sunlit: sunlit)
        }
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

    func refreshAll() async {
        for source in sources where source.enabled { await refresh(source.id) }
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
        satelliteByID = Dictionary(satellites.map { ($0.noradID, $0) }, uniquingKeysWith: { a, _ in a })
        var built: [SourceGroup] = []
        for source in sources {
            built.append(SourceGroup(source: source, status: sourceStatus[source.id],
                                     satellites: source.enabled ? await catalog.satellites(in: source.id) : []))
        }
        groups = built
    }

    // MARK: Prediction

    /// Selected satellites: passes are only predicted for what the user picked.
    var predictionTargets: [SatelliteTarget] {
        selected.compactMap { id in id.hasPrefix("sat:") ? satelliteByID[String(id.dropFirst(4))] : nil }
    }

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
        let targets = predictionTargets
        guard settings.hasLocation, !targets.isEmpty else {
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
        f.excludeEclipsed = filter.hideEclipsed
        f.minimumSunSeparation = filter.minimumSunSeparation > 0 ? filter.minimumSunSeparation : nil
        if filter.trackableOnly {
            f.mountPlanner = settings.planner
            f.maximumSecondsOffTarget = filter.maximumSecondsOffTarget
        }

        let now = Date.now
        // Include passes already in progress.
        let result = await predictor.passes(of: targets, from: now - 15 * 60, to: now + filter.hoursAhead * 3600,
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

    /// Loads saved values over the defaults, so a newer app version with extra settings
    /// keeps everything the user already set instead of resetting it.
    private static func load<T: Codable>(_ key: String, default value: T) -> T {
        guard let stored = UserDefaults.standard.data(forKey: key) else { return value }
        if let decoded = try? JSONDecoder().decode(T.self, from: stored) { return decoded }
        guard var base = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value))) as? [String: Any],
              let saved = (try? JSONSerialization.jsonObject(with: stored)) as? [String: Any] else { return value }
        base.merge(saved) { _, new in new }
        guard let merged = try? JSONSerialization.data(withJSONObject: base) else { return value }
        return (try? JSONDecoder().decode(T.self, from: merged)) ?? value
    }
}
