import Foundation

/// Sun, Moon and planets.
///
/// Accuracy: Sun ~0.01°, Moon ~0.01° (truncated Meeus ch. 47), planets ~1′ (JPL/Standish
/// Keplerian elements valid 1800–2050). Planets omit nutation and aberration (<40″).
/// All of this is far below what an alt-az mount can resolve in a finder.
public enum SolarSystemBody: String, CaseIterable, Target, Hashable {
    case sun, moon, mercury, venus, mars, jupiter, saturn, uranus, neptune

    public static let auKm = 149_597_870.7

    public var name: String { rawValue.capitalized }

    /// Geocentric apparent position in km, true equator and equinox of date.
    public func equatorialOfDate(_ time: AstroTime) -> Vec3 {
        switch self {
        case .sun: Self.sun(time)
        case .moon: Self.moon(time)
        default: Self.planet(Planet.elements[self]!, time)
        }
    }

    public func earthFixedPosition(at time: AstroTime) -> Vec3 {
        earthFixed(equatorialOfDate(time), siderealAngle: time.gast)
    }

    /// Right ascension and declination of date, in degrees.
    public func raDec(_ time: AstroTime) -> (ra: Double, dec: Double) {
        let s = equatorialOfDate(time).spherical
        return (s.longitude, s.latitude)
    }

    // MARK: Sun (Meeus ch. 25, low accuracy)

    static func sun(_ time: AstroTime) -> Vec3 {
        let t = time.centuriesTT
        let l0 = 280.46646 + 36_000.76983 * t + 0.0003032 * t * t
        let m = (357.52911 + 35_999.05029 * t - 0.0001537 * t * t).radians
        let e = 0.016708634 - 0.000042037 * t - 0.0000001267 * t * t
        let c = (1.914602 - 0.004817 * t - 0.000014 * t * t) * sin(m)
            + (0.019993 - 0.000101 * t) * sin(2 * m) + 0.000289 * sin(3 * m)
        let trueLongitude = l0 + c
        let nu = m + c.radians
        let r = 1.000001018 * (1 - e * e) / (1 + e * cos(nu))
        let omega = (125.04 - 1934.136 * t).radians
        let lambda = trueLongitude - 0.00569 - 0.00478 * sin(omega)
        let epsilon = Nutation(time).meanObliquity + 0.00256 * cos(omega)
        return (r * auKm) * (Mat3.rotX(epsilon) * Vec3.unit(longitude: lambda, latitude: 0))
    }

    // MARK: Moon (Meeus ch. 47, terms ≥ ~0.001°)

    /// D, M, M′, F multipliers and coefficients: longitude (1e-6°), distance (1e-3 km).
    private static let moonLR: [(Double, Double, Double, Double, Double, Double)] = [
        (0, 0, 1, 0, 6_288_774, -20_905_355), (2, 0, -1, 0, 1_274_027, -3_699_111),
        (2, 0, 0, 0, 658_314, -2_955_968), (0, 0, 2, 0, 213_618, -569_925),
        (0, 1, 0, 0, -185_116, 48_888), (0, 0, 0, 2, -114_332, -3_149),
        (2, 0, -2, 0, 58_793, 246_158), (2, -1, -1, 0, 57_066, -152_138),
        (2, 0, 1, 0, 53_322, -170_733), (2, -1, 0, 0, 45_758, -204_586),
        (0, 1, -1, 0, -40_923, -129_620), (1, 0, 0, 0, -34_720, 108_743),
        (0, 1, 1, 0, -30_383, 104_755), (2, 0, 0, -2, 15_327, 10_321),
        (0, 0, 1, 2, -12_528, 0), (0, 0, 1, -2, 10_980, 79_661),
        (4, 0, -1, 0, 10_675, -34_782), (0, 0, 3, 0, 10_034, -23_210),
        (4, 0, -2, 0, 8_548, -21_636), (2, 1, -1, 0, -7_888, 24_208),
        (2, 1, 0, 0, -6_766, 30_824), (1, 0, -1, 0, -5_163, -8_379),
        (1, 1, 0, 0, 4_987, -16_675), (2, -1, 1, 0, 4_036, -12_831),
        (2, 0, 2, 0, 3_994, -10_445), (4, 0, 0, 0, 3_861, -11_650),
        (2, 0, -3, 0, 3_665, 14_403), (0, 1, -2, 0, -2_689, -7_003),
        (2, 0, -1, 2, -2_602, 0), (2, -1, -2, 0, 2_390, 10_056),
        (1, 0, 1, 0, -2_348, 6_322), (2, -2, 0, 0, 2_236, -9_884),
    ]

    /// D, M, M′, F multipliers and latitude coefficient (1e-6°).
    private static let moonB: [(Double, Double, Double, Double, Double)] = [
        (0, 0, 0, 1, 5_128_122), (0, 0, 1, 1, 280_602), (0, 0, 1, -1, 277_693),
        (2, 0, 0, -1, 173_237), (2, 0, -1, 1, 55_413), (2, 0, -1, -1, 46_271),
        (2, 0, 0, 1, 32_573), (0, 0, 2, 1, 17_198), (2, 0, 1, -1, 9_266),
        (0, 0, 2, -1, 8_822), (2, -1, 0, -1, 8_216), (2, 0, -2, -1, 4_324),
        (2, 0, 1, 1, 4_200), (2, 1, 0, -1, -3_359), (2, -1, -1, 1, 2_463),
        (2, -1, 0, 1, 2_211), (2, -1, -1, -1, 2_065), (0, 1, -1, -1, -1_870),
        (4, 0, -1, -1, 1_828), (0, 1, 0, 1, -1_794), (0, 0, 0, 3, -1_749),
        (0, 1, -1, 1, -1_565), (1, 0, 0, 1, -1_491), (0, 1, 1, 1, -1_475),
        (0, 1, 1, -1, -1_410), (0, 1, 0, -1, -1_344), (1, 0, 0, -1, -1_335),
        (0, 0, 3, 1, 1_107), (4, 0, 0, -1, 1_021), (4, 0, -1, 1, 833),
    ]

    /// Geometric ecliptic longitude/latitude of date (degrees) and distance (km).
    static func moonEcliptic(_ time: AstroTime) -> (lambda: Double, beta: Double, distance: Double) {
        let t = time.centuriesTT
        let t2 = t * t, t3 = t2 * t, t4 = t3 * t
        let lp = 218.3164477 + 481_267.88123421 * t - 0.0015786 * t2 + t3 / 538_841 - t4 / 65_194_000
        let d = 297.8501921 + 445_267.1114034 * t - 0.0018819 * t2 + t3 / 545_868 - t4 / 113_065_000
        let m = 357.5291092 + 35_999.0502909 * t - 0.0001536 * t2 + t3 / 24_490_000
        let mp = 134.9633964 + 477_198.8675055 * t + 0.0087414 * t2 + t3 / 69_699 - t4 / 14_712_000
        let f = 93.2720950 + 483_202.0175233 * t - 0.0036539 * t2 - t3 / 3_526_000 + t4 / 863_310_000
        let e = 1 - 0.002516 * t - 0.0000074 * t2
        let a1 = 119.75 + 131.849 * t, a2 = 53.09 + 479_264.290 * t, a3 = 313.45 + 481_266.484 * t

        func eccentricity(_ mMult: Double) -> Double { abs(mMult) == 1 ? e : abs(mMult) == 2 ? e * e : 1 }

        var sumL = 0.0, sumR = 0.0, sumB = 0.0
        for (cd, cm, cmp, cf, cl, cr) in moonLR {
            let arg = (cd * d + cm * m + cmp * mp + cf * f).radians
            sumL += cl * eccentricity(cm) * sin(arg)
            sumR += cr * eccentricity(cm) * cos(arg)
        }
        for (cd, cm, cmp, cf, cb) in moonB {
            sumB += cb * eccentricity(cm) * sin((cd * d + cm * m + cmp * mp + cf * f).radians)
        }
        sumL += 3958 * sin(a1.radians) + 1962 * sin((lp - f).radians) + 318 * sin(a2.radians)
        sumB += -2235 * sin(lp.radians) + 382 * sin(a3.radians) + 175 * sin((a1 - f).radians)
            + 175 * sin((a1 + f).radians) + 127 * sin((lp - mp).radians) - 115 * sin((lp + mp).radians)

        return (normalizedDegrees(lp + sumL / 1e6), sumB / 1e6, 385_000.56 + sumR / 1000)
    }

    static func moon(_ time: AstroTime) -> Vec3 {
        let (lambda, beta, distance) = moonEcliptic(time)
        let n = Nutation(time)
        return distance * (Mat3.rotX(n.trueObliquity) * Vec3.unit(longitude: lambda + n.longitude, latitude: beta))
    }

    // MARK: Planets (Standish, "Keplerian Elements for Approximate Positions", table 1)

    struct Planet {
        /// a (AU), e, I, L, ϖ, Ω (degrees) and their rates per Julian century.
        let elements: [Double]
        let rates: [Double]

        static let elements: [SolarSystemBody: Planet] = [
            .mercury: Planet(elements: [0.38709927, 0.20563593, 7.00497902, 252.25032350, 77.45779628, 48.33076593],
                             rates: [0.00000037, 0.00001906, -0.00594749, 149_472.67411175, 0.16047689, -0.12534081]),
            .venus: Planet(elements: [0.72333566, 0.00677672, 3.39467605, 181.97909950, 131.60246718, 76.67984255],
                           rates: [0.00000390, -0.00004107, -0.00078890, 58_517.81538729, 0.00268329, -0.27769418]),
            .mars: Planet(elements: [1.52371034, 0.09339410, 1.84969142, -4.55343205, -23.94362959, 49.55953891],
                          rates: [0.00001847, 0.00007882, -0.00813131, 19_140.30268499, 0.44441088, -0.29257343]),
            .jupiter: Planet(elements: [5.20288700, 0.04838624, 1.30439695, 34.39644051, 14.72847983, 100.47390909],
                             rates: [-0.00011607, -0.00013253, -0.00183714, 3_034.74612775, 0.21252668, 0.20469106]),
            .saturn: Planet(elements: [9.53667594, 0.05386179, 2.48599187, 49.95424423, 92.59887831, 113.66242448],
                            rates: [-0.00125060, -0.00050991, 0.00193609, 1_222.49362201, -0.41897216, -0.28867794]),
            .uranus: Planet(elements: [19.18916464, 0.04725744, 0.77263783, 313.23810451, 170.95427630, 74.01692503],
                            rates: [-0.00196176, -0.00004397, -0.00242939, 428.48202785, 0.40805281, 0.04240589]),
            .neptune: Planet(elements: [30.06992276, 0.00859048, 1.77004347, -55.12002969, 44.96476227, 131.78422574],
                             rates: [0.00026291, 0.00005105, 0.00035372, 218.45945325, -0.32241464, -0.01262724]),
        ]

        /// Earth–Moon barycentre.
        static let earth = Planet(elements: [1.00000261, 0.01671123, -0.00001531, 100.46457166, 102.93768193, 0],
                                  rates: [0.00000562, -0.00004392, -0.01294668, 35_999.37244981, 0.32327364, 0])

        /// Heliocentric position in AU, J2000 ecliptic.
        func heliocentric(jdTT: Double) -> Vec3 {
            let t = (jdTT - 2_451_545.0) / 36_525
            let v = zip(elements, rates).map { $0 + $1 * t }
            let (a, e, i, l, peri, node) = (v[0], v[1], v[2].radians, v[3], v[4], v[5])
            let omega = (peri - node).radians
            let m = wrap180(l - peri).radians

            var ea = m + e * sin(m)
            for _ in 0..<10 {
                let delta = (ea - e * sin(ea) - m) / (1 - e * cos(ea))
                ea -= delta
                if abs(delta) < 1e-12 { break }
            }
            let xp = a * (cos(ea) - e)
            let yp = a * (1 - e * e).squareRoot() * sin(ea)

            let co = cos(omega), so = sin(omega), cn = cos(node.radians), sn = sin(node.radians)
            let ci = cos(i), si = sin(i)
            return Vec3((co * cn - so * sn * ci) * xp + (-so * cn - co * sn * ci) * yp,
                        (co * sn + so * cn * ci) * xp + (-so * sn + co * cn * ci) * yp,
                        so * si * xp + co * si * yp)
        }
    }

    static let j2000Obliquity = 23.43928

    static func planet(_ planet: Planet, _ time: AstroTime) -> Vec3 {
        let earth = Planet.earth.heliocentric(jdTT: time.jdTT)
        var geocentric = planet.heliocentric(jdTT: time.jdTT) - earth
        // Light time: see the planet where it was when the light left it.
        for _ in 0..<2 {
            let lightDays = geocentric.length * auKm / 299_792.458 / 86_400
            geocentric = planet.heliocentric(jdTT: time.jdTT - lightDays) - earth
        }
        let equatorialJ2000 = Mat3.rotX(j2000Obliquity) * geocentric
        return auKm * (precessionFromJ2000(to: time) * equatorialJ2000)
    }
}
