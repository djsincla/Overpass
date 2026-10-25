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
    var effectiveMode: TrackingMode { kind == .usb ? .smooth : preferredMode }

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

    var availableModes: [TrackingMode] {
        switch kind {
        case .wifi: [.passive, .step]
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
                normal = client
                identity = id
            case .usb:
                let transport: MountTransport
                #if os(macOS)
                guard !s.serialPath.isEmpty else { throw MountSessionError.noSerialPort }
                transport = try SerialTransport(path: s.serialPath)
                #else
                let relay = TCPTransport(host: s.relayHost, port: UInt16(s.relayPort), timeout: 3)
                try await relay.open()
                tcp = relay
                transport = relay
                #endif
                let client = MountClient(transport: transport)
                if s.captureMountAlignment {
                    identity = try await captureMountAlignment(client, transport)
                } else {
                    identity = try await client.enterSpecialMode()
                }
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
            _ = try? await special.exitSpecialMode()
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
        unwrapper = nil
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
                try? await Task.sleep(for: .milliseconds(500))
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
        let model = settings.alignment ?? AlignmentModel()
        skyPosition = model.sky(for: current)
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
        await cancelTracking()
        try? await normal?.stop()
        try? await special?.stop()
        status = "Stopped"
    }

    private func cancelTracking() async {
        prepareTask?.cancel()
        prepareTask = nil
        trackingTask?.cancel()
        trackingTask = nil
        trackingName = nil
        trackingObject = nil
        trackingMode = nil
    }

    // MARK: Tracking

    func track(_ object: SkyObject, mode: TrackingMode, pass: SatellitePass?) async {
        await stopAll()
        trackingName = object.name
        trackingObject = object
        trackingMode = mode
        trace = []
        lastLoop = nil
        status = "Starting…"
        trackingTask = Task {
            do {
                switch mode {
                case .passive: try await runPassive(object)
                case .step: try await runStep(object, pass: pass)
                case .smooth: try await runSmooth(object, pass: pass)
                }
            } catch is CancellationError {
            } catch {
                status = describe(error)
                try? await normal?.stop()
                try? await special?.stop()
            }
            if !Task.isCancelled {
                trackingTask = nil
                trackingName = nil
                trackingObject = nil
                trackingMode = nil
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
        // The Moon's parallax changes as it moves, so re-centre it every few minutes.
        repeat {
            let (ra, dec) = try observer.topocentricRADec(of: object.target, at: AstroTime(skyNow))
            try await normal.slew(rightAscension: ra, declination: dec, rate: rate)
            status = "Mount tracking at \(rate == .lunar ? "lunar" : rate == .solar ? "solar" : "sidereal") rate"
            if how != .lunar { return }
            try await Task.sleep(for: .seconds(300))
        } while !Task.isCancelled
    }

    private func runStep(_ object: SkyObject, pass: SatellitePass?) async throws {
        guard let normal else { throw MountSessionError.needsWiFi }
        var waitingAtRise = false
        while !Task.isCancelled {
            let s = settings
            let tick = Date.now
            let sky = skyNow
            let interval = max(0.5, s.stepInterval)
            if let pass, sky > pass.end.date + 5 {
                status = "Pass over"
                return
            }
            var aim = try StepTracking.aim(at: object.target, observer: s.observer, now: sky + timeOffset,
                                           lead: StepTracking.defaultLead(interval: interval))
            aim.azimuth = normalizedDegrees(aim.azimuth + azimuthOffset)
            aim.altitude += altitudeOffset

            if aim.altitude < startAltitude {
                // Before the pass: wait where it first reaches the start elevation, once.
                if let pass, let point = pass.startPoint(above: startAltitude), sky < point.date, !waitingAtRise {
                    status = "Slewing to start point at full speed…"
                    try await goto(normal, to: point.position)
                    waitingAtRise = true
                }
                status = pass.flatMap { $0.startPoint(above: startAltitude) }
                    .map { "Waiting at start point · reaches \(Int(startAltitude))° in \(countdown($0.date.timeIntervalSince(skyNow)))" }
                    ?? "Below \(Int(startAltitude))°"
            } else {
                // Read at the end of the last step; good enough to tell which way round to go.
                let here = if let skyPosition { skyPosition } else { try await currentAltAz(normal) }
                guard let legs = route(from: here, to: aim) else { throw MountSessionError.inCableMargin }
                if legs.count > 1 {
                    // The track crosses the cable stop: go back round the other way, then carry on.
                    try await goto(normal, to: aim, from: here)
                    continue
                }
                do {
                    try await normal.slew(altitude: aim.altitude, azimuth: aim.azimuth)
                    status = String(format: "Stepping every %.1f s · az %.1f° alt %.1f°", interval, aim.azimuth, aim.altitude)
                } catch NormalModeError.slewRefused {
                    status = "Mount refused the step (below its altitude limit?)"
                }
            }
            _ = try? await readPosition()
            let wait = interval - Date.now.timeIntervalSince(tick)
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        }
    }

    /// Set once per connection: gotos at the mount's maximum speed.
    private var maximumSpeedSet = false

    /// Smooth tracking loop period, seconds.
    private static let trackingPeriod = 0.1

    /// The HAZ46 goes to about 6°/s at its top speed; slightly under, so the quiet wait errs long.
    private static let estimatedSlewRate = 5.0

    /// A normal-mode goto at full speed that never swings through the cable stop. The mount
    /// takes the shorter way round by itself, so when the allowed way is the long way, it's
    /// sent in legs (each under 180°) that all turn the same way.
    private func goto(_ normal: NormalModeClient, to target: Horizontal, from start: Horizontal? = nil) async throws {
        let s = settings
        var here = if let start { start } else { try await currentAltAz(normal) }
        guard let legs = route(from: here, to: target) else { throw MountSessionError.inCableMargin }
        let message = status
        for (i, leg) in legs.enumerated() {
            if legs.count > 1 {
                let way = wrap180(leg.azimuth - here.azimuth) > 0 ? "clockwise" : "anticlockwise"
                status = "Going round the cable stop (\(Int(s.cableStopAzimuth))°) \(way) · leg \(i + 1) of \(legs.count)"
            }
            try await slewAndWait(normal, from: here, to: leg)
            here = leg
        }
        if legs.count > 1 { status = message }
    }

    /// Normal mode: the cable stop's allowed route from here to there, as gotos.
    private func route(from: Horizontal, to: Horizontal) -> [Horizontal]? {
        CableRoute.legs(from: from, to: to, stop: settings.cableStopAzimuth, margin: settings.cableMargin)
    }

    private func currentAltAz(_ normal: NormalModeClient) async throws -> Horizontal {
        let asked = Date.now
        let p = try await normal.altAz()
        let h = Horizontal(azimuth: p.azimuth, altitude: p.altitude)
        skyPositionDate = positionTime(asked: asked, answered: .now)
        skyPosition = h
        return h
    }

    /// One goto at full speed, waited out. Any command mid-slew makes the mount hesitate, so the
    /// app stays silent for about as long as the slew should take, then checks once a second.
    private func slewAndWait(_ normal: NormalModeClient, from start: Horizontal, to target: Horizontal) async throws {
        if !maximumSpeedSet {
            try await normal.setMaximumSlewSpeed(9)
            maximumSpeedSet = true
        }
        try await normal.slew(altitude: target.altitude, azimuth: target.azimuth)
        let distance = max(abs(wrap180(target.azimuth - start.azimuth)), abs(target.altitude - start.altitude))
        // Plus time to speed up and slow down.
        try await Task.sleep(for: .seconds(distance / Self.estimatedSlewRate + 2))
        let deadline = Date.now + 180
        while try await normal.isSlewing() {
            guard Date.now < deadline else { throw MountSessionError.couldNotReachStart }
            try await Task.sleep(for: .seconds(1))
        }
        _ = try await currentAltAz(normal)
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
                    let ahead = plan.target(at: t + latency) ?? target
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
                status = "Tracking"
            }
            desired.primary += model.azimuthSense * azimuthOffset
            // The altitude axis may count down (iOptron's counts from the zenith).
            desired.secondary += model.altitudeSense * altitudeOffset

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
            // Ten updates a second; reading the axes and setting the speeds take part of that.
            let rest = Self.trackingPeriod - Date.now.timeIntervalSince(loopStart)
            if rest > 0.005 { try await Task.sleep(for: .seconds(rest)) }
        }
    }

    /// Adds one loop iteration to the trace, keeping the last `traceSpan` seconds.
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
        if let first = trace.first, now.timeIntervalSince(first.date) > Self.traceSpan {
            trace.removeFirst(trace.prefix { now.timeIntervalSince($0.date) > Self.traceSpan }.count)
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
    /// Returns false if the mount refused its slew command.
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
                // A few degrees under rate control carries it across the ±180° reading wrap.
                let rate = direction * min(settings.maximumAzimuthRate, 2)
                if wouldHitCableStop(current, primaryRate: rate) { throw MountSessionError.pastCableStop }
                try await special.setSpeeds(primary: rate, secondary: 0)
                try await Task.sleep(for: .seconds(1.5))
                try await special.stop()
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
            let before = side * 177, after = -side * 177
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

    /// Normal mode: tell the mount the object is centred, so its own model improves.
    func sync(on object: SkyObject) async {
        guard let normal else { return }
        do {
            let h = try settings.observer.look(at: object.target, AstroTime(.now))
            try await normal.sync(altitude: h.altitude, azimuth: h.azimuth)
            status = "Synced on \(object.name)"
        } catch {
            status = describe(error)
        }
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

    /// The mount's own alignment, so Smooth tracking can start without a star alignment.
    ///
    /// In Special mode the HAZ reports its axes in its own aligned coordinates: P0 is azimuth
    /// − 180° and P1 the zenith distance (`AlignmentModel.iOptronSpecialMode`). So when the
    /// mount is already in Special mode, that convention is used as it is. From Normal mode,
    /// where the mount was pointing (`:GAC#`) is read first and paired with the axes, which also
    /// corrects any small zero offset. The Normal-mode position resets to 0, 0 after the mount
    /// has been in Special mode, so that reading is only used when it's real, and the mode is
    /// never switched just to read it.
    private func captureMountAlignment(_ client: MountClient, _ transport: MountTransport) async throws -> MountIdentity {
        status = "Reading the mount's alignment…"
        var pointing: Horizontal?
        if try await client.identify().isSpecialMode == false {
            let p = try await NormalModeClient(transport: transport).altAz()
            if abs(p.altitude) > 1e-6 || abs(p.azimuth) > 1e-6 { pointing = Horizontal(azimuth: p.azimuth, altitude: p.altitude) }
        }
        let identity = try await client.enterSpecialMode()
        let raw = try await client.positions()
        guard let app else { return identity }
        let convention = AlignmentModel.iOptronSpecialMode
        var model = convention
        if let pointing, let fitted = AlignmentModel.fromMount(sky: pointing, axes: AxisPosition(primary: raw.primary, secondary: raw.secondary),
                                                              azimuthSense: convention.azimuthSense,
                                                              altitudeSense: convention.altitudeSense) {
            model = fitted
        }
        app.settings.alignment = model
        app.settings.alignmentRMS = nil
        app.settings.alignmentStars = 0
        app.settings.alignmentFromMount = true
        status = pointing == nil
            ? "Using the mount's own coordinates (P0 azimuth − 180°, P1 from the zenith)"
            : String(format: "Using the mount's alignment (az zero %+.2f°, alt zero %+.2f°)", wrap180(model.yaw), model.altitudeOffset)
        return identity
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
    case inSpecialMode, noSerialPort, needsWiFi, needsUSB, notAligned, notPassive
    case untrackablePass, routeCrossesCableStop, inCableMargin, pastCableStop, belowHorizon, couldNotReachStart

    var message: String {
        switch self {
        case .inSpecialMode: "The mount is in Special mode, so WiFi won't work. Connect by USB, or switch it back."
        case .noSerialPort: "Choose the mount's USB port in Settings."
        case .needsWiFi: "Passive and Step tracking need the WiFi connection."
        case .needsUSB: "Smooth tracking needs the USB connection (Special mode)."
        case .notAligned: "Align on at least two stars first."
        case .notPassive: "The mount can't track this by itself; use Step or Smooth."
        case .untrackablePass: "This pass crosses the cable stop or exceeds the altitude limits."
        case .routeCrossesCableStop: "Stopped: that move would swing through the cable stop."
        case .inCableMargin: "Can't point there: it's inside the margin around the cable stop (Settings → Cable stop)."
        case .pastCableStop: "Stopped at the cable stop."
        case .belowHorizon: "It's below your horizon."
        case .couldNotReachStart: "Stopped: the mount didn't reach the start point within 5 minutes."
        }
    }
}
