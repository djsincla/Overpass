import Foundation

/// Minimum altitude by azimuth, for trees and buildings. Linearly interpolated, wrapping at 360°.
public struct HorizonMask: Sendable {
    public var points: [(azimuth: Double, altitude: Double)]

    public init(_ points: [(azimuth: Double, altitude: Double)]) {
        self.points = points.sorted { $0.azimuth < $1.azimuth }
    }

    public func minimumAltitude(at azimuth: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        let az = normalizedDegrees(azimuth)
        var lo = (azimuth: last.azimuth - 360, altitude: last.altitude)
        for p in points + [(first.azimuth + 360, first.altitude)] {
            if az <= p.azimuth {
                let span = p.azimuth - lo.azimuth
                return span == 0 ? p.altitude : lo.altitude + (p.altitude - lo.altitude) * (az - lo.azimuth) / span
            }
            lo = p
        }
        return first.altitude
    }
}

public struct PassSample: Sendable {
    public let date: Date
    public let position: Horizontal
    public let sunlit: Bool
    /// Degrees per second, signed.
    public let azimuthRate: Double
    public let altitudeRate: Double
}

public struct SatellitePass: Sendable, Identifiable {
    public var id: String { "\(noradID)-\(Int(start.date.timeIntervalSince1970))" }

    public let name: String
    public let noradID: String
    /// Above the horizon/mask.
    public let start: PassSample
    public let culmination: PassSample
    public let end: PassSample
    /// The whole track at `sampleInterval` spacing; for the sky plot and the tracker.
    public let track: [PassSample]
    /// True if the search window cut off the pass (e.g. it was already up).
    public let truncated: Bool

    /// Samples where the satellite is sunlit and the observer's sky is dark.
    public let visibleSamples: Range<Int>?
    public let peakAzimuthRate: Double
    public let peakAltitudeRate: Double
    public let minimumSunSeparation: Double
    public let minimumRange: Double

    public var duration: TimeInterval { end.date.timeIntervalSince(start.date) }
    public var maxAltitude: Double { culmination.position.altitude }
    public var isVisible: Bool { visibleSamples != nil }
    /// In the Earth's shadow for the whole pass.
    public var isEclipsed: Bool { !track.contains { $0.sunlit } }
    /// The fastest either axis must move, for comparing with the mount's limits.
    public var peakAxisRate: Double { max(peakAzimuthRate, peakAltitudeRate) }
}

public struct PassPredictor: Sendable {
    public var observer: Observer
    /// Lowest altitude that counts as "up" where no mask applies.
    public var minimumAltitude: Double = 0
    public var horizonMask: HorizonMask?
    /// Sun altitude below which the sky counts as dark (−6 civil, −12 nautical).
    public var darkSkySunAltitude: Double = -6
    public var sampleInterval: TimeInterval = 1
    public var deltaT: TimeInterval = AstroTime.defaultDeltaT
    /// How far back to look for the rise of a pass that's already up when the search starts.
    /// Geostationary objects never set, so this bounds the search.
    public var maximumLookBack: TimeInterval = 12 * 3600

    public init(observer: Observer) {
        self.observer = observer
    }

    func threshold(_ azimuth: Double) -> Double {
        max(minimumAltitude, horizonMask?.minimumAltitude(at: azimuth) ?? -90)
    }

    func margin(_ target: SatelliteTarget, _ date: Date) throws -> Double {
        let h = try observer.look(at: target, AstroTime(date, deltaT: deltaT))
        return h.altitude - threshold(h.azimuth)
    }

    /// All passes in [from, to], oldest first.
    public func passes(of target: SatelliteTarget, from: Date, to: Date) throws -> [SatellitePass] {
        // Coarse scan short enough not to miss brief low passes of LEO objects.
        let step: TimeInterval = target.period < 225 ? 20 : 300
        var passes: [SatellitePass] = []
        var t = from
        var previous = try margin(target, t)
        var rise: Date? = previous > 0 ? from : nil
        var truncated = previous > 0
        // Already up: look back for the real rise, so long passes (high orbits last hours)
        // aren't cut off where the search window happens to start.
        if previous > 0 {
            var back = from
            while back > from - maximumLookBack {
                let earlier = back - step
                if try margin(target, earlier) <= 0 {
                    rise = try crossing(target, earlier, back)
                    truncated = false
                    break
                }
                back = earlier
            }
            if truncated { rise = back }
        }

        while t < to {
            let next = min(t + step, to)
            let current = try margin(target, next)
            if previous <= 0, current > 0 {
                rise = try crossing(target, t, next)
                truncated = false
            } else if previous > 0, current <= 0, let r = rise {
                passes.append(try buildPass(target, r, try crossing(target, t, next), truncated: truncated))
                rise = nil
            }
            previous = current
            t = next
        }
        if let r = rise, r < to {
            passes.append(try buildPass(target, r, to, truncated: true))
        }
        return passes
    }

    /// Bisects for the horizon crossing between `a` and `b` to 0.1 s.
    func crossing(_ target: SatelliteTarget, _ a: Date, _ b: Date) throws -> Date {
        var lo = a, hi = b
        let rising = try margin(target, a) <= 0
        while hi.timeIntervalSince(lo) > 0.1 {
            let mid = lo + hi.timeIntervalSince(lo) / 2
            if (try margin(target, mid) > 0) == rising { hi = mid } else { lo = mid }
        }
        return lo + hi.timeIntervalSince(lo) / 2
    }

    func buildPass(_ target: SatelliteTarget, _ start: Date, _ end: Date, truncated: Bool) throws -> SatellitePass {
        // Keep long (deep space) passes to a manageable number of samples.
        let interval = max(sampleInterval, end.timeIntervalSince(start) / 5000)
        var times = Array(stride(from: start, to: end, by: interval))
        times.append(end)

        var raw: [(Date, Horizontal, Bool, Double, Bool)] = []
        for date in times {
            let time = AstroTime(date, deltaT: deltaT)
            let position = try observer.look(at: target, time)
            let sun = observer.horizontal(ofEarthFixed: SolarSystemBody.sun.earthFixedPosition(at: time))
            let sunlit = try target.isSunlit(at: time)
            raw.append((date, position, sunlit, angularSeparation(position.unitVector, sun.unitVector),
                        sunlit && sun.altitude < darkSkySunAltitude))
        }

        var samples: [PassSample] = []
        for i in raw.indices {
            let a = raw[max(i - 1, 0)], b = raw[min(i + 1, raw.count - 1)]
            let dt = b.0.timeIntervalSince(a.0)
            samples.append(PassSample(date: raw[i].0, position: raw[i].1, sunlit: raw[i].2,
                                      azimuthRate: dt > 0 ? wrap180(b.1.azimuth - a.1.azimuth) / dt : 0,
                                      altitudeRate: dt > 0 ? (b.1.altitude - a.1.altitude) / dt : 0))
        }

        let visible = raw.indices.filter { raw[$0].4 }
        let peak = samples.max { $0.position.altitude < $1.position.altitude }!
        return SatellitePass(
            name: target.name, noradID: target.noradID,
            start: samples.first!, culmination: peak, end: samples.last!, track: samples, truncated: truncated,
            visibleSamples: visible.isEmpty ? nil : visible.first!..<(visible.last! + 1),
            peakAzimuthRate: samples.map { abs($0.azimuthRate) }.max()!,
            peakAltitudeRate: samples.map { abs($0.altitudeRate) }.max()!,
            minimumSunSeparation: raw.map(\.3).min()!,
            minimumRange: samples.map(\.position.range).min()!)
    }
}

public struct PassFilter: Sendable {
    public enum Visibility: Sendable { case any, visibleOnly }

    public var minimumMaxAltitude: Double = 10
    public var minimumDuration: TimeInterval = 0
    public var visibility: Visibility = .any
    /// Drop passes spent entirely in the Earth's shadow (never sunlit), whatever the sky.
    public var excludeEclipsed = false
    /// Reject passes needing faster axis motion than the mount can do (deg/s).
    public var maximumAxisRate: Double?
    /// Keep the scope at least this far from the Sun (degrees).
    public var minimumSunSeparation: Double?
    /// Only passes culminating in this azimuth sector (degrees, clockwise; may wrap through north).
    public var culminationAzimuth: (from: Double, to: Double)?
    public var startAfter: Date?
    public var startBefore: Date?
    public var nameContains: String?
    /// Only passes this mount can follow (cable stop, axis limits, speeds).
    public var mountPlanner: MountPlanner?
    /// With `mountPlanner`, how long the mount may lose the target (e.g. cutting round the zenith).
    public var maximumSecondsOffTarget: TimeInterval = 0

    public init() {}

    public func matches(_ pass: SatellitePass) -> Bool {
        if pass.maxAltitude < minimumMaxAltitude { return false }
        if pass.duration < minimumDuration { return false }
        if visibility == .visibleOnly, !pass.isVisible { return false }
        if excludeEclipsed, pass.isEclipsed { return false }
        if let limit = maximumAxisRate, pass.peakAxisRate > limit { return false }
        if let limit = minimumSunSeparation, pass.minimumSunSeparation < limit { return false }
        if let sector = culminationAzimuth {
            let span = normalizedDegrees(sector.to - sector.from)
            if normalizedDegrees(pass.culmination.position.azimuth - sector.from) > span { return false }
        }
        if let date = startAfter, pass.start.date < date { return false }
        if let date = startBefore, pass.start.date > date { return false }
        if let text = nameContains, !text.isEmpty,
           !pass.name.localizedCaseInsensitiveContains(text), pass.noradID != text { return false }
        // Last, because planning is the most expensive check.
        if let planner = mountPlanner {
            guard let plan = planner.plan(pass.track), plan.secondsOffTarget <= maximumSecondsOffTarget else { return false }
        }
        return true
    }
}

public enum PassSort: Sendable {
    case startTime, maxAltitude, duration

    public func sort(_ passes: [SatellitePass]) -> [SatellitePass] {
        switch self {
        case .startTime: passes.sorted { $0.start.date < $1.start.date }
        case .maxAltitude: passes.sorted { $0.maxAltitude > $1.maxAltitude }
        case .duration: passes.sorted { $0.duration > $1.duration }
        }
    }
}

extension PassPredictor {
    /// Predicts, filters and sorts passes for many satellites, running them in parallel.
    public func passes(of targets: [SatelliteTarget], from: Date, to: Date,
                       filter: PassFilter = PassFilter(), sort: PassSort = .startTime) async -> [SatellitePass] {
        let predictor = self
        let all = await withTaskGroup(of: [SatellitePass].self) { group in
            for target in targets {
                // Satellites that fail to propagate (decayed, bad elements) are skipped.
                group.addTask { (try? predictor.passes(of: target, from: from, to: to)) ?? [] }
            }
            return await group.reduce(into: []) { $0 += $1 }
        }
        return sort.sort(all.filter(filter.matches))
    }
}
