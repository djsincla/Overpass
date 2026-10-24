import Foundation

/// Apparent visual magnitudes: smaller is brighter (Venus about −4, the faintest naked-eye stars about +6).
extension SolarSystemBody {
    /// Sun–planet distance r and Earth–planet distance Δ (AU), and the phase angle (degrees):
    /// the angle at the planet between the Sun and the Earth.
    func planetGeometry(_ time: AstroTime) -> (r: Double, delta: Double, phase: Double)? {
        guard let planet = Planet.elements[self] else { return nil }
        let earth = Planet.earth.heliocentric(jdTT: time.jdTT)
        var p = planet.heliocentric(jdTT: time.jdTT)
        var g = p - earth
        for _ in 0..<2 {
            p = planet.heliocentric(jdTT: time.jdTT - g.length * Self.auKm / 299_792.458 / 86_400)
            g = p - earth
        }
        let phase = acos(max(-1, min(1, p.dot(g) / (p.length * g.length)))).degrees
        return (p.length, g.length, phase)
    }

    /// Meeus, Astronomical Algorithms, ch. 41 (the 1984 Astronomical Almanac expressions).
    /// Saturn's rings are ignored, so Saturn can read up to about a magnitude too faint
    /// when the rings are wide open.
    public func apparentMagnitude(_ time: AstroTime) -> Double {
        switch self {
        case .sun:
            return -26.74
        case .moon:
            // Phase angle from the Sun–Moon elongation (geocentric; parallax is negligible here).
            let elongation = angularSeparation(Self.moon(time), Self.sun(time))
            let i = 180 - elongation
            return -12.73 + 0.026 * abs(i) + 4e-9 * pow(i, 4)
        default:
            guard let (r, delta, i) = planetGeometry(time) else { return .nan }
            let distance = 5 * log10(r * delta)
            switch self {
            case .mercury: return -0.42 + distance + 0.0380 * i - 0.000273 * i * i + 0.000002 * i * i * i
            case .venus: return -4.40 + distance + 0.0009 * i + 0.000239 * i * i - 0.00000065 * i * i * i
            case .mars: return -1.52 + distance + 0.016 * i
            case .jupiter: return -9.40 + distance + 0.005 * i
            case .saturn: return -8.88 + distance + 0.044 * i
            case .uranus: return -7.19 + distance
            case .neptune: return -6.87 + distance
            default: return .nan
            }
        }
    }
}

extension SatelliteTarget {
    /// Brightness from a standard magnitude (at 1,000 km and 90° phase, the convention used by
    /// satellite observers), the range, and a diffusely reflecting sphere's phase law.
    /// TLEs don't carry a standard magnitude, so it has to come from elsewhere.
    public func apparentMagnitude(standard: Double, observer: Observer, at time: AstroTime) throws -> Double? {
        guard try isSunlit(at: time) else { return nil }
        let sat = try earthFixedPosition(at: time)
        let toObserver = observer.position - sat
        let toSun = SolarSystemBody.sun.earthFixedPosition(at: time) - sat
        let phase = angularSeparation(toObserver, toSun).radians
        let reflected = ((.pi - phase) * cos(phase) + sin(phase)) / .pi
        let atStandard = 1 / Double.pi  // the same phase law at 90°
        guard reflected > 0 else { return nil }
        return standard + 5 * log10(toObserver.length / 1000) - 2.5 * log10(reflected / atStandard)
    }
}

extension SkyObject {
    /// Apparent magnitude now, where it can be known. Satellites need a standard magnitude.
    public func apparentMagnitude(observer: Observer, at time: AstroTime, standardMagnitude: Double? = nil) -> Double? {
        switch self {
        case .star(let s): return s.magnitude
        case .body(let b): return b.apparentMagnitude(time)
        case .satellite(let s):
            guard let standard = standardMagnitude else { return nil }
            return try? s.apparentMagnitude(standard: standard, observer: observer, at: time)
        }
    }
}
