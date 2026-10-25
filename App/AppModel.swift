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
    /// Dark appearance regardless of the system setting: a bright screen ruins night vision.
    var alwaysDark = false
    /// iPhone/iPad: switch the home-screen icon to the red one as well.
    var redAppIcon = false

    /// Tracking starts (and "Move to start" waits) where a pass first reaches this elevation.
    var trackingStartAltitude: Double = 10

    var stepInterval: Double = 2
    /// From star alignment; Smooth tracking needs it.
    var alignment: AlignmentModel?
    var alignmentRMS: Double?
    var alignmentStars = 0
    /// The alignment was captured from the mount's own (Normal mode) alignment when connecting.
    var alignmentFromMount = false
    /// On USB connect, take the mount's existing alignment rather than needing a star alignment.
    var captureMountAlignment = true

    /// Camera guiding: which camera, and how its image moves with the mount.
    var cameraDeviceID: String?
    var cameraCalibration: CameraCalibration?

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
    /// How the Observe screen's object list is ordered.
    var objectSort = ObjectSort.riseTime

    enum ObjectSort: String, Codable, CaseIterable, Identifiable {
        case name = "Name", riseTime = "Rise time", brightness = "Brightness"
        var id: Self { self }
    }

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

    /// The time bar: how far the dome, the lists and tracking are moved from now (±2 days).
    /// Sync and alignment always use real time.
    var timeShift: TimeInterval = 0 {
        didSet { if timeShift != 0 && !predictedWide { schedulePrediction() } }
    }
    nonisolated static let maximumTimeShift: TimeInterval = 2 * 86_400
    /// Whether the last prediction covered the whole time bar range.
    private var predictedWide = false

    /// The time the Observe screen shows.
    func viewDate(_ now: Date = .now) -> Date { now + timeShift }

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
    /// Launch, orbit, radar and physical size by catalogue number (CelesTrak SATCAT and GCAT).
    private(set) var satelliteInfo: [String: SatelliteInfo] = [:]
    private(set) var passes: [SatellitePass] = []
    private(set) var isPredicting = false
    private(set) var isRefreshing = false
    /// Checking selected satellites for ones that never rise here.
    private(set) var isPruning = false
    /// The object the pass calculator is open on.
    var calculatorObjectID: String?
    var message: String?

    let mount = MountSession()
    let guider = Guider()
    let conjunctions = ConjunctionsModel()

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
        guider.app = self
        conjunctions.app = self
    }

    func start() async {
        Task { await loadSatelliteInfo() }
        await reloadFromCatalog()
        schedulePrediction()
        await refreshDue()
        conjunctions.startWatching()
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
        highlightedObjectID.flatMap(object) ?? highlightedPass(at: viewDate()).flatMap { object("sat:\($0.noradID)") }
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
        if objectID.hasPrefix("sat:"), let pass = passes.first(where: { "sat:\($0.noradID)" == objectID && $0.end.date > viewDate() }) {
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
            // Tracking follows the time bar, so any pass not over at that time can be tracked.
            let now = viewDate()
            let highlighted = highlightedPass(at: now)
            let pass = highlighted?.noradID == s.noradID ? highlighted
                : passes.first { $0.noradID == s.noradID && $0.end.date > now }
            targetPassKey = pass.map { ($0.noradID, $0.start.date) }
        } else {
            targetPassKey = nil
        }
    }

    func setTarget(pass: SatellitePass) {
        guard !mount.isTracking, pass.end.date > viewDate() else { return }
        targetObjectID = "sat:\(pass.noradID)"
        targetPassKey = (pass.noradID, pass.start.date)
    }

    func clearTarget() {
        guard !mount.isTracking else { return }
        targetObjectID = nil
        targetPassKey = nil
    }

    /// Whether `object` can be tracked now, with this connection and mode.
    func canTrack(_ object: SkyObject?) -> Bool {
        guard let object, mount.state == .connected else { return false }
        switch (mount.kind, mount.effectiveMode) {
        case (.wifi, .passive): return object.passiveTracking != nil
        case (.usb, _): return settings.alignment != nil
        default: return true
        }
    }

    /// Tracks the locked target only, never whatever happens to be highlighted. The Sun needs
    /// the filter confirmation first, which callers show.
    func startTracking() async {
        guard let target = targetObject, canTrack(target) else { return }
        await mount.track(target, mode: mount.effectiveMode, pass: targetPass)
    }

    /// Makes `objectID` the target and starts tracking it (from the sky view's menu).
    func track(objectID: String) async {
        guard !mount.isTracking, let object = object(objectID), !object.isSun else { return }
        highlight(objectID: objectID)
        setTargetFromHighlight()
        await startTracking()
    }

    /// Stops tracking (or the move to the start point) and lets go of the target.
    func untrack() async {
        if mount.isTracking || mount.isPreparing { await mount.stopAll() }
        clearTarget()
    }

    /// The pass a satellite is on now, or its next one.
    func currentOrNextPass(_ noradID: String, at date: Date) -> SatellitePass? {
        passes.filter { $0.noradID == noradID && $0.end.date > date }.min { $0.start.date < $1.start.date }
    }

    /// When an object rises (or rose, if it's up now), for sorting: up now first, then soonest.
    func riseTime(_ object: SkyObject, at date: Date) -> Date {
        switch object {
        case .satellite(let s):
            return currentOrNextPass(s.noradID, at: date)?.start.date ?? .distantFuture
        default:
            guard let v = try? settings.observer.visibility(of: object.target, at: date) else { return .distantFuture }
            if v.isUp { return v.rise ?? .distantPast }
            return v.rise ?? .distantFuture
        }
    }

    func info(_ object: SkyObject) -> SatelliteInfo? {
        guard case .satellite(let s) = object else { return nil }
        return satelliteInfo[SatelliteCatalogInfo.key(s.noradID)]
    }

    /// Published radar cross-section in m², a rough guide to size and brightness.
    func radarCrossSection(_ object: SkyObject) -> Double? { info(object)?.radarCrossSection }

    private static let satelliteInfoFile = storage.appending(path: "satellite-info.json")

    /// The saved copy first, then a fresh one weekly: the catalogues are 7 and 19 MB, and what's
    /// shown from them rarely changes.
    private func loadSatelliteInfo() async {
        let file = Self.satelliteInfoFile
        let saved = await Task.detached {
            try? JSONDecoder().decode([String: SatelliteInfo].self, from: Data(contentsOf: file))
        }.value
        if let saved { satelliteInfo = saved }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, Date.now.timeIntervalSince(modified) < 7 * 86_400, saved != nil { return }

        func download(_ url: URL) async -> Data? {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return data
        }
        guard let satcat = await download(SatelliteCatalogInfo.celesTrakURL) else { return }
        let gcat = await download(SatelliteCatalogInfo.gcatURL)
        let fresh = await Task.detached { () -> [String: SatelliteInfo] in
            var info = SatelliteCatalogInfo.parseCelesTrak(String(decoding: satcat, as: UTF8.self))
            if let gcat { SatelliteCatalogInfo.addGCAT(String(decoding: gcat, as: UTF8.self), to: &info) }
            if !info.isEmpty {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? JSONEncoder().encode(info).write(to: file)
            }
            return info
        }.value
        if !fresh.isEmpty { satelliteInfo = fresh }
    }

    func magnitude(_ object: SkyObject, at date: Date) -> Double? {
        object.apparentMagnitude(observer: settings.observer, at: AstroTime(date))
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

    /// Deselects the selected satellites (in one source, or all) that never get above the lowest
    /// altitude from here in the next week: wrong latitude for their orbit, or geostationary
    /// below the horizon.
    func deselectNeverRising(in group: SourceGroup? = nil) async {
        let ids = group.map { Set($0.satellites.map(\.noradID)) }
        let candidates: [SatelliteTarget] = selectedObjects.compactMap { object in
            guard case .satellite(let s) = object, ids?.contains(s.noradID) ?? true else { return nil }
            return s
        }
        guard !candidates.isEmpty else {
            message = "No selected satellites to check."
            return
        }
        isPruning = true
        defer { isPruning = false }
        var predictor = PassPredictor(observer: settings.observer)
        predictor.minimumAltitude = settings.minimumAltitude
        let now = Date.now
        let never = await predictor.neverRising(candidates, from: now, to: now + 7 * 86_400)
        var selection = selected
        selection.subtract(never.map { "sat:\($0.noradID)" })
        selected = selection
        let above = "above \(Int(settings.minimumAltitude))° from here in the next 7 days"
        if never.isEmpty {
            message = "All \(candidates.count) selected satellites rise \(above)."
        } else {
            let names = never.map(\.name).sorted()
            let list = names.prefix(10).joined(separator: ", ") + (names.count > 10 ? ", and \(names.count - 10) more" : "")
            message = "Deselected \(never.count) of \(candidates.count) that never rise \(above): \(list)."
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

    /// `quietly`: an automatic refresh, so "too soon" and network failures aren't reported.
    func refresh(_ id: String, quietly: Bool = false) async {
        guard let catalog else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await catalog.refresh(id)
        } catch TLECatalogError.tooSoon(let next) {
            if !quietly {
                message = "CelesTrak asks for at least 2 hours between downloads. Try again after \(next.formatted(date: .omitted, time: .shortened))."
            }
        } catch {
            if !quietly { message = "Refresh failed: \(error.localizedDescription)" }
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
        // Include passes already in progress. Once the time bar moves, cover its whole range so
        // dragging it never waits on a prediction.
        let wide = timeShift != 0
        let reach = wide ? Self.maximumTimeShift : 0
        let result = await predictor.passes(of: targets, from: now - reach - 15 * 60,
                                            to: now + reach + filter.hoursAhead * 3600,
                                            filter: f, sort: filter.sort.passSort)
        guard !Task.isCancelled else { return }
        passes = wide ? result : result.filter { $0.end.date > now }
        predictedWide = wide
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

    func save(_ value: some Encodable, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Loads saved values over the defaults, so a newer app version with extra settings
    /// keeps everything the user already set instead of resetting it.
    static func load<T: Codable>(_ key: String, default value: T) -> T {
        guard let stored = UserDefaults.standard.data(forKey: key) else { return value }
        if let decoded = try? JSONDecoder().decode(T.self, from: stored) { return decoded }
        guard var base = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value))) as? [String: Any],
              let saved = (try? JSONSerialization.jsonObject(with: stored)) as? [String: Any] else { return value }
        base.merge(saved) { _, new in new }
        guard let merged = try? JSONSerialization.data(withJSONObject: base) else { return value }
        return (try? JSONDecoder().decode(T.self, from: merged)) ?? value
    }
}
