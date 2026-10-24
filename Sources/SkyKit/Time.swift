import Foundation

/// An instant expressed on the time scales the ephemerides need.
public struct AstroTime: Sendable {
    /// TT − UT. About 69.2 s in 2026 (37 leap seconds + 32.184 s, UT1 ≈ UTC).
    public static let defaultDeltaT: TimeInterval = 69.2

    public let date: Date
    /// Julian Date on the UT scale (sidereal time, SGP4).
    public let jdUT: Double
    /// Julian Ephemeris Date on the TT scale (Sun, Moon, planets).
    public let jdTT: Double

    public init(_ date: Date, deltaT: TimeInterval = AstroTime.defaultDeltaT) {
        self.date = date
        jdUT = date.timeIntervalSince1970 / 86_400 + 2_440_587.5
        jdTT = jdUT + deltaT / 86_400
    }

    /// Builds a time from a TT Julian Ephemeris Date (as used by the Meeus worked examples).
    public init(jdTT: Double, deltaT: TimeInterval = AstroTime.defaultDeltaT) {
        let jdUT = jdTT - deltaT / 86_400
        self.init(Date(timeIntervalSince1970: (jdUT - 2_440_587.5) * 86_400), deltaT: deltaT)
    }

    /// Julian centuries of TT since J2000.0.
    public var centuriesTT: Double { (jdTT - 2_451_545.0) / 36_525 }

    /// Greenwich mean sidereal time in degrees (Meeus 12.4, IAU 1982).
    public var gmst: Double {
        let t = (jdUT - 2_451_545.0) / 36_525
        return normalizedDegrees(280.46061837 + 360.98564736629 * (jdUT - 2_451_545.0)
                                 + 0.000387933 * t * t - t * t * t / 38_710_000)
    }

    /// Greenwich apparent sidereal time in degrees.
    public var gast: Double {
        let n = Nutation(self)
        return normalizedDegrees(gmst + n.longitude * cos(n.trueObliquity.radians))
    }
}

/// Low-precision nutation and obliquity (Meeus ch. 22), good to about 0.5″.
public struct Nutation: Sendable {
    /// Δψ in degrees.
    public let longitude: Double
    /// Δε in degrees.
    public let obliquity: Double
    /// ε₀ in degrees.
    public let meanObliquity: Double

    public var trueObliquity: Double { meanObliquity + obliquity }

    public init(_ time: AstroTime) {
        let t = time.centuriesTT
        let omega = (125.04452 - 1934.136261 * t).radians
        let l = (280.4665 + 36_000.7698 * t).radians
        let lp = (218.3165 + 481_267.8813 * t).radians
        longitude = (-17.20 * sin(omega) - 1.32 * sin(2 * l) - 0.23 * sin(2 * lp) + 0.21 * sin(2 * omega)) / 3600
        obliquity = (9.20 * cos(omega) + 0.57 * cos(2 * l) + 0.10 * cos(2 * lp) - 0.09 * cos(2 * omega)) / 3600
        meanObliquity = (84_381.448 - 46.8150 * t - 0.00059 * t * t + 0.001813 * t * t * t) / 3600
    }
}

/// Rotates J2000 mean equatorial vectors to the mean equator and equinox of `time` (Meeus 21.2–21.4).
public func precessionFromJ2000(to time: AstroTime) -> Mat3 {
    let t = time.centuriesTT
    let zeta = (2306.2181 * t + 0.30188 * t * t + 0.017998 * t * t * t) / 3600
    let z = (2306.2181 * t + 1.09468 * t * t + 0.018203 * t * t * t) / 3600
    let theta = (2004.3109 * t - 0.42665 * t * t - 0.041833 * t * t * t) / 3600
    return Mat3.rotZ(z) * Mat3.rotY(-theta) * Mat3.rotZ(zeta)
}

/// Rotates an equatorial-of-date vector into the Earth-fixed frame, given a sidereal angle.
func earthFixed(_ v: Vec3, siderealAngle: Double) -> Vec3 {
    Mat3.rotZ(-siderealAngle) * v
}
