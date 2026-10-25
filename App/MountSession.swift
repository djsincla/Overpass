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
    private(set) var skyPosition: Horizontal?
    /// Raw axes (Special mode), primary unwrapped.
    private(set) var axes: AxisPosition?
    private(set) var status = ""
    private(set) var trackingName: String?
    /// What's being tracked, for the camera guider.
    private(set) var trackingObject: SkyObject?
    private(set) var trackingMode: TrackingMode?
    var isTracking: Bool { trackingTask != nil }

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
    private var pollTask: Task<Void, Never>?
    private var trackingTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Never>?
    /// True while moving to a pass's start point.
    var isPreparing: Bool { prepareTask != nil }

    private var settings: Settings { app?.settings ?? Settings() }

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
                identity = try await client.enterSpecialMode()
                let raw = try await client.positions()
                unwrapper = AxisUnwrapper(raw: raw.primary, model: s.alignment ?? AlignmentModel(), limits: s.limits)
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

    @discardableResult
    private func readPosition() async throws -> AxisPosition? {
        if let normal {
            let p = try await normal.altAz()
            skyPosition = Horizontal(azimuth: p.azimuth, altitude: p.altitude)
            return nil
        }
        guard let special, var unwrapper else { return nil }
        let raw = try await special.positions()
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
                case .up: (0, jogSpeed)
                case .down: (0, -jogSpeed)
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
                case .up: (0, speed)
                case .down: (0, -speed)
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
        guard let point = pass.startPoint(above: startAltitude), point.date > .now else { return nil }
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
                    status = "Waiting at az \(Int(point.position.azimuth))°, alt \(Int(point.position.altitude))° · reaches it in \(countdown(point.date.timeIntervalSinceNow))"
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
        var controller = RateController(limits: s.limits)
        controller.maximumCorrection = max(s.maximumAzimuthRate, s.maximumAltitudeRate)
        let deadline = Date.now + 300
        while !Task.isCancelled {
            guard let current = try await readPosition() else { return }
            let goal = plan.start
            if abs(goal.primary - current.primary) < 0.02 && abs(goal.secondary - current.secondary) < 0.02 {
                try await special.stop()
                status = "Ready at the start point · rises in \(countdown(plan.samples[0].date.timeIntervalSinceNow))"
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
        try await goto(normal, to: try observer.look(at: object.target, AstroTime(.now)))

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
            let (ra, dec) = try observer.topocentricRADec(of: object.target, at: AstroTime(.now))
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
            let interval = max(0.5, s.stepInterval)
            if let pass, tick > pass.end.date + 5 {
                status = "Pass over"
                return
            }
            var aim = try StepTracking.aim(at: object.target, observer: s.observer, now: tick + timeOffset,
                                           lead: StepTracking.defaultLead(interval: interval))
            aim.azimuth = normalizedDegrees(aim.azimuth + azimuthOffset)
            aim.altitude += altitudeOffset

            if aim.altitude < startAltitude {
                // Before the pass: wait where it first reaches the start elevation, once.
                if let pass, let point = pass.startPoint(above: startAltitude), tick < point.date, !waitingAtRise {
                    status = "Slewing to start point at full speed…"
                    try await goto(normal, to: point.position)
                    waitingAtRise = true
                }
                status = pass.flatMap { $0.startPoint(above: startAltitude) }
                    .map { "Waiting at start point · reaches \(Int(startAltitude))° in \(countdown($0.date.timeIntervalSinceNow))" }
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
        let p = try await normal.altAz()
        let h = Horizontal(azimuth: p.azimuth, altitude: p.altitude)
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

        while !Task.isCancelled {
            let s = settings
            let latency = 0.05
            let t = Date.now + timeOffset + latency
            guard let current = try await readPosition() else { return }

            var desired: AxisPosition
            var rates: (Double, Double)
            if let plan {
                if let end = plan.samples.last?.date, t > end {
                    try await special.stop()
                    status = "Pass over"
                    return
                }
                if let target = plan.target(at: t) {
                    desired = target.axes
                    rates = (target.primaryRate, target.secondaryRate)
                    controller.maximumCorrection = 2
                    status = "Tracking"
                } else {
                    // Before the pass: drive to the start of the plan and hold.
                    desired = plan.start
                    rates = (0, 0)
                    controller.maximumCorrection = max(s.maximumAzimuthRate, s.maximumAltitudeRate)
                    status = "Waiting at start point · reaches \(Int(startAltitude))° in \(countdown(plan.samples[0].date.timeIntervalSinceNow))"
                }
            } else {
                // Not a pass: follow the object directly, staying on the current azimuth turn.
                let now = try s.observer.look(at: object.target, AstroTime(t))
                let later = try s.observer.look(at: object.target, AstroTime(t + 1))
                guard now.altitude > s.minimumAltitude else { throw MountSessionError.belowHorizon }
                let a = axesNear(model.mountFrame(now), model, current.primary)
                let b = axesNear(model.mountFrame(later), model, a.primary)
                desired = a
                rates = (b.primary - a.primary, b.secondary - a.secondary)
                controller.maximumCorrection = max(s.maximumAzimuthRate, s.maximumAltitudeRate)
                status = "Tracking"
            }
            desired.primary += model.azimuthSense * azimuthOffset
            desired.secondary += altitudeOffset

            let command = controller.rates(desired: desired, primaryRate: rates.0, secondaryRate: rates.1, current: current)
            if wouldHitCableStop(current, primaryRate: command.primary) { throw MountSessionError.pastCableStop }
            try await special.setSpeeds(primary: command.primary, secondary: command.secondary)
            try await Task.sleep(for: .milliseconds(100))
        }
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

    /// Fits and saves the model. One star keeps the previous axis direction; the first alignment needs two.
    func finishAlignment() -> Bool {
        guard let app else { return false }
        let sense = alignmentPoints.count == 1 ? app.settings.alignment?.azimuthSense : nil
        guard alignmentPoints.count >= 2 || sense != nil,
              let model = AlignmentModel.fit(alignmentPoints, azimuthSense: sense) else { return false }
        app.settings.alignment = model
        app.settings.alignmentRMS = alignmentPoints.count > 2 ? model.rms(alignmentPoints) : nil
        app.settings.alignmentStars = alignmentPoints.count
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
