import Foundation

/// Where an object is now, which way it's heading, and how high this pass (or the next) gets.
public struct ObjectVisibility: Sendable {
    public enum Trend: Sendable { case rising, setting }

    public let altitude: Double
    public let azimuth: Double
    public let trend: Trend
    /// The current period above the horizon if it's up, otherwise the next one.
    public let rise: Date?
    public let set: Date?
    public let peak: Date?
    public let maxAltitude: Double?

    public var isUp: Bool { altitude > 0 }
}

extension Observer {
    /// Rise, peak and set for slowly moving objects (Sun, Moon, planets, stars), by scanning
    /// `step` seconds at a time and refining each crossing. Not for satellites, whose passes
    /// last minutes; use `PassPredictor` for those.
    public func visibility(of target: some Target, at date: Date, horizon: Double = 0,
                           lookBack: TimeInterval = 14 * 3600, lookAhead: TimeInterval = 30 * 3600,
                           step: TimeInterval = 600) throws -> ObjectVisibility {
        func altitude(_ t: Date) throws -> Double { try look(at: target, AstroTime(t)).altitude - horizon }

        let now = try look(at: target, AstroTime(date))
        let soon = try look(at: target, AstroTime(date + 30))
        let trend: ObjectVisibility.Trend = soon.altitude >= now.altitude ? .rising : .setting

        /// The crossing between a and b, to the second.
        func crossing(_ a: Date, _ b: Date) throws -> Date {
            var lo = a, hi = b
            let rising = try altitude(a) <= 0
            while hi.timeIntervalSince(lo) > 1 {
                let mid = lo + hi.timeIntervalSince(lo) / 2
                if (try altitude(mid) > 0) == rising { hi = mid } else { lo = mid }
            }
            return lo
        }

        // Find the up-period that contains now, or the next one.
        var rise: Date?
        var set: Date?
        if now.altitude - horizon > 0 {
            var t = date
            while t > date - lookBack {
                let earlier = t - step
                if try altitude(earlier) <= 0 { rise = try crossing(earlier, t); break }
                t = earlier
            }
            t = date
            while t < date + lookAhead {
                let later = t + step
                if try altitude(later) <= 0 { set = try crossing(t, later); break }
                t = later
            }
        } else {
            var t = date
            while t < date + lookAhead {
                let later = t + step
                if try altitude(later) > 0 {
                    rise = try crossing(t, later)
                    var u = later
                    while u < date + lookAhead + lookBack {
                        let after = u + step
                        if try altitude(after) <= 0 { set = try crossing(u, after); break }
                        u = after
                    }
                    break
                }
                t = later
            }
        }

        // The peak of that period (circumpolar objects: the highest point in the window).
        let from = rise ?? (now.altitude - horizon > 0 ? date - lookBack : date)
        let to = set ?? date + lookAhead
        guard to > from, rise != nil || now.altitude - horizon > 0 else {
            return ObjectVisibility(altitude: now.altitude, azimuth: now.azimuth, trend: trend,
                              rise: nil, set: nil, peak: nil, maxAltitude: nil)
        }
        var best = (date: from, altitude: -90.0)
        for t in stride(from: from, through: to, by: step / 4) {
            let a = try altitude(t)
            if a > best.altitude { best = (t, a) }
        }
        // Refine around the coarse peak.
        var lo = best.date - step / 4, hi = best.date + step / 4
        for _ in 0..<40 {
            let m1 = lo + hi.timeIntervalSince(lo) / 3, m2 = hi - hi.timeIntervalSince(lo) / 3
            if try altitude(m1) < altitude(m2) { lo = m1 } else { hi = m2 }
        }
        let peak = lo + hi.timeIntervalSince(lo) / 2
        return ObjectVisibility(altitude: now.altitude, azimuth: now.azimuth, trend: trend,
                          rise: rise, set: set, peak: peak, maxAltitude: try altitude(peak) + horizon)
    }
}

extension SatellitePass {
    /// Where the satellite is at `date` during this pass, and which way it's heading.
    public func status(at date: Date) -> (altitude: Double, azimuth: Double, trend: ObjectVisibility.Trend)? {
        guard date >= start.date, date <= end.date,
              let sample = track.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })
        else { return nil }
        return (sample.position.altitude, sample.position.azimuth, date < culmination.date ? .rising : .setting)
    }
}
