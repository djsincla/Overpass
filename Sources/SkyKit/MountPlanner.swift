import Foundation

/// Physical limits of the mount and its cabling.
public struct MountLimits: Sendable {
    /// Sky azimuth the mount must never rotate through, so cables can't wind up.
    /// The cables should be neutral when the scope points the opposite way.
    public var cableStopAzimuth: Double = 0
    /// Keep at least this far from the stop, degrees.
    public var cableMargin: Double = 5
    /// Mount-frame altitude limits. A maximum above 90° allows pointing over the top,
    /// which needs the tube to clear the mount and tripod — check this on the hardware.
    public var minimumAltitudeAxis: Double = -5
    public var maximumAltitudeAxis: Double = 90
    /// Degrees per second. Measure the real values with `:Q0#` / `:Q1#`.
    public var maximumAzimuthRate: Double = 6
    public var maximumAltitudeRate: Double = 6

    public init() {}

    public var allowsOverTheTop: Bool { maximumAltitudeAxis > 90 }
}

public struct PlannedSample: Sendable {
    public let date: Date
    /// Unwrapped axis positions, ready for the mount.
    public let axes: AxisPosition
    /// How far the planned pointing is from the target, degrees.
    public let error: Double
}

public struct MountPlan: Sendable {
    public enum Orientation: Sendable, Equatable {
        /// Ordinary alt-az tracking.
        case normal
        /// Whole pass tracked with the tube past the zenith (azimuth + 180°, altitude 180° − alt).
        case overTheTop
        /// Normal for one half of the pass, over the top for the other; ideal for overhead passes.
        case flipAtCulmination
    }

    public let orientation: Orientation
    public let samples: [PlannedSample]
    public let maximumError: Double
    /// Time spent further than the tolerance from the target.
    public let secondsOffTarget: TimeInterval

    public var start: AxisPosition { samples[0].axes }
}

/// Turns a predicted pass into an axis trajectory the mount can follow without crossing the
/// cable stop or exceeding its speed limits.
///
/// Every alt-az mount has a blind spot at the zenith: a pass that misses it by δ needs an azimuth
/// swing at about (sky speed)/δ. Flipping over the top doesn't remove that; it helps passes that go
/// right through the zenith, and passes whose azimuth range would cross the cable stop. The planner
/// tries each orientation, rate-limits the result (cutting the corner around the zenith) and keeps
/// whichever stays on target longest.
public struct MountPlanner: Sendable {
    public var limits: MountLimits
    public var model: AlignmentModel
    /// Pointing error that still counts as on target, degrees (about half the field of view).
    public var tolerance: Double = 0.1

    public init(limits: MountLimits = MountLimits(), model: AlignmentModel = AlignmentModel()) {
        self.limits = limits
        self.model = model
    }

    /// The best feasible plan, or nil if the pass can't be tracked within the limits.
    public func plan(_ track: [PassSample]) -> MountPlan? {
        candidates(track).min { a, b in
            if a.secondsOffTarget != b.secondsOffTarget { return a.secondsOffTarget < b.secondsOffTarget }
            if abs(a.maximumError - b.maximumError) > 1e-6 { return a.maximumError < b.maximumError }
            return rank(a.orientation) < rank(b.orientation)
        }
    }

    func rank(_ o: MountPlan.Orientation) -> Int {
        switch o {
        case .normal: 0
        case .overTheTop: 1
        case .flipAtCulmination: 2
        }
    }

    /// All plans that respect the limits.
    public func candidates(_ track: [PassSample]) -> [MountPlan] {
        guard track.count > 1 else { return [] }
        let frames = track.map { model.mountFrame($0.position) }
        let peak = frames.indices.max { frames[$0].altitude < frames[$1].altitude }!

        var patterns: [(MountPlan.Orientation, (Int) -> Bool)] = [(.normal, { _ in false })]
        if limits.allowsOverTheTop {
            patterns.append((.overTheTop, { _ in true }))
            patterns.append((.flipAtCulmination, { $0 > peak }))
            patterns.append((.flipAtCulmination, { $0 < peak }))
        }

        return patterns.flatMap { orientation, flipped -> [MountPlan] in
            let raw = frames.indices.map { i in
                flipped(i) ? (frames[i].azimuth + 180, 180 - frames[i].altitude) : (frames[i].azimuth, frames[i].altitude)
            }
            let unwrapped = unwrap(raw.map(\.0))
            // A big jump (a pass right through the zenith, or a flip) could be taken either way
            // round; try both, and let the cable stop and errors decide.
            let steps = unwrapped.indices.dropFirst().map { abs(unwrapped[$0] - unwrapped[$0 - 1]) }
            let jump = steps.indices.max { steps[$0] < steps[$1] }.map { $0 + 1 }
            let shifts: [Double] = jump != nil && steps[jump! - 1] > 90 ? [0, 360, -360] : [0]
            return shifts.compactMap { shift in
                let azimuths = unwrapped.indices.map { i in i >= (jump ?? 0) ? unwrapped[i] + shift : unwrapped[i] }
                return build(orientation, track, azimuths: azimuths, altitudes: raw.map(\.1))
            }
        }
    }

    func unwrap(_ angles: [Double]) -> [Double] {
        var out = [angles[0]]
        for a in angles.dropFirst() { out.append(out.last! + wrap180(a - out.last!)) }
        return out
    }

    func build(_ orientation: MountPlan.Orientation, _ track: [PassSample],
               azimuths: [Double], altitudes: [Double]) -> MountPlan? {
        let dates = track.map(\.date)
        var az = rateLimited(azimuths, dates, limits.maximumAzimuthRate)
        let alt = rateLimited(altitudes, dates, limits.maximumAltitudeRate)

        // Choose the turn that keeps the whole pass between the cable stops.
        let stop = limits.cableStopAzimuth + model.yaw
        let lo = stop + limits.cableMargin, hi = stop + 360 - limits.cableMargin
        let turn = 360 * ((lo - az.min()!) / 360).rounded(.up)
        guard az.max()! + turn < hi else { return nil }
        az = az.map { $0 + turn }

        guard alt.allSatisfy({ (limits.minimumAltitudeAxis...limits.maximumAltitudeAxis).contains($0) }) else {
            return nil
        }

        let samples = track.indices.map { i -> PlannedSample in
            let axes = model.axes(mountAzimuth: az[i], mountAltitude: alt[i])
            return PlannedSample(date: dates[i], axes: axes,
                                 error: angularSeparation(model.sky(for: axes).unitVector, track[i].position.unitVector))
        }
        var off: TimeInterval = 0
        for i in samples.indices.dropFirst() where samples[i].error > tolerance || samples[i - 1].error > tolerance {
            off += dates[i].timeIntervalSince(dates[i - 1])
        }
        return MountPlan(orientation: orientation, samples: samples,
                         maximumError: samples.map(\.error).max()!, secondsOffTarget: off)
    }

    /// Limits speed without lagging: the average of a forward pass (which lags) and a backward pass
    /// (which leads) is centred on the target, and still within the limit.
    func rateLimited(_ values: [Double], _ dates: [Date], _ rate: Double) -> [Double] {
        var forward = values, backward = values
        for i in values.indices.dropFirst() {
            let step = rate * dates[i].timeIntervalSince(dates[i - 1])
            forward[i] = min(max(values[i], forward[i - 1] - step), forward[i - 1] + step)
        }
        for i in values.indices.reversed().dropFirst() {
            let step = rate * dates[i + 1].timeIntervalSince(dates[i])
            backward[i] = min(max(values[i], backward[i + 1] - step), backward[i + 1] + step)
        }
        return zip(forward, backward).map { ($0 + $1) / 2 }
    }
}
