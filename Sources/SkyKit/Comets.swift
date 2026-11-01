import Foundation

/// A comet from the Minor Planet Center's orbital elements: a two-body orbit about the Sun
/// (J2000 ecliptic), good to about an arcminute for months either side of the elements' epoch.
public struct Comet: Target, Hashable, Identifiable {
    /// "12P/Pons-Brooks", "C/2023 A3 (Tsuchinshan-ATLAS)".
    public let name: String
    /// Julian date (TT) of perihelion.
    public let perihelionJD: Double
    /// Perihelion distance, AU.
    public let q: Double
    public let e: Double
    /// Argument of perihelion, longitude of the ascending node, inclination: degrees, J2000 ecliptic.
    public let argumentOfPerihelion: Double
    public let node: Double
    public let inclination: Double
    /// Magnitude parameters: m = H + 5 log Δ + 2.5 K log r.
    public let absoluteMagnitude: Double?
    public let slope: Double?

    public var id: String { name }

    /// "12P", "C/2023 A3": the name up to its parenthesised or slash-separated proper name.
    public var designation: String {
        if let paren = name.firstIndex(of: "(") { return name[..<paren].trimmingCharacters(in: .whitespaces) }
        if let slash = name.firstIndex(of: "/"), name[..<slash].last?.isLetter == true, name.first?.isNumber == true {
            return String(name[..<slash])
        }
        return name
    }

    public init(name: String, perihelionJD: Double, q: Double, e: Double, argumentOfPerihelion: Double,
                node: Double, inclination: Double, absoluteMagnitude: Double? = nil, slope: Double? = nil) {
        self.name = name
        self.perihelionJD = perihelionJD
        self.q = q
        self.e = e
        self.argumentOfPerihelion = argumentOfPerihelion
        self.node = node
        self.inclination = inclination
        self.absoluteMagnitude = absoluteMagnitude
        self.slope = slope
    }

    /// Gaussian gravitational constant, radians per day.
    static let k = 0.01720209895

    /// Heliocentric position in AU, J2000 ecliptic.
    public func heliocentric(jdTT: Double) -> Vec3 {
        let (x, y) = Self.orbitalPlane(q: q, e: e, days: jdTT - perihelionJD)
        let w = argumentOfPerihelion.radians, n = node.radians, i = inclination.radians
        let cw = cos(w), sw = sin(w), cn = cos(n), sn = sin(n), ci = cos(i), si = sin(i)
        return Vec3((cw * cn - sw * sn * ci) * x + (-sw * cn - cw * sn * ci) * y,
                    (cw * sn + sw * cn * ci) * x + (-sw * sn + cw * cn * ci) * y,
                    sw * si * x + cw * si * y)
    }

    /// Position in the orbit's plane, x towards perihelion, AU, `days` after perihelion.
    static func orbitalPlane(q: Double, e: Double, days t: Double) -> (Double, Double) {
        if abs(e - 1) < 1e-6 {
            // Parabola: Barker's equation, s³ + 3s = W, with s = tan(ν/2).
            let w = 3 * k * t / (2 * q * q * q).squareRoot()
            let y = cbrt(w / 2 + (w * w / 4 + 1).squareRoot())
            let s = y - 1 / y
            return (q * (1 - s * s), 2 * q * s)
        }
        if e < 1 {
            let a = q / (1 - e)
            let m = remainder(k * t / (a * a * a).squareRoot(), 2 * .pi)
            var ea = e > 0.8 ? (m >= 0 ? Double.pi : -.pi) / 2 + m / 2 : m
            for _ in 0..<100 {
                let delta = (ea - e * sin(ea) - m) / (1 - e * cos(ea))
                ea -= max(-1, min(1, delta))
                if abs(delta) < 1e-13 { break }
            }
            return (a * (cos(ea) - e), a * (1 - e * e).squareRoot() * sin(ea))
        }
        let a = q / (e - 1)
        let m = k * t / (a * a * a).squareRoot()
        var h = asinh(m / e)
        for _ in 0..<100 {
            let delta = (e * sinh(h) - h - m) / (e * cosh(h) - 1)
            h -= max(-1, min(1, delta))
            if abs(delta) < 1e-13 { break }
        }
        return (a * (e - cosh(h)), a * (e * e - 1).squareRoot() * sinh(h))
    }

    /// Geocentric position (AU, J2000 equatorial) as seen: where the comet was when its light left.
    public func geocentricJ2000(jdTT: Double) -> Vec3 {
        let earth = SolarSystemBody.Planet.earth.heliocentric(jdTT: jdTT)
        var g = heliocentric(jdTT: jdTT) - earth
        for _ in 0..<2 {
            g = heliocentric(jdTT: jdTT - g.length * SolarSystemBody.auKm / 299_792.458 / 86_400) - earth
        }
        return Mat3.rotX(SolarSystemBody.j2000Obliquity) * g
    }

    public func equatorialOfDate(_ time: AstroTime) -> Vec3 {
        SolarSystemBody.auKm * (precessionFromJ2000(to: time) * geocentricJ2000(jdTT: time.jdTT))
    }

    public func earthFixedPosition(at time: AstroTime) -> Vec3 {
        earthFixed(equatorialOfDate(time), siderealAngle: time.gast)
    }

    /// Distances from the Sun (r) and the Earth (Δ), AU.
    public func distances(_ time: AstroTime) -> (r: Double, delta: Double) {
        (heliocentric(jdTT: time.jdTT).length, geocentricJ2000(jdTT: time.jdTT).length)
    }

    /// Predicted total magnitude from the MPC parameters; comets often stray a magnitude or two from it.
    public func apparentMagnitude(_ time: AstroTime) -> Double? {
        guard let h = absoluteMagnitude, let slope else { return nil }
        let (r, delta) = distances(time)
        return h + 5 * log10(delta) + 2.5 * slope * log10(r)
    }

    /// How fast it moves against the stars, arcseconds per hour.
    public func motion(_ time: AstroTime) -> Double {
        let a = geocentricJ2000(jdTT: time.jdTT), b = geocentricJ2000(jdTT: time.jdTT + 1.0 / 24)
        return angularSeparation(a, b) * 3600
    }

    /// Seconds before it drifts `arcseconds` from where the mount's sidereal tracking holds it,
    /// kept between a minute and a quarter of an hour.
    public func recentreInterval(_ time: AstroTime, arcseconds: Double = 30) -> TimeInterval {
        let perSecond = motion(time) / 3600
        guard perSecond > 0 else { return 900 }
        return min(900, max(60, arcseconds / perSecond))
    }
}

/// The MPC's `CometEls.txt`: one comet per line in fixed columns.
public enum MPCComets {
    public static let url = URL(string: "https://minorplanetcenter.net/iau/MPCORB/CometEls.txt")!

    public static func parse(_ text: String) -> [Comet] {
        text.split(whereSeparator: \.isNewline).compactMap { parseLine(String($0)) }
    }

    static func parseLine(_ line: String) -> Comet? {
        let c = Array(line)
        guard c.count >= 103 else { return nil }
        func field(_ from: Int, _ to: Int) -> String {
            String(c[from..<min(to, c.count)]).trimmingCharacters(in: .whitespaces)
        }
        guard let year = Int(field(14, 18)), let month = Int(field(19, 21)), let day = Double(field(22, 29)),
              let q = Double(field(30, 39)), let e = Double(field(41, 49)),
              let w = Double(field(51, 59)), let node = Double(field(61, 69)), let i = Double(field(71, 79)),
              q > 0, e >= 0 else { return nil }
        let name = field(102, 158)
        guard !name.isEmpty else { return nil }
        return Comet(name: name, perihelionJD: julianDay(year: year, month: month, day: day), q: q, e: e,
                     argumentOfPerihelion: w, node: node, inclination: i,
                     absoluteMagnitude: Double(field(91, 95)), slope: Double(field(96, 100)))
    }

    /// Gregorian calendar date (day with fraction) to Julian date.
    static func julianDay(year: Int, month: Int, day: Double) -> Double {
        var y = year, m = month
        if m <= 2 { y -= 1; m += 12 }
        let a = y / 100
        let b = 2 - a + a / 4
        return Double(Int(365.25 * Double(y + 4716))) + Double(Int(30.6001 * Double(m + 1))) + day + Double(b) - 1524.5
    }
}
