import Foundation

/// A satellite that could be the one seen at a point in the sky.
public struct SightingCandidate: Sendable, Identifiable {
    public let satellite: SatelliteTarget
    public let position: Horizontal
    /// Degrees from where you pointed.
    public let offset: Double
    /// Degrees between its path and the way you swiped, nil for a tap.
    public let directionError: Double?
    public let sunlit: Bool
    /// Lower is a better match.
    public let score: Double

    public var id: String { satellite.noradID }
}

/// Which satellite is that? Given where in the sky you pointed (and which way it was moving, if
/// you swiped along its path), the satellites up there now, best match first.
public enum SatelliteIdentifier {
    /// `towards` is where the swipe ended, for the direction of motion. `radius` allows for the
    /// phone's compass, which is often several degrees out. Satellites in the Earth's shadow are
    /// kept, as they could be seen just after it enters, but ranked lower. Anything slower than
    /// `minimumRate` (°/s) across the sky isn't a moving dot: GPS, geostationary, or XMM-Newton
    /// out near apogee at 0.004°/s.
    public static func candidates(among satellites: [SatelliteTarget], observer: Observer, at date: Date,
                                  pointedAt aim: Horizontal, towards: Horizontal? = nil,
                                  radius: Double = 15, minimumRate: Double = 0.03, limit: Int = 5,
                                  deltaT: TimeInterval = AstroTime.defaultDeltaT) -> [SightingCandidate] {
        let time = AstroTime(date, deltaT: deltaT)
        let aimVector = aim.unitVector
        let swipe = towards.map { tangent(from: aimVector, to: $0.unitVector) }
        var found: [SightingCandidate] = []
        for satellite in satellites {
            guard let h = try? observer.look(at: satellite, time), h.altitude > 0 else { continue }
            let offset = angularSeparation(aimVector, h.unitVector)
            guard offset <= radius else { continue }
            guard let later = try? observer.look(at: satellite, AstroTime(date + 2, deltaT: deltaT)),
                  angularSeparation(h.unitVector, later.unitVector) / 2 >= minimumRate else { continue }
            var directionError: Double?
            if let swipe {
                let motion = tangent(from: h.unitVector, to: later.unitVector)
                directionError = angularSeparation(motion, swipe)
            }
            let sunlit = (try? satellite.isSunlit(at: time)) ?? false
            // A degree off in position weighs as much as 6° off in direction; shadow costs 8°.
            let score = offset + (directionError ?? 0) / 6 + (sunlit ? 0 : 8)
            found.append(SightingCandidate(satellite: satellite, position: h, offset: offset,
                                           directionError: directionError, sunlit: sunlit, score: score))
        }
        return Array(found.sorted { $0.score < $1.score }.prefix(limit))
    }

    /// The direction from `a` towards `b`, in the plane of the sky at `a`.
    static func tangent(from a: Vec3, to b: Vec3) -> Vec3 {
        let d = b - a
        return d - d.dot(a) * a
    }
}
