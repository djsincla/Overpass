import Foundation
import IOptronKit
import Observation
import SkyKit

enum TrackingMode: String, CaseIterable, Identifiable {
    /// The mount tracks by itself after one goto (WiFi). Stars, planets, Moon, Sun, geostationary.
    case passive = "Passive"
    /// A goto to where the target will be, repeated every few seconds (WiFi).
    case step = "Step"
    /// Continuously varied axis speeds (USB Special mode).
    case smooth = "Smooth"
    var id: Self { self }
}

enum JogDirection { case up, down, left, right }

/// One pass of the Smooth tracking loop. Errors are on the sky (azimuth scaled by cos altitude), degrees.
struct TraceSample {
    let date: Date
    /// When the axes were read (the middle of the exchange).
    let read: Date
    /// Seconds since the previous pass of the loop.
    let loopInterval: TimeInterval
    let primary: Double
    let secondary: Double
    let primaryError: Double
    let secondaryError: Double
    let feedPrimary: Double
    let feedSecondary: Double
    let commandPrimary: Double
    let commandSecondary: Double
    /// The reading looked like a glitch, so the planned speed was held instead of correcting.
    var held = false

    var error: Double { (primaryError * primaryError + secondaryError * secondaryError).squareRoot() }
}

/// The connection to the mount, manual moves, alignment and the three tracking modes.
@MainActor @Observable
final class MountSession {
    enum State: Equatable {
        case disconnected, connecting, connected
        case failed(String)
    }

    weak var app: AppModel?

    private(set) var state = State.disconnected
    private(set) var kind: ConnectionKind?
    private(set) var identity: MountIdentity?
    /// Where the scope points, for the dome.
    private(set) var skyPosition: Horizontal? {
        didSet { if skyPosition == nil { skyPositionDate = nil } }
    }
    /// When `skyPosition` was true: the middle of the exchange that read it. A moving target
    /// has to be compared at this moment, not when the screen redraws.
    private(set) var skyPositionDate: Date?
    /// Raw axes (Special mode), primary unwrapped.
    private(set) var axes: AxisPosition?
    private(set) var status = ""
    private(set) var trackingName: String?
    /// What's being tracked, for the camera guider.
    private(set) var trackingObject: SkyObject?
    private(set) var trackingMode: TrackingMode?
    /// The last few minutes of the Smooth tracking loop, for diagnosing jumps and lag.
    private(set) var trace: [TraceSample] = []
    /// How much of the trace is kept, seconds: long enough for a whole pass.
    nonisolated static let traceSpan: TimeInterval = 240
    private var lastLoop: Date?
    var isTracking: Bool { trackingTask != nil }
    /// The mode chosen in the tracking card; WiFi offers Passive or Step, USB is always Smooth.
    var preferredMode = TrackingMode.step
    /// What tracking will actually use with this connection.
    var effectiveMode: TrackingMode { kind?.isSpecialMode == true ? .smooth : preferredMode }

    // Fine tuning, applied live by Step and Smooth tracking.
    /// Seconds added to "now": positive aims further along the track (fixes along-track TLE error).
    var timeOffset: TimeInterval = 0
    /// Degrees, added to the target position.
    var azimuthOffset: Double = 0
    var altitudeOffset: Double = 0

    /// Special mode jog speed, degrees per second.
    var jogSpeed: Double = 0.5
    /// Normal mode jog speed.
    var moveRate = NormalCommand.MoveRate.x64

    /// Sightings collected during alignment (Special mode).
    private(set) var alignmentPoints: [AlignmentPoint] = []

    private var normal: NormalModeClient?
    private var special: MountClient?
    private var tcp: TCPTransport?
    private var unwrapper: AxisUnwrapper?
    /// The USB line (or, on iPhone and iPad, the relay), for Normal-mode commands on the way out
    /// of Special mode.
    private var usbTransport: MountTransport?

    /// Where Overpass last knew the tube pointed, kept across launches. The mount loses its
    /// position whenever it changes mode (Normal mode reads az 0, alt 0 after Special mode, and
    /// Special mode starts from that), so Overpass is the record and tells the mount after
    /// every switch.
    struct KnownPointing: Codable, Equatable {
        var azimuth: Double
        var altitude: Double
        var date: Date
        var horizontal: Horizontal { Horizontal(azimuth: azimuth, altitude: altitude) }
    }
    private(set) var knownPointing: KnownPointing? = AppModel.load("knownPointing", default: KnownPointing?.none)
    private var knownPointingSaved = Date.distantPast
    /// Set when the mount's position disagrees with the record: readings stop updating the record
    /// until the position is set or aligned, so the good value isn't overwritten by the bad one.
    private(set) var recordHeld = false

    /// Mode switches and position syncs, for working out what the mount does with them.
    static let logFile = AppModel.storage.appending(path: "mount-log.txt")

    func log(_ line: String) {
        let text = "\(Date.now.formatted(.iso8601)) \(line)\n"
        let file = Self.logFile
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: file)
        }
    }

    private func describe(_ h: Horizontal) -> String { String(format: "az %.3f° alt %.3f°", h.azimuth, h.altitude) }

    private func remember(_ pointing: Horizontal, now: Bool = false) {
        knownPointing = KnownPointing(azimuth: pointing.azimuth, altitude: pointing.altitude, date: .now)
        if now || Date.now.timeIntervalSince(knownPointingSaved) > 5 {
            app?.save(knownPointing, "knownPointing")
            knownPointingSaved = .now
        }
    }
    /// Set when a `:T0`/`:T1` slew headed away from its target; rate control does moves after that.
    private var nativeSlewWentWrongWay = false
    private var pollTask: Task<Void, Never>?
    private var trackingTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Never>?
    /// True while moving to a pass's start point.
    var isPreparing: Bool { prepareTask != nil }

    private var settings: Settings { app?.settings ?? Settings() }

    /// The time tracking follows: the Observe screen's time bar, so a shifted timeline can be
    /// rehearsed on the mount. Timeouts and step intervals still use the real clock, and sync and
    /// alignment always use real time (the scope is on the real star).
    private var skyNow: Date { app?.viewDate() ?? .now }

    private let countdownSounds = CountdownSounds()

    /// Sound alerts before tracking starts, `start` being sky time (the time bar's).
    private func countDown(to start: Date) {
        let s = settings
        guard s.countdownSounds || s.minuteWarningSound else { return countdownSounds.cancel() }
        countdownSounds.alert(before: start - skyNow.timeIntervalSince(.now),
                              minuteWarning: s.minuteWarningSound, countdown: s.countdownSounds)
    }

    var availableModes: [TrackingMode] {
        switch kind {
        case .wifi, .usbNormal: [.passive, .step]
        case .usb: [.smooth]
        case nil: []
        }
    }

    // MARK: Connection

    func connect() async {
        await disconnect()
        let s = settings
        state = .connecting
        status = ""
        maximumSpeedSet = false
        do {
            switch s.connection {
            case .wifi:
                let transport = TCPTransport(host: s.wifiHost, port: UInt16(s.wifiPort), timeout: 3)
                try await transport.open()
                tcp = transport
                let client = NormalModeClient(transport: transport)
                let id = try await client.identify()
                if id.isSpecialMode {
                    throw MountSessionError.inSpecialMode
                }
                try await client.configure(latitude: s.latitude, longitude: s.longitude)
                await syncIfLeftSpecialMode(client)
                normal = client
                identity = id
            case .usbNormal:
                let transport = try await openUSB(s)
                let client = NormalModeClient(transport: transport)
                var id = try await client.identify()
                if id.isSpecialMode {
                    // Chosen Normal mode, so leave Special mode, carrying the position across.
                    status = "Leaving Special mode…"
                    let special = MountClient(transport: transport)
                    let raw = try await special.positions()
                    let model = s.alignment ?? .iOptronSpecialMode
                    let pointing = model.sky(for: AxisPosition(primary: raw.primary, secondary: raw.secondary))
                    remember(pointing, now: true)
                    log(String(format: "USB Normal connect, leaving Special mode: P0 %+.4f° P1 %+.4f° = ", raw.primary, raw.secondary) + describe(pointing))
                    await holdStill(special: special)
                    _ = try await special.exitSpecialMode()
                    await holdStill(normal: client)
                    let position = await waitForNormalPosition(client)
                    try await client.configure(latitude: s.latitude, longitude: s.longitude)
                    await syncAfterSwitch(client, position: position)
                    id = try await client.identify()
                } else {
                    try await client.configure(latitude: s.latitude, longitude: s.longitude)
                    await syncIfLeftSpecialMode(client)
                }
                normal = client
                identity = id
            case .usb:
                let transport = try await openUSB(s)
                let client = MountClient(transport: transport)
                identity = try await enterSpecialMode(client, transport)
                let raw = try await client.positions()
                let s = settings
                unwrapper = AxisUnwrapper(raw: raw.primary, model: s.alignment ?? AlignmentModel(), limits: s.limits)
                nativeSlewWentWrongWay = false
                special = client
            }
            kind = s.connection
            state = .connected
            startPolling()
        } catch {
            state = .failed(describe(error))
            await closeTransport()
        }
    }

    func disconnect() async {
        await stopAll()
        pollTask?.cancel()
        pollTask = nil
        if let special, settings.leaveSpecialModeOnDisconnect {
            // Where the tube points, from the Special-mode axes, before leaving: Normal mode
            // comes back reading az 0, alt 0, so tell it.
            var pointing: Horizontal?
            if settings.alignment != nil, (try? await readPosition()) != nil { pointing = skyPosition }
            if let pointing { remember(pointing, now: true) }
            if let raw = try? await special.positions() {
                log(String(format: "Disconnect: P0 %+.4f° P1 %+.4f°", raw.primary, raw.secondary) + (pointing.map { " = " + describe($0) } ?? ""))
            }
            await holdStill(special: special)
            if (try? await special.exitSpecialMode()) != nil, let transport = usbTransport {
                normalNeedsSync = true
                await holdStill(normal: NormalModeClient(transport: transport))
                // No sync: on the HAZ46 a :CM# sync here added the position a second time
                // (25 Oct 2026). Just record what Normal mode reports.
                if let p = try? await NormalModeClient(transport: transport).altAz() {
                    log(String(format: "Left Special mode: :GAC# az %.3f° alt %.3f°", p.azimuth, p.altitude))
                }
            }
        }
        await closeTransport()
        state = .disconnected
        kind = nil
        identity = nil
        skyPosition = nil
        axes = nil
    }

    private func closeTransport() async {
        await tcp?.close()
        tcp = nil
        normal = nil
        special = nil
        usbTransport = nil
        unwrapper = nil
        axisHistory = []
    }

    /// The mount's USB port, or on iPhone and iPad the relay plugged into it.
    private func openUSB(_ s: Settings) async throws -> MountTransport {
        #if os(macOS)
        guard !s.serialPath.isEmpty else { throw MountSessionError.noSerialPort }
        let transport = try SerialTransport(path: s.serialPath)
        #else
        let transport = TCPTransport(host: s.relayHost, port: UInt16(s.relayPort), timeout: 3)
        try await transport.open()
        tcp = transport
        #endif
        usbTransport = transport
        return transport
    }

    /// Keeps the position readout current while nothing else is talking to the mount.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            var failures = 0
            while !Task.isCancelled {
                if trackingTask == nil && prepareTask == nil {
                    do {
                        _ = try await readPosition()
                        failures = 0
                    } catch MountSessionError.pastCableStop {
                        // A held jog reached the stop: this is the backstop that ends it.
                        try? await special?.stop()
                        status = MountSessionError.pastCableStop.message
                    } catch {
                        failures += 1
                        if failures >= 3 {
                            status = describe(error)
                            state = .failed("Lost contact with the mount: \(describe(error))")
                            return
                        }
                    }
                }
                // Special mode is polled twice a second; Normal mode at its configured pace.
                let pause = special != nil ? 0.5 : max(0.5, settings.normalModePeriod)
                try? await Task.sleep(for: .seconds(pause))
            }
        }
    }

    /// Recent request-to-answer times, for timestamping positions.
    private var exchangeTimes: [TimeInterval] = []

    /// When a reported position was true: half a typical exchange after asking. Not half of
    /// this exchange: every 5 s the HAZ answers ~15 ms late, and the position it reports was
    /// taken before the delay, so a midpoint stamp made it look 10–20″ behind a fast satellite.
    private func positionTime(asked: Date, answered: Date) -> Date {
        exchangeTimes.append(answered.timeIntervalSince(asked))
        if exchangeTimes.count > 25 { exchangeTimes.removeFirst() }
        let typical = exchangeTimes.sorted()[exchangeTimes.count / 2]
        return asked + typical / 2
    }

    /// The last few seconds of axis readings (Special mode), for matching camera frames to where
    /// the mount was when they were taken.
    private var axisHistory: [(date: Date, axes: AxisPosition)] = []

    /// Where the axes were at `date`, interpolated between readings. Slightly past the last
    /// reading it carries on at the last speed.
    func axes(at date: Date) -> AxisPosition? {
        guard let last = axisHistory.last else { return nil }
        guard let i = axisHistory.firstIndex(where: { $0.date >= date }) else {
            guard axisHistory.count >= 2, date.timeIntervalSince(last.date) < 0.5 else { return last.axes }
            return Self.interpolate(axisHistory[axisHistory.count - 2], last, at: date)
        }
        return i == 0 ? axisHistory[0].axes : Self.interpolate(axisHistory[i - 1], axisHistory[i], at: date)
    }

    private static func interpolate(_ a: (date: Date, axes: AxisPosition), _ b: (date: Date, axes: AxisPosition),
                                    at date: Date) -> AxisPosition {
        let span = b.date.timeIntervalSince(a.date)
        guard span > 0 else { return b.axes }
        let f = date.timeIntervalSince(a.date) / span
        return AxisPosition(primary: a.axes.primary + f * (b.axes.primary - a.axes.primary),
                            secondary: a.axes.secondary + f * (b.axes.secondary - a.axes.secondary))
    }

    /// Whether the mount's own location can be read: Normal mode, over WiFi or USB.
    var canReadSite: Bool { normal != nil }

    /// The mount's latitude and longitude: its GPS fix, or what was last set in it.
    func site() async throws -> MountSite {
        guard let normal else { throw MountSessionError.needsNormalMode }
        return try await normal.site()
    }

    @discardableResult
    private func readPosition() async throws -> AxisPosition? {
        if let normal {
            _ = try await currentAltAz(normal)
            return nil
        }
        guard let special, var unwrapper else { return nil }
        let asked = Date.now
        let raw = try await special.positions()
        skyPositionDate = positionTime(asked: asked, answered: .now)
        let current = AxisPosition(primary: unwrapper.update(raw: raw.primary), secondary: raw.secondary)
        self.unwrapper = unwrapper
        axes = current
        if let date = skyPositionDate {
            axisHistory.append((date, current))
            axisHistory.removeFirst(axisHistory.prefix { date.timeIntervalSince($0.date) > 5 }.count)
        }
        let model = settings.alignment ?? AlignmentModel()
        skyPosition = model.sky(for: current)
        if settings.alignment != nil, !recordHeld, let skyPosition { remember(skyPosition) }
        try checkCableRange(current)
        return current
    }

    /// Special mode only: the app owns the azimuth turns, so it can enforce the cable stop itself.
    private func checkCableRange(_ current: AxisPosition) throws {
        let s = settings
        let model = s.alignment ?? AlignmentModel()
        let mountAzimuth = model.azimuthSense * current.primary
        let lo = s.cableStopAzimuth + model.yaw
        if mountAzimuth < lo || mountAzimuth > lo + 360 { throw MountSessionError.pastCableStop }
    }

    // MARK: Manual moves

    func jog(_ direction: JogDirection, pressed: Bool) async {
        if pressed { await cancelTracking() }
        do {
            if let normal {
                let d: NormalCommand.Direction = switch direction {
                case .up: .north
                case .down: .south
                case .left: .west
                case .right: .east
                }
                if pressed {
                    try await normal.setMoveRate(moveRate)
                    try await normal.startMove(d)
                } else {
                    try await normal.stopMove(d)
                }
            } else if let special {
                guard pressed else { try await special.stop(); return }
                let model = settings.alignment ?? AlignmentModel()
                let speed: (Double, Double) = switch direction {
                case .up: (0, model.altitudeSense * jogSpeed)
                case .down: (0, -model.altitudeSense * jogSpeed)
                // Right = clockwise from above (azimuth increasing).
                case .right: (model.azimuthSense * jogSpeed, 0)
                case .left: (-model.azimuthSense * jogSpeed, 0)
                }
                if let axes, wouldHitCableStop(axes, primaryRate: speed.0) {
                    status = "Can't turn further that way: cable stop"
                    return
                }
                try await special.setSpeeds(primary: speed.0, secondary: speed.1)
            }
        } catch {
            status = describe(error)
        }
    }

    /// Fine tune. While Step or Smooth tracking, shifts the tracking offsets; otherwise makes a
    /// short, slow move of about `arcminutes` (the mount's own tracking carries on in Passive).
    func nudge(_ direction: JogDirection, arcminutes: Double) async {
        let degrees = arcminutes / 60
        if trackingMode == .step || trackingMode == .smooth {
            switch direction {
            case .up: altitudeOffset += degrees
            case .down: altitudeOffset -= degrees
            case .right: azimuthOffset += degrees
            case .left: azimuthOffset -= degrees
            }
            return
        }
        guard trackingTask == nil || trackingMode == .passive else { return }
        do {
            if let normal {
                // 16× sidereal ≈ 0.067°/s: slow enough to time a 1′ move to about a tenth of a second.
                let rate = NormalCommand.MoveRate.x16
                let d: NormalCommand.Direction = switch direction {
                case .up: .north
                case .down: .south
                case .left: .west
                case .right: .east
                }
                try await normal.setMoveRate(rate)
                try await normal.startMove(d)
                try await Task.sleep(for: .seconds(degrees / rate.degreesPerSecond!))
                try await normal.stopMove(d)
            } else if let special {
                let speed = 0.05
                let model = settings.alignment ?? AlignmentModel()
                let rates: (Double, Double) = switch direction {
                case .up: (0, model.altitudeSense * speed)
                case .down: (0, -model.altitudeSense * speed)
                case .right: (model.azimuthSense * speed, 0)
                case .left: (-model.azimuthSense * speed, 0)
                }
                if let axes, wouldHitCableStop(axes, primaryRate: rates.0) { return }
                try await special.setSpeeds(primary: rates.0, secondary: rates.1)
                try await Task.sleep(for: .seconds(degrees / speed))
                try await special.stop()
            }
        } catch {
            status = describe(error)
        }
    }

    private func wouldHitCableStop(_ axes: AxisPosition, primaryRate: Double) -> Bool {
        let s = settings
        let model = s.alignment ?? AlignmentModel()
        let mountAzimuth = model.azimuthSense * axes.primary
        let direction = model.azimuthSense * primaryRate
        let lo = s.cableStopAzimuth + model.yaw + s.cableMargin, hi = lo + 360 - 2 * s.cableMargin
        return (direction > 0 && mountAzimuth >= hi) || (direction < 0 && mountAzimuth <= lo)
    }

    /// Stops everything: tracking, slews and jogs.
    func stopAll() async {
        if let trackingName { log("Stop pressed while tracking \(trackingName)") } else if prepareTask != nil { log("Stop pressed while moving to the start point") }
        // Stop at once, then again once the loops have ended: waiting first let a goto finish
        // over slow WiFi, and a loop partway through a step can still send one more command.
        let wasMoving = trackingTask != nil || prepareTask != nil
        if wasMoving {
            prepareTask?.cancel()
            trackingTask?.cancel()
            try? await normal?.stop()
            try? await special?.stop()
        }
        await cancelTracking()
        try? await normal?.stop()
        try? await special?.stop()
        status = "Stopped"
    }

    private func cancelTracking() async {
        let tasks = [prepareTask, trackingTask].compactMap { $0 }
        prepareTask = nil
        trackingTask = nil
        trackingName = nil
        trackingObject = nil
        trackingMode = nil
        tracksCamera = false
        for task in tasks { task.cancel() }
        countdownSounds.cancel()
        // Wait for the loops to end. One partway through a step would otherwise send its speeds
        // after the stop that follows, and the mount would pause and carry on.
        for task in tasks { await task.value }
    }

    // MARK: Tracking

    func track(_ object: SkyObject, mode: TrackingMode, pass: SatellitePass?) async {
        await startTracking(name: object.name, object: object, mode: mode) {
            switch mode {
            case .passive: try await self.runPassive(object)
            case .step: try await self.runStep(object, pass: pass)
            case .smooth: try await self.runSmooth(object, pass: pass)
            }
        }
    }

    /// Follows whatever the camera tracker is locked on (Special mode).
    func trackCamera(_ source: CameraTracker) async {
        await startTracking(name: "Camera target", object: nil, mode: nil, camera: true) {
            try await self.runCamera(source)
        }
    }

    /// Camera tracking is running.
    private(set) var tracksCamera = false

    private func startTracking(name: String, object: SkyObject?, mode: TrackingMode?, camera: Bool = false,
                               _ run: @escaping @MainActor () async throws -> Void) async {
        await stopAll()
        trackingName = name
        trackingObject = object
        trackingMode = mode
        tracksCamera = camera
        trace = []
        lastLoop = nil
        status = "Starting…"
        let label = mode.map { "\(name) (\($0))" } ?? name
        log("Tracking \(label) started" + (skyPosition.map { " at " + describe($0) } ?? ""))
        trackingTask = Task {
            do {
                try await run()
            } catch is CancellationError {
            } catch {
                status = describe(error)
                log("Tracking \(label) stopped: \(describe(error))")
                try? await normal?.stop()
                try? await special?.stop()
            }
            if !Task.isCancelled {
                trackingTask = nil
                trackingName = nil
                trackingObject = nil
                trackingMode = nil
                tracksCamera = false
            }
        }
    }

    /// The elevation tracking starts from: the higher of the prediction horizon and the start setting.
    private var startAltitude: Double { max(settings.minimumAltitude, settings.trackingStartAltitude) }

    /// Where `pass` first reaches the start elevation, if it hasn't already gone past it.
    func startPoint(of pass: SatellitePass) -> PassSample? {
        guard let point = pass.startPoint(above: startAltitude), point.date > skyNow else { return nil }
        return point
    }

    /// Moves the mount to where the pass will first reach the start elevation, and holds there.
    func moveToStart(of pass: SatellitePass) async {
        await stopAll()
        guard let point = startPoint(of: pass) else {
            status = "That pass is already past its start point."
            return
        }
        status = "Moving to start point"
        log("Move to start of \(pass.name): " + describe(point.position) + " at \(point.date.formatted(date: .omitted, time: .standard))")
        prepareTask = Task {
            do {
                if let normal {
                    status = "Slewing to start point at full speed…"
                    try await goto(normal, to: point.position)
                    // MSS leaves tracking off, so the mount holds there.
                    status = "Waiting at az \(Int(point.position.azimuth))°, alt \(Int(point.position.altitude))° · reaches it in \(countdown(point.date.timeIntervalSince(skyNow)))"
                } else if let special {
                    try await driveToPlanStart(pass, special)
                }
            } catch is CancellationError {
            } catch {
                status = describe(error)
                log("Move to start stopped: \(describe(error))")
                try? await normal?.stop()
                try? await special?.stop()
            }
            if !Task.isCancelled { prepareTask = nil }
        }
    }

    /// Special mode: the start of the planned pass, so the mount is already on the right side and
    /// azimuth turn (which matters when the plan flips over the top).
    private func driveToPlanStart(_ pass: SatellitePass, _ special: MountClient) async throws {
        guard let model = settings.alignment else { throw MountSessionError.notAligned }
        let s = settings
        guard let plan = MountPlanner(limits: s.limits, model: model).plan(pass.track(above: startAltitude)) else {
            throw MountSessionError.untrackablePass
        }
        status = "Slewing to start point at full speed…"
        try await slewAxes(special, to: plan.start)
        // The mount's slew gets close; rate control settles the last fraction of a degree.
        var controller = RateController(limits: s.limits)
        controller.maximumCorrection = max(s.maximumAzimuthRate, s.maximumAltitudeRate)
        let deadline = Date.now + 300
        while !Task.isCancelled {
            guard let current = try await readPosition() else { return }
            let goal = plan.start
            if abs(goal.primary - current.primary) < 0.02 && abs(goal.secondary - current.secondary) < 0.02 {
                try await special.stop()
                status = "Ready at the start point · rises in \(countdown(plan.samples[0].date.timeIntervalSince(skyNow)))"
                return
            }
            guard Date.now < deadline else { throw MountSessionError.couldNotReachStart }
            let command = controller.rates(desired: goal, primaryRate: 0, secondaryRate: 0, current: current)
            if wouldHitCableStop(current, primaryRate: command.primary) { throw MountSessionError.pastCableStop }
            try await special.setSpeeds(primary: command.primary, secondary: command.secondary)
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func runPassive(_ object: SkyObject) async throws {
        guard let normal else { throw MountSessionError.needsWiFi }
        guard let how = object.passiveTracking else { throw MountSessionError.notPassive }
        let s = settings
        let observer = s.observer
        // Get there by the allowed way round first; the RA/Dec goto that starts tracking is then tiny.
        status = "Slewing at full speed…"
        try await goto(normal, to: try observer.look(at: object.target, AstroTime(skyNow)))

        if how == .holdPosition {
            status = "Holding position (geostationary)"
            return
        }
        let rate: NormalCommand.TrackingRate = switch how {
        case .lunar: .lunar
        case .solar: .solar
        default: .sidereal
        }
        let rateName = rate == .lunar ? "lunar" : rate == .solar ? "solar" : "sidereal"
        // The Moon's parallax changes as it moves, so it's re-centred every few minutes. Between
        // times, watch the mount's own status, so a stop shows here and in the mount log.
        var recentred = Date.distantPast
        var lastState: Int?
        while !Task.isCancelled {
            if how == .lunar ? Date.now.timeIntervalSince(recentred) > 300 : recentred == .distantPast {
                let (ra, dec) = try observer.topocentricRADec(of: object.target, at: AstroTime(skyNow))
                do {
                    try await normal.slew(rightAscension: ra, declination: dec, rate: rate)
                    log(String(format: "Passive %@: RA/Dec goto (RA %.4f° Dec %.4f°) accepted, %@ rate", object.name, ra, dec, rateName))
                } catch {
                    log("Passive \(object.name): RA/Dec goto failed: \(describe(error))")
                    throw error
                }
                recentred = .now
            }
            let state = try? await normal.systemStatus()
            if let state, state != lastState {
                log("Passive \(object.name): mount status \(state) (\(Self.systemStatusName(state)))")
                lastState = state
            }
            switch state {
            case 1, 5: status = "Mount tracking at \(rateName) rate"
            case 2: status = "Mount slewing…"
            case let other?:
                status = "The mount stopped tracking (it reports \(Self.systemStatusName(other)))"
            case nil: break
            }
            try await Task.sleep(for: .seconds(max(2, settings.normalModePeriod * 3)))
        }
    }

    /// `:GLS#` system status digit.
    static func systemStatusName(_ digit: Int) -> String {
        switch digit {
        case 0: "stopped"
        case 1: "tracking"
        case 2: "slewing"
        case 3: "guiding"
        case 4: "meridian flip"
        case 5: "tracking with PEC"
        case 6: "parked"
        case 7: "stopped at home"
        default: "status \(digit)"
        }
    }

    private func runStep(_ object: SkyObject, pass: SatellitePass?) async throws {
        guard let normal else { throw MountSessionError.needsWiFi }
        var waitingAtRise = false
        let crossing = pass.flatMap(northCrossing(of:))
        if let crossing, let pass {
            log("\(pass.name) crosses the cable stop at \(crossing.formatted(date: .omitted, time: .standard)); the mount goes the long way round there")
        }
        func crossingNote() -> String {
            crossing.map { " · goes the long way round at \($0.formatted(date: .omitted, time: .shortened)), where it crosses the cable stop" } ?? ""
        }
        func aimPoint(after seconds: TimeInterval) throws -> Horizontal {
            var h = try StepTracking.aim(at: object.target, observer: settings.observer, now: skyNow + timeOffset, lead: seconds)
            h.azimuth = normalizedDegrees(h.azimuth + azimuthOffset)
            h.altitude += altitudeOffset
            return h
        }
        while !Task.isCancelled {
            let s = settings
            let tick = Date.now
            let sky = skyNow
            let interval = max(s.normalModePeriod, s.stepInterval)
            if let pass, sky > pass.end.date + 5 {
                status = "Pass over"
                return
            }
            let aim = try aimPoint(after: StepTracking.defaultLead(interval: interval))

            if aim.altitude < startAltitude {
                // Before the pass: wait where it first reaches the start elevation, once.
                if let pass, let point = pass.startPoint(above: startAltitude), sky < point.date, !waitingAtRise {
                    status = "Slewing to start point at full speed…"
                    try await goto(normal, to: point.position)
                    waitingAtRise = true
                }
                let point = pass.flatMap { $0.startPoint(above: startAltitude) }
                if let point { countDown(to: point.date) }
                status = (point
                    .map { "Waiting at start point · reaches \(Int(startAltitude))° in \(countdown($0.date.timeIntervalSince(skyNow)))" }
                    ?? "Below \(Int(startAltitude))°") + crossingNote()
            } else {
                // Read at the end of the last step; good enough to tell which way round to go.
                let here = if let skyPosition { skyPosition } else { try await currentAltAz(normal) }
                if Self.turnsLongWay(from: here, to: aim, stop: s.cableStopAzimuth) {
                    // The mount's goto won't turn through north, so it goes the long way round.
                    // Let it, aimed at where the satellite will be when it gets there.
                    var ahead = aim
                    for _ in 0..<3 {
                        ahead = try aimPoint(after: Self.slewTime(from: here, to: ahead, stop: s.cableStopAzimuth))
                    }
                    if let pass, skyNow + Self.slewTime(from: here, to: ahead, stop: s.cableStopAzimuth) > pass.end.date {
                        status = "Pass over before the mount could get round"
                        return
                    }
                    log("Going the long way round to " + describe(ahead) + " from " + describe(here))
                    status = "Going the long way round (the mount won't turn through the cable stop)…"
                    try await goto(normal, to: ahead, from: here)
                    continue
                }
                do {
                    try await normal.slew(altitude: aim.altitude, azimuth: aim.azimuth)
                    log("Step to " + describe(aim) + ", mount read " + describe(here))
                    status = String(format: "Stepping every %.1f s · az %.1f° alt %.1f°", interval, aim.azimuth, aim.altitude) + crossingNote()
                } catch NormalModeError.slewRefused {
                    status = "Mount refused the step (below its altitude limit?)"
                    log("Step to " + describe(aim) + " refused by the mount")
                }
            }
            _ = try? await readPosition()
            let wait = interval - Date.now.timeIntervalSince(tick)
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        }
    }

    /// Set once per connection: gotos at the mount's maximum speed.
    private var maximumSpeedSet = false

    /// The azimuth the mount can't turn through, in either mode.
    var effectiveCableStop: Double { settings.cableStopAzimuth }

    /// While a Normal-mode goto runs: where it's headed. The position isn't read mid-slew (the
    /// mount hesitates at any command), so this is what the sky shows meanwhile.
    private(set) var slewTarget: Horizontal?

    /// When `pass` crosses the cable stop above the start elevation, if it does: there the
    /// mount's goto goes the long way round.
    func northCrossing(of pass: SatellitePass) -> Date? {
        let stop = settings.cableStopAzimuth
        let track = pass.track.filter { $0.position.altitude >= startAltitude }
        for (a, b) in zip(track, track.dropFirst()) where Self.turnsLongWay(from: a.position, to: b.position, stop: stop) {
            return b.date
        }
        return nil
    }

    /// Update period while moving into position (waiting at the start, catching up, crossing
    /// north); the faster setting is only for tracking on target.
    private static let positioningPeriod = 0.25

    /// The HAZ46 goes to about 6°/s at its top speed; slightly under, so the quiet wait errs long.
    private static let estimatedSlewRate = 5.0

    /// The HAZ46's own goto never turns through north (az 0°): asked for 283° to 19°, it went
    /// most of the way round the other way (26 Oct 2026). That is its cable wrap, so Normal mode
    /// leaves the route to it and only allows for the time it takes.
    static func turnsLongWay(from: Horizontal, to: Horizontal, stop: Double) -> Bool {
        abs(CableRoute.offset(to.azimuth, stop: stop) - CableRoute.offset(from.azimuth, stop: stop)) > 180
    }

    /// How long a goto takes the way the mount goes, plus time to speed up and slow down.
    static func slewTime(from: Horizontal, to: Horizontal, stop: Double) -> TimeInterval {
        let turn = abs(CableRoute.offset(to.azimuth, stop: stop) - CableRoute.offset(from.azimuth, stop: stop))
        return max(turn, abs(to.altitude - from.altitude)) / estimatedSlewRate + 2
    }

    /// A normal-mode goto at full speed. The mount picks the way round.
    private func goto(_ normal: NormalModeClient, to target: Horizontal, from start: Horizontal? = nil) async throws {
        let here = if let start { start } else { try await currentAltAz(normal) }
        try await slewAndWait(normal, from: here, to: target)
    }

    private func currentAltAz(_ normal: NormalModeClient) async throws -> Horizontal {
        let asked = Date.now
        let p = try await normal.altAz()
        let h = Horizontal(azimuth: p.azimuth, altitude: p.altitude)
        skyPositionDate = positionTime(asked: asked, answered: .now)
        skyPosition = h
        // 0, 0 is what the mount reads after a mode change, not a position.
        if !recordHeld, abs(h.azimuth) > 1e-6 || abs(h.altitude) > 1e-6 { remember(h) }
        return h
    }

    /// One goto at full speed, waited out. Any command mid-slew makes the mount hesitate, so the
    /// app stays silent for about as long as the slew should take, then checks once a second.
    private func slewAndWait(_ normal: NormalModeClient, from start: Horizontal, to target: Horizontal) async throws {
        if !maximumSpeedSet {
            try await normal.setMaximumSlewSpeed(9)
            maximumSpeedSet = true
        }
        log("Goto " + describe(target) + " from " + describe(start))
        let sent = Date.now
        slewTarget = target
        defer { slewTarget = nil }
        try await normal.slew(altitude: target.altitude, azimuth: target.azimuth)
        try await Task.sleep(for: .seconds(Self.slewTime(from: start, to: target, stop: settings.cableStopAzimuth)))
        let deadline = Date.now + 180
        while try await normal.isSlewing() {
            guard Date.now < deadline else {
                log("Goto still slewing after 180 s; giving up")
                throw MountSessionError.couldNotReachStart
            }
            try await Task.sleep(for: .seconds(1))
        }
        let arrived = try await currentAltAz(normal)
        log(String(format: "Goto done in %.0f s: reads ", Date.now.timeIntervalSince(sent)) + describe(arrived)
            + String(format: ", %.2f° from the target", angularSeparation(arrived.unitVector, target.unitVector)))
    }

    private func runSmooth(_ object: SkyObject, pass: SatellitePass?) async throws {
        guard let special else { throw MountSessionError.needsUSB }
        guard let model = settings.alignment else { throw MountSessionError.notAligned }
        let s = settings
        var controller = RateController(limits: s.limits)
        let plan: MountPlan?
        if let pass {
            guard let p = MountPlanner(limits: s.limits, model: model).plan(pass.track(above: startAltitude)) else {
                throw MountSessionError.untrackablePass
            }
            plan = p
        } else {
            plan = nil
        }
        var mountSlews = true
        var glitchesInARow = 0

        while !Task.isCancelled {
            let loopStart = Date.now
            let s = settings
            // The chosen update period is for tracking on target; moving into position doesn't need it.
            var period = Self.positioningPeriod
            // Position is compared at the moment the axes were read; only the feed-forward
            // rate looks ahead, to when the speed command takes effect. Aiming the position
            // ahead as well held the scope ~50 ms in front of the satellite (tens of arc-seconds).
            let latency = 0.05
            guard let current = try await readPosition() else { return }
            let t = (skyPositionDate ?? .now) + (app?.timeShift ?? 0) + timeOffset

            var desired: AxisPosition
            var rates: (Double, Double)
            if let plan {
                if let end = plan.samples.last?.date, t > end {
                    try await special.stop()
                    status = "Pass over"
                    return
                }
                if let target = plan.target(at: t) {
                    // Far behind (tracking started mid-pass, or the mount was elsewhere): jump with
                    // the mount's own slew to where the satellite will be once it gets there.
                    let gap = max(abs(target.axes.primary - current.primary), abs(target.axes.secondary - current.secondary))
                    if mountSlews, gap > 2,
                       let ahead = plan.target(at: t + gap / Self.estimatedSlewRate + 2) {
                        status = "Catching up at full speed…"
                        mountSlews = try await slewAxes(special, to: ahead.axes)
                        continue
                    }
                    desired = target.axes
                    // The speed is held until the next update: use the satellite's speed over that
                    // interval (its middle), which at long periods matters more than the latency.
                    period = gap > 2 ? Self.positioningPeriod : s.trackingPeriod
                    let ahead = plan.target(at: t + latency + period / 2) ?? target
                    rates = (ahead.primaryRate, ahead.secondaryRate)
                    // Far off with no mount slew to catch up with: catch up at full speed.
                    controller.maximumCorrection = gap > 2 ? max(s.maximumAzimuthRate, s.maximumAltitudeRate) : 2
                    status = "Tracking"
                } else {
                    // Before the pass: get to the start of the plan at full speed, then hold.
                    if mountSlews, abs(plan.start.primary - current.primary) > 1 || abs(plan.start.secondary - current.secondary) > 1 {
                        status = "Slewing to start point at full speed…"
                        // If the mount refuses, rate control does the move instead.
                        mountSlews = try await slewAxes(special, to: plan.start)
                        continue
                    }
                    desired = plan.start
                    rates = (0, 0)
                    controller.maximumCorrection = max(s.maximumAzimuthRate, s.maximumAltitudeRate)
                    countDown(to: plan.samples[0].date)
                    status = "Waiting at start point · reaches \(Int(startAltitude))° in \(countdown(plan.samples[0].date.timeIntervalSince(skyNow)))"
                }
            } else {
                // Not a pass: follow the object directly, staying on the current azimuth turn.
                let now = try s.observer.look(at: object.target, AstroTime(t))
                let later = try s.observer.look(at: object.target, AstroTime(t + 1))
                // (The rate over the next second already reaches past the command latency.)
                guard now.altitude > s.minimumAltitude else { throw MountSessionError.belowHorizon }
                let a = axesNear(model.mountFrame(now), model, current.primary)
                let b = axesNear(model.mountFrame(later), model, a.primary)
                desired = a
                rates = (b.primary - a.primary, b.secondary - a.secondary)
                controller.maximumCorrection = max(s.maximumAzimuthRate, s.maximumAltitudeRate)
                let gap = max(abs(a.primary - current.primary), abs(a.secondary - current.secondary))
                period = gap > 2 ? Self.positioningPeriod : s.trackingPeriod
                status = "Tracking"
            }
            desired.primary += model.azimuthSense * azimuthOffset
            // The altitude axis may count down (iOptron's counts from the zenith).
            desired.secondary += model.altitudeSense * altitudeOffset

            // A correction acts for a whole period: 1.5 × error per second over 2 s would
            // overshoot and grow, so keep gain × period under about 0.7.
            controller.gain = min(1.5, 0.7 / period)

            // A lone reading far off the recent level is a glitch, not the mount: hold the planned
            // speed for it rather than kicking the mount to "correct" it.
            let error = max(abs(desired.primary - current.primary), abs(desired.secondary - current.secondary))
            let recent = trace.suffix(20).map { max(abs($0.primaryError), abs($0.secondaryError)) }.sorted()
            let typical = recent.isEmpty ? .infinity : recent[recent.count / 2]
            let glitch = recent.count >= 10 && error > max(4 * typical, 8 / 3600) && error < 0.05 && glitchesInARow == 0
            glitchesInARow = glitch ? glitchesInARow + 1 : 0
            let command = glitch
                ? (primary: rates.0, secondary: rates.1)
                : controller.rates(desired: desired, primaryRate: rates.0, secondaryRate: rates.1, current: current)
            if wouldHitCableStop(current, primaryRate: command.primary) { throw MountSessionError.pastCableStop }
            try await special.setSpeeds(primary: command.primary, secondary: command.secondary)
            record(current: current, desired: desired, feed: rates, command: command, held: glitch)
            // Reading the axes and setting the speeds take part of each period.
            let rest = period - Date.now.timeIntervalSince(loopStart)
            if rest > 0.005 { try await Task.sleep(for: .seconds(rest)) }
        }
    }

    /// Camera tracking: drive the axes at the target's measured speed, plus a correction toward
    /// where it is now. The target's position comes in the mount's own axis coordinates (where
    /// the mount pointed when the frame was taken, plus the offset in the image), so the camera's
    /// delay doesn't leave it off centre: the delay shifts the mount's and the target's motion alike.
    private func runCamera(_ source: CameraTracker) async throws {
        guard let special else { throw MountSessionError.needsUSB }
        var controller = RateController(limits: settings.limits)
        var moving = false
        // The error at the start of a stretch where it hasn't been shrinking. Something fixed in
        // the picture (the camera's text, a hot pixel, a mark on the lens) keeps the same offset
        // however far the mount turns, so following it would run the mount away.
        var stuck: (date: Date, error: Double)?
        while !Task.isCancelled {
            let loopStart = Date.now
            let s = settings
            let period = s.trackingPeriod
            guard let current = try await readPosition() else { return }
            let read = skyPositionDate ?? .now

            guard let estimate = source.estimate(at: read) else {
                if source.isLost {
                    try await special.stop()
                    status = "Lost the target. Click it again to pick it up."
                    return
                }
                // Just picked: measuring its speed before moving.
                if moving { try await special.stop(); moving = false }
                setStatus("Measuring its motion…")
                try await Task.sleep(for: .seconds(period))
                continue
            }
            let unseen = read.timeIntervalSince(estimate.latest)
            if unseen > source.coastLimit {
                try await special.stop()
                status = "Lost the target. Click it again to pick it up."
                return
            }

            // A correction acts for a whole period, and the camera adds its own delay on top,
            // so this stays gentler than Smooth tracking.
            controller.gain = min(1.0, 0.5 / period)
            controller.maximumCorrection = max(s.maximumAzimuthRate, s.maximumAltitudeRate)
            var command = controller.rates(desired: estimate.position, primaryRate: estimate.primaryRate,
                                           secondaryRate: estimate.secondaryRate, current: current)

            // Hold the altitude axis at the mount's limits rather than drive through them.
            let model = s.alignment ?? .iOptronSpecialMode
            let altitude = model.mountFrame(model.sky(for: current)).altitude
            let rising = model.altitudeSense * command.secondary > 0
            let atLimit = (rising && altitude >= s.limits.maximumAltitudeAxis) || (!rising && altitude <= s.limits.minimumAltitudeAxis)
            if atLimit { command.secondary = 0 }
            if wouldHitCableStop(current, primaryRate: command.primary) { throw MountSessionError.pastCableStop }

            let cosAltitude = cos(model.sky(for: current).altitude.radians)
            let error = hypot((estimate.position.primary - current.primary) * cosAltitude,
                              atLimit ? 0 : estimate.position.secondary - current.secondary)
            if error < 0.1 {
                stuck = nil
            } else if let start = stuck, error > 0.7 * start.error {
                if read.timeIntervalSince(start.date) > 8 {
                    try await special.stop()
                    status = "Stopped: the mount turned but the object stayed as far from the aim point. "
                        + "It may be fixed in the picture (the camera's text, a mark on the lens), or the calibration may be off."
                    return
                }
            } else {
                stuck = (read, error)
            }

            try await special.setSpeeds(primary: command.primary, secondary: command.secondary)
            moving = true
            record(current: current, desired: estimate.position, feed: (estimate.primaryRate, estimate.secondaryRate), command: command)
            let off = trace.last.map { $0.error * 60 } ?? 0
            let limit = rising ? s.limits.maximumAltitudeAxis : s.limits.minimumAltitudeAxis
            setStatus(atLimit ? "Held at the altitude limit (\(Int(limit))°). Change it with Point down to."
                      : unseen > 0.3 ? "Out of sight, carrying on along its path…"
                      : String(format: "Camera tracking · %.1f′ off", off))
            let rest = period - Date.now.timeIntervalSince(loopStart)
            if rest > 0.005 { try await Task.sleep(for: .seconds(rest)) }
        }
    }

    /// Sets the status only when it changes, so a fast loop doesn't redraw the screen each pass.
    private func setStatus(_ text: String) {
        if status != text { status = text }
    }

    /// Adds one loop iteration to the trace, keeping the last minute (`traceSpan` when logging).
    private func record(current: AxisPosition, desired: AxisPosition, feed: (Double, Double),
                        command: (primary: Double, secondary: Double), held: Bool = false) {
        let now = Date.now
        let altitude = (settings.alignment ?? AlignmentModel()).sky(for: current).altitude
        trace.append(TraceSample(date: now, read: skyPositionDate ?? now,
                                 loopInterval: lastLoop.map { now.timeIntervalSince($0) } ?? 0,
                                 primary: current.primary, secondary: current.secondary,
                                 primaryError: (desired.primary - current.primary) * cos(altitude.radians),
                                 secondaryError: desired.secondary - current.secondary,
                                 feedPrimary: feed.0, feedSecondary: feed.1,
                                 commandPrimary: command.primary, commandSecondary: command.secondary, held: held))
        lastLoop = now
        // The chart shows a minute; the longer log is only kept for exporting while debugging.
        let span = settings.tracksLog ? Self.traceSpan : 60
        if let first = trace.first, now.timeIntervalSince(first.date) > span {
            trace.removeFirst(trace.prefix { now.timeIntervalSince($0.date) > span }.count)
        }
    }

    /// The trace as CSV: times in seconds from the first sample, angles in degrees, errors in arc-seconds.
    var traceCSV: String {
        guard let start = trace.first?.date else { return "" }
        var lines = ["t,read_t,loop_interval,primary,secondary,primary_error_arcsec,secondary_error_arcsec,feed_primary,feed_secondary,command_primary,command_secondary,held"]
        for s in trace {
            lines.append(String(format: "%.3f,%.3f,%.3f,%.5f,%.5f,%.1f,%.1f,%.5f,%.5f,%.5f,%.5f,%d",
                                s.date.timeIntervalSince(start), s.read.timeIntervalSince(start), s.loopInterval,
                                s.primary, s.secondary, s.primaryError * 3600, s.secondaryError * 3600,
                                s.feedPrimary, s.feedSecondary, s.commandPrimary, s.commandSecondary, s.held ? 1 : 0))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A Special-mode goto with the mount's own full-speed slew (`:T0#`/`:T1#`), in legs that
    /// can't be taken the wrong way round (see `AxisSlew`). Returns within about half a degree;
    /// callers settle the rest under rate control. If the mount refuses a slew, it returns
    /// early and rate control does the whole move.
    /// Returns false if the mount refused its slew command, or the rest of the move has to be
    /// made under rate control (a goal next to the ±180° wrap).
    @discardableResult
    private func slewAxes(_ special: MountClient, to goal: AxisPosition) async throws -> Bool {
        guard !nativeSlewWentWrongWay else { return false }
        let deadline = Date.now + 300
        while !Task.isCancelled {
            guard Date.now < deadline else { throw MountSessionError.couldNotReachStart }
            guard let current = try await readPosition() else { return true }
            if abs(goal.primary - current.primary) < 0.5 && abs(goal.secondary - current.secondary) < 0.5 { return true }
            switch AxisSlew.next(current: current.primary, goal: goal.primary) {
            case .slew(let raw, let unwrapped):
                do {
                    try await special.slew(primary: raw, secondary: goal.secondary)
                } catch is ReplyError {
                    return false
                }
                guard try await waitForArrival(AxisPosition(primary: unwrapped, secondary: goal.secondary), deadline: deadline) else {
                    // Heading away from the target: the mount's idea of that position isn't ours
                    // (it may count turns past north itself). Stop before it reaches the cable,
                    // and leave moves to rate control, where the app owns the turns.
                    try await special.stop()
                    nativeSlewWentWrongWay = true
                    status = String(format: "The mount's slew to %.1f° went the wrong way from %.1f° (now %.1f°); moving under rate control instead",
                                    raw, wrap180(current.primary), wrap180(axes?.primary ?? current.primary))
                    return false
                }
            case .crossWrap(let direction):
                // The mount won't slew across ±180° (or near it), so drive across at full speed
                // until clear of the zone on the far side, or at the goal.
                let rate = direction * settings.maximumAzimuthRate
                let limit = 180 - AxisSlew.defaultWrapMargin
                let side = wrap180(current.primary) < 0 ? -1.0 : 1.0
                if wouldHitCableStop(current, primaryRate: rate) { throw MountSessionError.pastCableStop }
                // One speed command, then position checks only (cheap, and close enough apart
                // at full speed to stop short of the cable).
                try await special.setSpeeds(primary: rate, secondary: 0)
                while !Task.isCancelled {
                    guard Date.now < deadline else { throw MountSessionError.couldNotReachStart }
                    try await Task.sleep(for: .milliseconds(100))
                    guard let now = try await readPosition() else { break }
                    let raw = wrap180(now.primary)
                    if direction * (goal.primary - now.primary) < 0.5 { break }
                    if raw * side < 0 && abs(raw) <= limit { break }
                    if wouldHitCableStop(now, primaryRate: rate) {
                        try await special.stop()
                        throw MountSessionError.pastCableStop
                    }
                }
                try await special.stop()
            case .rateControl:
                // The goal is next to ±180°, where the mount won't slew; the caller's rate
                // control finishes the move.
                return false
            }
        }
        return true
    }

    // MARK: Testing the mount's own slew

    /// Finds out how `:T0#` reads its target: whether it uses the same zero and direction as the
    /// position reading, and what it does across the ±180° wrap (the short way, or the long way
    /// round as if ±180° were two ends). Every move is watched and stopped if it goes more than 2°
    /// the wrong way. Returns a report.
    func testNativeSlew() async -> String {
        guard let special else { return "Connect over USB (Special mode) first." }
        await stopAll()
        var report: [String] = []
        do {
            guard let start = try await readPosition() else { return "No position from the mount." }
            let r0 = wrap180(start.primary)
            report.append(String(format: "Start: azimuth axis reads %+.2f°.", r0))

            // 1. A small move inside the reading's range.
            let near = r0 - 5 > -170 ? r0 - 5 : r0 + 5
            report.append(try await watchSlew(special, to: near, label: "5° slew"))

            // 2. Across the wrap, if the cable stop allows it there.
            let side: Double = r0 >= 0 ? 1 : -1
            // The HAZ46 won't slew within 8° of ±180°, so the approach stops at 172°.
            let before = side * 172, after = -side * 177
            let current = try await readPosition() ?? start
            let wrapGoal = current.primary + wrap180(after - wrap180(current.primary))
            let crossing = AxisPosition(primary: wrapGoal, secondary: current.secondary)
            let model = settings.alignment ?? AlignmentModel()
            let lo = settings.cableStopAzimuth + model.yaw + settings.cableMargin
            let path = [current.primary, current.primary + wrap180(before - wrap180(current.primary)), crossing.primary]
                .map { model.azimuthSense * $0 }
            if path.allSatisfy({ $0 > lo && $0 < lo + 360 - 2 * settings.cableMargin }) {
                report.append(try await watchSlew(special, to: before, label: "Slew to the wrap"))
                report.append(try await watchSlew(special, to: after, label: "6° across the wrap"))
            } else {
                report.append("Skipped the wrap test: the cable stop is in the way from here.")
            }
        } catch {
            try? await special.stop()
            report.append("Stopped: \(describe(error))")
        }
        try? await special.stop()
        let text = report.joined(separator: "\n")
        status = "Slew test finished"
        return text
    }

    /// One `:T0#` slew to a raw reading, watched at 4 Hz for up to 15 s.
    private func watchSlew(_ special: MountClient, to raw: Double, label: String) async throws -> String {
        guard let first = try await readPosition() else { return "\(label): no position." }
        let from = wrap180(first.primary)
        // Which way the short path goes, on the continuous axis.
        let shortWay = wrap180(raw - from)
        try await special.slew(primary: raw, secondary: first.secondary)
        let started = Date.now
        var moved = 0.0
        while Date.now.timeIntervalSince(started) < 15 {
            try await Task.sleep(for: .milliseconds(250))
            guard let now = try await readPosition() else { break }
            moved = now.primary - first.primary
            let reading = wrap180(now.primary)
            if abs(wrap180(reading - raw)) < 0.2 {
                return String(format: "%@ from %+.2f° to %+.2f°: arrived after moving %+.1f° (the short way is %+.1f°). %@", label, from, raw, moved, shortWay,
                              abs(moved - shortWay) < 1 ? "Same frame as the reading." : "A different way round from the reading.")
            }
            if moved * shortWay < 0 && abs(moved) > 2 {
                try await special.stop()
                return String(format: "%@ from %+.2f° to %+.2f°: went the wrong way (%+.1f° when the short way is %+.1f°), stopped.", label, from, raw, moved, shortWay)
            }
        }
        try await special.stop()
        return String(format: "%@ from %+.2f° to %+.2f°: hadn't arrived after 15 s, moved %+.1f°, stopped.", label, from, raw, moved)
    }

    /// Polls (4 Hz) until the axes reach `target`, or stop moving short of it. False if the
    /// mount is moving away from the target instead.
    private func waitForArrival(_ target: AxisPosition, deadline: Date) async throws -> Bool {
        var last: AxisPosition?
        var still = 0
        var closest = Double.infinity
        while !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(250))
            guard let current = try await readPosition() else { return true }
            if abs(target.primary - current.primary) < 0.1 && abs(target.secondary - current.secondary) < 0.1 { return true }
            let distance = max(abs(target.primary - current.primary), abs(target.secondary - current.secondary))
            closest = min(closest, distance)
            if distance > closest + 1 { return false }
            if let last, abs(last.primary - current.primary) < 0.005 && abs(last.secondary - current.secondary) < 0.005 {
                still += 1
                if still >= 4 { return true }
            } else {
                still = 0
            }
            last = current
            guard Date.now < deadline else { throw MountSessionError.couldNotReachStart }
        }
        return true
    }

    /// Axis readings for a mount-frame direction, on the azimuth turn nearest `reference`.
    private func axesNear(_ frame: (azimuth: Double, altitude: Double), _ model: AlignmentModel, _ reference: Double) -> AxisPosition {
        let p = model.axes(mountAzimuth: frame.azimuth, mountAltitude: frame.altitude)
        return AxisPosition(primary: reference + wrap180(p.primary - reference), secondary: p.secondary)
    }

    // MARK: Camera calibration (Special mode)

    /// Runs both axes at these speeds (degrees per second) until told otherwise.
    func moveAxes(primary: Double, secondary: Double) async throws {
        guard let special else { throw MountSessionError.needsUSB }
        try await special.setSpeeds(primary: primary, secondary: secondary)
    }

    func stopMotion() async throws {
        try await special?.stop()
    }

    func currentAxes() async throws -> AxisPosition? {
        try await readPosition()
    }

    // MARK: Alignment

    /// `object` is centred: make the position read it. Special mode moves the zeros of Overpass's
    /// alignment (nothing is sent to the mount, whose own sync commands aren't understood yet).
    /// Normal mode syncs the mount (`:CM#`) and reads the position back, since a sync there once
    /// doubled the position instead of setting it.
    func sync(on object: SkyObject) async {
        let observer = settings.observer
        do {
            if special != nil {
                guard let model = settings.alignment, let current = try await readPosition() else {
                    status = "Align first, or turn on the mount's own alignment"
                    return
                }
                let sky = try observer.look(at: object.target, AstroTime(skyPositionDate ?? .now))
                let shift = angularSeparation(model.sky(for: current).unitVector, sky.unitVector)
                let synced = model.synced(axes: current, to: sky)
                app?.settings.alignment = synced
                unwrapper = AxisUnwrapper(raw: wrap180(current.primary), model: synced, limits: settings.limits)
                recordHeld = false
                remember(sky, now: true)
                _ = try? await readPosition()
                log(String(format: "Sync on %@ (Special mode): P0 %+.4f° P1 %+.4f° = ", object.name, current.primary, current.secondary)
                    + describe(sky) + String(format: ", moved the alignment %.3f°", shift))
                status = String(format: "Synced on %@: the alignment moved %@", object.name, Self.arc(shift))
            } else if let normal {
                await holdStill(normal: normal)
                let before = try await normal.altAz()
                let sky = try observer.look(at: object.target, AstroTime(.now))
                try await normal.sync(altitude: sky.altitude, azimuth: sky.azimuth)
                let after = try await normal.altAz()
                let reads = Horizontal(azimuth: after.azimuth, altitude: after.altitude)
                let off = angularSeparation(reads.unitVector, sky.unitVector)
                log(String(format: "Sync on %@ (Normal mode): :GAC# az %.3f° alt %.3f° → sent ", object.name, before.azimuth, before.altitude)
                    + describe(sky) + " → reads " + describe(reads))
                if off < 0.1 {
                    recordHeld = false
                    normalNeedsSync = false
                    remember(sky, now: true)
                    status = "Synced on \(object.name)"
                } else {
                    status = String(format: "Synced on %@, but the mount now reads %@, %.2f° from it. In the mount log.",
                                    object.name, describe(reads), off)
                }
                _ = try? await currentAltAz(normal)
            }
        } catch {
            status = describe(error)
        }
    }

    /// "12″", "3′ 20″", "1.25°".
    static func arc(_ degrees: Double) -> String {
        let seconds = degrees * 3600
        if seconds < 60 { return String(format: "%.0f″", seconds) }
        if degrees < 1 { return String(format: "%d′ %02d″", Int(seconds) / 60, Int(seconds) % 60) }
        return String(format: "%.2f°", degrees)
    }

    /// Special mode: record that `object` is centred right now.
    func addAlignmentPoint(_ object: SkyObject) async {
        do {
            guard let current = try await readPosition() else { return }
            let sky = try settings.observer.look(at: object.target, AstroTime(.now))
            alignmentPoints.append(AlignmentPoint(targetName: object.name, date: .now, sky: sky, axes: current))
            status = "Recorded \(object.name)"
        } catch {
            status = describe(error)
        }
    }

    func removeAlignmentPoint(at index: Int) {
        alignmentPoints.remove(at: index)
    }

    func clearAlignment() {
        alignmentPoints = []
    }

    /// Special mode, with the axes set to where the tube really points. Entering Special mode
    /// the mount takes its axes from its Normal-mode position, which reads az 0, alt 0 after any
    /// earlier spell in Special mode, so Overpass syncs them (`:S0`/`:S1`): to the mount's own
    /// Normal-mode reading when that's real, otherwise to the last position Overpass saw.
    ///
    /// With "Use the mount's own alignment" (or no star alignment), the axes follow iOptron's
    /// convention (`AlignmentModel.iOptronSpecialMode`: P0 azimuth − 180°, P1 from the zenith);
    /// otherwise the star alignment, so either way the axes and the model agree.
    private func enterSpecialMode(_ client: MountClient, _ transport: MountTransport) async throws -> MountIdentity {
        // The convention replaces a star alignment, but not itself: a sync on it (which moves
        // its zeros) is kept across switches and reconnects.
        if settings.alignment == nil || (settings.captureMountAlignment && !settings.alignmentFromMount), let app {
            app.settings.alignment = .iOptronSpecialMode
            app.settings.alignmentRMS = nil
            app.settings.alignmentStars = 0
            app.settings.alignmentFromMount = true
        }
        let model = settings.alignment ?? .iOptronSpecialMode

        if try await client.identify().isSpecialMode {
            // Already in Special mode, so no switch has reset the axes. Check them against the record.
            // It may still be moving at the last speeds set, if Overpass quit or crashed mid-track.
            try? await client.stop()
            let identity = try await client.identify()
            if let known = knownPointing, let raw = try? await client.positions() {
                let here = model.sky(for: AxisPosition(primary: raw.primary, secondary: raw.secondary))
                let off = angularSeparation(here.unitVector, known.horizontal.unitVector)
                status = off > 0.5
                    ? String(format: "The mount's axes are %.1f° from where Overpass last saw the scope; align, or check nothing moved it", off)
                    : "Special mode: the axes agree with where Overpass last saw the scope"
            }
            return identity
        }

        let normal = NormalModeClient(transport: transport)
        await holdStill(normal: normal)
        let reading = try? await normal.altAz()
        if let reading { log(String(format: "Entering Special mode: :GAC# az %.3f° alt %.3f°", reading.azimuth, reading.altitude)) }
        let identity = try await client.enterSpecialMode()
        await holdStill(special: client)
        // No sync: until the mount's sync commands are understood, only compare and report.
        if let raw = try? await client.positions() {
            let here = model.sky(for: AxisPosition(primary: raw.primary, secondary: raw.secondary))
            log(String(format: "In Special mode: P0 %+.4f° P1 %+.4f° = ", raw.primary, raw.secondary) + describe(here)
                + (knownPointing.map { " (Overpass's record: " + describe($0.horizontal) + ")" } ?? ""))
            if let known = knownPointing {
                let off = angularSeparation(here.unitVector, known.horizontal.unitVector)
                recordHeld = off > 0.5
                status = off > 0.5
                    ? String(format: "The mount's axes are %.1f° from where Overpass last saw the scope; use Set position, or align", off)
                    : "Special mode: the axes agree with where Overpass last saw the scope"
            }
        }
        return identity
    }

    /// Before and after a mode switch: nothing moving and no tracking, so the position carried
    /// across is the one read. Special mode: speeds to zero. Normal mode: tracking off (it can
    /// start sidereal tracking by itself) and any slew stopped. Then wait until two readings
    /// a quarter of a second apart agree, for up to 5 s.
    private func holdStill(special: MountClient? = nil, normal: NormalModeClient? = nil) async {
        if let special { try? await special.stop() }
        if let normal {
            try? await normal.setTracking(false)
            try? await normal.stop()
        }
        var last: (Double, Double)?
        let deadline = Date.now + 5
        while Date.now < deadline {
            let now: (Double, Double)?
            if let special, let p = try? await special.positions() {
                now = (p.primary, p.secondary)
            } else if let normal, let p = try? await normal.altAz() {
                now = (p.azimuth, p.altitude)
            } else {
                now = nil
            }
            if let now, let last, abs(wrap180(now.0 - last.0)) < 0.001, abs(now.1 - last.1) < 0.001 { return }
            last = now
            try? await Task.sleep(for: .milliseconds(250))
        }
        log("Still moving after 5 s before a mode switch")
    }

    /// Just after leaving Special mode, Normal mode reports a placeholder (az 0 alt 0, or az 180
    /// alt 90) for several seconds before the real position, which the mount kept. Waits up to
    /// 20 s for the real one. A sync during the placeholder is added to the kept position.
    @discardableResult
    private func waitForNormalPosition(_ normal: NormalModeClient) async -> Horizontal? {
        let started = Date.now
        while Date.now.timeIntervalSince(started) < 20 {
            if let p = try? await normal.altAz() {
                let placeholder = (abs(p.azimuth) < 1e-6 && abs(p.altitude) < 1e-6)
                    || (abs(p.azimuth - 180) < 1e-6 && abs(p.altitude - 90) < 1e-6)
                if !placeholder {
                    log(String(format: "Normal mode position after %.1f s: az %.3f° alt %.3f°", Date.now.timeIntervalSince(started), p.azimuth, p.altitude))
                    return Horizontal(azimuth: p.azimuth, altitude: p.altitude)
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        log("Normal mode still reported a placeholder position after 20 s")
        return nil
    }

    /// After switching to Normal mode the hand controller asks whether to perform an alignment;
    /// a sync answers it. Once the real position is back (never during the placeholder), sync on
    /// the target if the scope is on it, otherwise on where Overpass knows the scope points, and
    /// read the position back to check.
    private func syncAfterSwitch(_ normal: NormalModeClient, position: Horizontal?) async {
        guard let position else {
            status = "Normal mode, but the mount still reported a placeholder position after 20 s, so it wasn't synced"
            return
        }
        var name = "the scope's position"
        var sky = knownPointing?.horizontal ?? position
        if let target = app?.targetObject, let h = try? settings.observer.look(at: target.target, AstroTime(.now)),
           angularSeparation(h.unitVector, sky.unitVector) < 0.5 {
            name = target.name
            sky = h
        }
        do {
            try await normal.sync(altitude: sky.altitude, azimuth: sky.azimuth)
            let after = try await normal.altAz()
            let reads = Horizontal(azimuth: after.azimuth, altitude: after.altitude)
            let off = angularSeparation(reads.unitVector, sky.unitVector)
            log("Sync after switching to Normal mode, on \(name): mount read " + describe(position) + ", sent " + describe(sky)
                + ", now reads " + describe(reads))
            if off < 0.1 {
                recordHeld = false
                normalNeedsSync = false
                remember(sky, now: true)
                status = "Normal mode, synced on \(name)"
            } else {
                status = String(format: "Normal mode: synced on %@, but the mount now reads %@, %.2f° away. In the mount log.", name, describe(reads), off)
            }
        } catch {
            status = "Normal mode, but the sync failed: \(describe(error))"
        }
    }

    /// A Normal-mode connect: if Overpass last left the mount by taking it out of Special mode,
    /// sync it now (it won't track until then); otherwise just compare with the record.
    private func syncIfLeftSpecialMode(_ normal: NormalModeClient) async {
        guard normalNeedsSync else {
            await checkNormalPosition(normal)
            return
        }
        status = "Waiting for the mount's position…"
        let position = await waitForNormalPosition(normal)
        await syncAfterSwitch(normal, position: position)
    }

    // MARK: Switching modes over USB

    private(set) var isSwitchingMode = false

    /// Set when Overpass took the mount out of Special mode without syncing it (a disconnect):
    /// Normal mode won't track until it's synced, so the next Normal-mode connect does it.
    private var normalNeedsSync: Bool {
        get { AppModel.load("normalNeedsSync", default: false) }
        set { app?.save(newValue, "normalNeedsSync") }
    }

    /// Over USB: Special mode to Normal mode or back, without disconnecting. Tracking stops and
    /// the mount is still before the switch, and the session carries on in the new mode.
    func switchMode() async {
        guard state == .connected, let transport = usbTransport, let current = kind else { return }
        await stopAll()
        isSwitchingMode = true
        pollTask?.cancel()
        pollTask = nil
        defer {
            isSwitchingMode = false
            startPolling()
        }
        do {
            if current.isSpecialMode, let special {
                status = "Switching to Normal mode…"
                await holdStill(special: special)
                if let raw = try? await special.positions() {
                    let model = settings.alignment ?? .iOptronSpecialMode
                    log(String(format: "Switching to Normal mode: P0 %+.4f° P1 %+.4f° = ", raw.primary, raw.secondary)
                        + describe(model.sky(for: AxisPosition(primary: raw.primary, secondary: raw.secondary))))
                }
                _ = try await special.exitSpecialMode()
                let normal = NormalModeClient(transport: transport)
                await holdStill(normal: normal)
                status = "Waiting for the mount's position…"
                let position = await waitForNormalPosition(normal)
                try await normal.configure(latitude: settings.latitude, longitude: settings.longitude)
                await syncAfterSwitch(normal, position: position)
                self.special = nil
                unwrapper = nil
                self.normal = normal
                identity = try await normal.identify()
                kind = .usbNormal
                app?.settings.connection = .usbNormal

            } else if let normal {
                status = "Switching to Special mode…"
                let client = MountClient(transport: transport)
                identity = try await enterSpecialMode(client, transport)
                let raw = try await client.positions()
                unwrapper = AxisUnwrapper(raw: raw.primary, model: settings.alignment ?? .iOptronSpecialMode, limits: settings.limits)
                nativeSlewWentWrongWay = false
                _ = normal
                self.normal = nil
                self.special = client
                kind = .usb
                app?.settings.connection = .usb
                if status.hasPrefix("Switching") { status = "Special mode" }
            }
            _ = try? await readPosition()
        } catch {
            status = "Couldn't switch modes: \(describe(error))"
            log("Mode switch failed: \(describe(error))")
        }
    }

    // MARK: Setting the position

    /// Special mode: sets the axes so the scope reads `pointing` (`:S0`/`:S1`), then reads them
    /// back to check the mount took the values as positions. Returns a report.
    func setPosition(_ pointing: Horizontal) async -> String {
        guard let special else { return "Connect over USB (Special mode) first." }
        await stopAll()
        let model = settings.alignment ?? .iOptronSpecialMode
        let axes = model.axes(for: pointing)
        do {
            let before = try await special.positions()
            try await special.sync(primary: axes.primary, secondary: axes.secondary)
            let after = try await special.positions()
            log(String(format: "Set position to %@: P0 %+.4f° P1 %+.4f° → sent %+.4f° %+.4f° → read %+.4f° %+.4f°",
                       describe(pointing), before.primary, before.secondary, axes.primary, axes.secondary, after.primary, after.secondary))
            guard abs(wrap180(after.primary - axes.primary)) < 0.05, abs(after.secondary - axes.secondary) < 0.05 else {
                return String(format: "The mount didn't take the position as sent: sent P0 %+.3f° P1 %+.3f°, it now reads P0 %+.3f° P1 %+.3f° (it read %+.3f° %+.3f° before). Nothing else was changed; this is in the mount log.",
                              axes.primary, axes.secondary, after.primary, after.secondary, before.primary, before.secondary)
            }
            unwrapper = AxisUnwrapper(raw: after.primary, model: model, limits: settings.limits)
            recordHeld = false
            remember(pointing, now: true)
            _ = try? await readPosition()
            return "The axes now read " + describe(pointing) + "."
        } catch {
            return "Couldn't set the position: \(describe(error))"
        }
    }

    /// Switches Special → Normal → Special without moving or syncing anything, reading the
    /// position at each step, to see what a mode change does to it. Returns a report; every
    /// line also goes to the mount log.
    func testModeSwitching() async -> String {
        guard let special, let transport = usbTransport else { return "Connect over USB (Special mode) first." }
        await stopAll()
        pollTask?.cancel()
        pollTask = nil
        defer { startPolling() }
        let model = settings.alignment ?? .iOptronSpecialMode
        var report: [String] = []
        func note(_ line: String) { report.append(line); log("Mode test: " + line) }
        func axesLine(_ label: String, _ raw: (primary: Double, secondary: Double)) {
            note(String(format: "%@: P0 %+.4f° P1 %+.4f° = ", label, raw.primary, raw.secondary)
                 + describe(model.sky(for: AxisPosition(primary: raw.primary, secondary: raw.secondary))))
        }
        do {
            await holdStill(special: special)
            axesLine("Special mode", try await special.positions())
            _ = try await special.exitSpecialMode()
            let normal = NormalModeClient(transport: transport)
            await holdStill(normal: normal)
            let started = Date.now
            for wait in [0.0, 1, 3, 6, 10, 15] {
                let delay = wait - Date.now.timeIntervalSince(started)
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                let p = try await normal.altAz()
                note(String(format: "Normal mode after %.0f s: :GAC# az %.3f° alt %.3f°", Date.now.timeIntervalSince(started), p.azimuth, p.altitude))
            }
            await holdStill(normal: normal)
            _ = try await special.enterSpecialMode()
            await holdStill(special: special)
            let back = Date.now
            for wait in [0.0, 2] {
                let delay = wait - Date.now.timeIntervalSince(back)
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                axesLine(String(format: "Special mode again after %.0f s", Date.now.timeIntervalSince(back)), try await special.positions())
            }
            if let raw = try? await special.positions() {
                unwrapper = AxisUnwrapper(raw: raw.primary, model: model, limits: settings.limits)
            }
        } catch {
            note("Stopped: \(describe(error))")
        }
        return report.joined(separator: "\n")
    }

    /// Normal mode: compare the mount's position with Overpass's record and report, without
    /// syncing (a sync here added the position twice on the HAZ46).
    private func checkNormalPosition(_ client: NormalModeClient) async {
        guard let p = try? await client.altAz() else { return }
        let reading = Horizontal(azimuth: p.azimuth, altitude: p.altitude)
        log("Normal mode: :GAC# " + describe(reading) + (knownPointing.map { " (Overpass's record: " + describe($0.horizontal) + ")" } ?? ""))
        guard let known = knownPointing else { return }
        let off = angularSeparation(reading.unitVector, known.horizontal.unitVector)
        if off > 0.5 {
            status = String(format: "The mount reads %@, %.1f° from where Overpass last saw the scope (%@)",
                            describe(reading), off, describe(known.horizontal))
        }
    }

    /// Fits and saves the model. One star keeps the previous axis direction; the first alignment needs two.
    func finishAlignment() -> Bool {
        guard let app else { return false }
        // One star keeps the previous model's axis directions; two or more fit them.
        let single = alignmentPoints.count == 1
        let sense = single ? app.settings.alignment?.azimuthSense : nil
        let altitudeSense = single ? app.settings.alignment?.altitudeSense : nil
        guard alignmentPoints.count >= 2 || sense != nil,
              let model = AlignmentModel.fit(alignmentPoints, azimuthSense: sense, altitudeSense: altitudeSense) else { return false }
        app.settings.alignment = model
        app.settings.alignmentRMS = alignmentPoints.count > 2 ? model.rms(alignmentPoints) : nil
        app.settings.alignmentStars = alignmentPoints.count
        app.settings.alignmentFromMount = false
        recordHeld = false
        if let raw = axes?.primary {
            // Re-anchor the turn count to the new model.
            unwrapper = AxisUnwrapper(raw: wrap180(raw), model: model, limits: app.settings.limits)
        }
        status = "Aligned on \(alignmentPoints.count) stars"
        return true
    }

    // MARK: Errors

    private func describe(_ error: Error) -> String {
        switch error {
        case let e as MountSessionError: e.message
        case TransportError.timedOut: "The mount stopped answering."
        case MountClientError.modeDidNotChange: "The mount didn't switch to Special mode. Power it off and on, then connect again."
        case TransportError.closed: "The connection closed."
        case TransportError.cannotOpen(let why): "Couldn't open the port: \(why)"
        case NormalModeError.slewRefused: "The mount refused the slew (below its altitude limit?)"
        default: error.localizedDescription
        }
    }
}

enum MountSessionError: Error {
    case inSpecialMode, noSerialPort, needsWiFi, needsNormalMode, needsUSB, notAligned, notPassive
    case untrackablePass, routeCrossesCableStop, pastCableStop, belowHorizon, couldNotReachStart

    var message: String {
        switch self {
        case .inSpecialMode: "The mount is in Special mode, so WiFi won't work. Connect by USB, or switch it back."
        case .noSerialPort: "Choose the mount's USB port in Settings."
        case .needsWiFi: "Passive and Step tracking need the WiFi connection."
        case .needsNormalMode: "Connect over WiFi or USB Normal mode to read the mount's location."
        case .needsUSB: "Smooth tracking needs the USB connection (Special mode)."
        case .notAligned: "Align on at least two stars first."
        case .notPassive: "The mount can't track this by itself; use Step or Smooth."
        case .untrackablePass: "This pass crosses the cable stop or exceeds the altitude limits."
        case .routeCrossesCableStop: "Stopped: that move would swing through the cable stop."
        case .pastCableStop: "Stopped at the cable stop."
        case .belowHorizon: "It's below your horizon."
        case .couldNotReachStart: "Stopped: the mount didn't reach the start point within 5 minutes."
        }
    }
}
