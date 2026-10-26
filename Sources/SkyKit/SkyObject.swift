import Foundation

/// Anything the user can select, highlight and track.
public enum SkyObject: Identifiable, Sendable {
    case satellite(SatelliteTarget)
    case body(SolarSystemBody)
    case star(Star)

    /// Stable across launches: "sat:25544", "body:moon", "star:Vega".
    public var id: String {
        switch self {
        case .satellite(let s): "sat:\(s.noradID)"
        case .body(let b): "body:\(b.rawValue)"
        case .star(let s): "star:\(s.name)"
        }
    }

    public var name: String {
        switch self {
        case .satellite(let s): s.name
        case .body(let b): b.name
        case .star(let s): s.name
        }
    }

    public var target: any Target {
        switch self {
        case .satellite(let s): s
        case .body(let b): b
        case .star(let s): s
        }
    }

    public var isSatellite: Bool {
        if case .satellite = self { return true }
        return false
    }

    public var isSun: Bool {
        if case .body(.sun) = self { return true }
        return false
    }

    /// How the mount can follow this object by itself in passive mode, if at all.
    public var passiveTracking: PassiveTracking? {
        switch self {
        case .body(.sun): .solar
        case .body(.moon): .lunar
        case .body, .star: .sidereal
        case .satellite(let s): s.isGeostationary ? .holdPosition : nil
        }
    }
}

public enum PassiveTracking: Sendable, Equatable {
    case sidereal, lunar, solar
    /// Point once and stop tracking (geostationary satellites).
    case holdPosition
}

extension SatelliteTarget {
    /// Close enough to geostationary that a fixed alt-az pointing holds it.
    public var isGeostationary: Bool {
        abs(period - 1436.07) < 10 && satellite.tle.e₀ < 0.01 && satellite.tle.i₀.degrees < 3
    }
}

extension Observer {
    /// Right ascension and declination as seen from here (equator and equinox of date), in degrees.
    /// Differs from geocentric by up to ~1° for the Moon, which matters when the mount tracks alone.
    public func topocentricRADec(of target: some Target, at time: AstroTime) throws -> (ra: Double, dec: Double) {
        let local = try target.earthFixedPosition(at: time) - position
        let s = (Mat3.rotZ(time.gast) * local).spherical
        return (s.longitude, s.latitude)
    }
}

// MARK: Step tracking (normal mode)

public enum StepTracking {
    /// Where to send the mount now so it arrives near the middle of the next interval.
    /// `lead` should be about half the interval plus the time a short slew takes.
    public static func aim(at target: some Target, observer: Observer, now: Date, lead: TimeInterval,
                           deltaT: TimeInterval = AstroTime.defaultDeltaT) throws -> Horizontal {
        try observer.look(at: target, AstroTime(now + lead, deltaT: deltaT))
    }

    /// The default lead for an interval: half of it, plus about half a second for the slew itself.
    public static func defaultLead(interval: TimeInterval) -> TimeInterval { interval / 2 + 0.5 }

    /// The mount picks its own slew route in normal mode; assuming it takes the shorter way
    /// round, would going from `from` to `to` pass through the cable stop?
    public static func shorterRouteCrossesStop(from: Double, to: Double, stop: Double, margin: Double = 0) -> Bool {
        let delta = wrap180(to - from)
        let toStop = wrap180(stop - from)
        guard delta != 0 else { return false }
        // Same direction, and the stop (widened by the margin) lies within the swing.
        if delta > 0 { return toStop > -margin && toStop < delta + margin }
        return toStop < margin && toStop > delta - margin
    }
}

// MARK: Smooth tracking (special mode)

extension MountPlan {
    /// Axis positions and rates (degrees, degrees per second) at `date`, on a cubic through the
    /// samples. The rate changes smoothly from moment to moment; straight lines between samples
    /// would hold it constant for each sample interval and step it at every sample, which near
    /// the top of a pass means a jolt every second.
    public func target(at date: Date) -> (axes: AxisPosition, primaryRate: Double, secondaryRate: Double)? {
        guard let first = samples.first, let last = samples.last, date >= first.date, date <= last.date else { return nil }
        // The last sample at or before `date` (binary search).
        var lo = 0, hi = samples.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if samples[mid].date <= date { lo = mid } else { hi = mid - 1 }
        }
        let i = min(lo, samples.count - 2)
        guard i >= 0 else { return (first.axes, 0, 0) }
        let a = samples[i], b = samples[i + 1]
        let dt = b.date.timeIntervalSince(a.date)
        guard dt > 0 else { return (a.axes, 0, 0) }
        let u = min(max(date.timeIntervalSince(a.date) / dt, 0), 1)

        func slope(_ k: Int, _ axis: KeyPath<AxisPosition, Double>) -> Double {
            let before = samples[max(k - 1, 0)], after = samples[min(k + 1, samples.count - 1)]
            let span = after.date.timeIntervalSince(before.date)
            return span > 0 ? (after.axes[keyPath: axis] - before.axes[keyPath: axis]) / span : 0
        }
        // Cubic Hermite: positions at both ends, slopes from the neighbouring samples.
        func hermite(_ axis: KeyPath<AxisPosition, Double>) -> (value: Double, rate: Double) {
            let p0 = a.axes[keyPath: axis], p1 = b.axes[keyPath: axis]
            let m0 = slope(i, axis) * dt, m1 = slope(i + 1, axis) * dt
            let u2 = u * u, u3 = u2 * u
            let value = (2 * u3 - 3 * u2 + 1) * p0 + (u3 - 2 * u2 + u) * m0 + (-2 * u3 + 3 * u2) * p1 + (u3 - u2) * m1
            let derivative = (6 * u2 - 6 * u) * p0 + (3 * u2 - 4 * u + 1) * m0 + (-6 * u2 + 6 * u) * p1 + (3 * u2 - 2 * u) * m1
            return (value, derivative / dt)
        }
        let p = hermite(\.primary), s = hermite(\.secondary)
        return (AxisPosition(primary: p.value, secondary: s.value), p.rate, s.rate)
    }
}

/// Feed-forward plus proportional correction: the planned rate does the tracking, and the
/// error term pulls the mount back onto the plan.
public struct RateController: Sendable {
    /// Correction gain, per second: an error of 0.1° adds 0.1 × gain °/s.
    public var gain: Double = 1.5
    /// Cap on the correction, so a big error doesn't trigger a violent move.
    public var maximumCorrection: Double = 2
    public var limits: MountLimits

    public init(limits: MountLimits) {
        self.limits = limits
    }

    /// Commanded axis rates in degrees per second.
    public func rates(desired: AxisPosition, primaryRate: Double, secondaryRate: Double,
                      current: AxisPosition) -> (primary: Double, secondary: Double) {
        func axis(_ target: Double, _ feed: Double, _ actual: Double, _ limit: Double) -> Double {
            let correction = min(max(gain * (target - actual), -maximumCorrection), maximumCorrection)
            return min(max(feed + correction, -limit), limit)
        }
        return (axis(desired.primary, primaryRate, current.primary, limits.maximumAzimuthRate),
                axis(desired.secondary, secondaryRate, current.secondary, limits.maximumAltitudeRate))
    }
}

/// Keeps a continuous primary-axis angle from readings that wrap at ±180°.
public struct AxisUnwrapper: Sendable {
    public private(set) var unwrapped: Double
    private var lastRaw: Double

    /// Starts on the turn that puts the mount inside the cable range.
    public init(raw: Double, model: AlignmentModel, limits: MountLimits) {
        let lo = limits.cableStopAzimuth + model.yaw
        let mountAzimuth = model.azimuthSense * raw
        let k = ((lo - mountAzimuth) / 360).rounded(.up)
        unwrapped = model.azimuthSense * (mountAzimuth + 360 * k)
        lastRaw = raw
    }

    /// Starts on the turn nearest `reference`: a position remembered from before, past the cable stop.
    public init(raw: Double, near reference: Double) {
        unwrapped = reference + wrap180(raw - reference)
        lastRaw = raw
    }

    public mutating func update(raw: Double) -> Double {
        unwrapped += wrap180(raw - lastRaw)
        lastRaw = raw
        return unwrapped
    }
}
