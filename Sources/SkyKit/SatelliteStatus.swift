import Foundation

/// Where a satellite is and how it moves, as seen from one place at one moment.
public struct SatelliteState: Sendable {
    public let date: Date
    public let position: Horizontal
    /// km/s, positive when moving away.
    public let rangeRate: Double
    /// km/s, in the inertial (TEME) frame.
    public let orbitalSpeed: Double
    /// km/s, of the point below it over the ground.
    public let groundSpeed: Double
    /// The point below it, with its height above the ellipsoid (km).
    public let subpoint: Geodetic
    /// Degrees per second across the sky.
    public let angularSpeed: Double

    /// By central difference over a second, like `Observer.track`.
    public init(_ target: SatelliteTarget, observer: Observer, at date: Date, deltaT: TimeInterval = AstroTime.defaultDeltaT) throws {
        let h = 0.5
        let t0 = AstroTime(date - h, deltaT: deltaT), t = AstroTime(date, deltaT: deltaT), t1 = AstroTime(date + h, deltaT: deltaT)
        let before = try target.earthFixedPosition(at: t0), now = try target.earthFixedPosition(at: t), after = try target.earthFixedPosition(at: t1)
        let lookBefore = observer.horizontal(ofEarthFixed: before), lookAfter = observer.horizontal(ofEarthFixed: after)
        self.date = date
        position = observer.horizontal(ofEarthFixed: now)
        rangeRate = (lookAfter.range - lookBefore.range) / (2 * h)
        orbitalSpeed = (try target.temePosition(at: t1) - target.temePosition(at: t0)).length / (2 * h)
        subpoint = Geodesy.geodetic(ofEarthFixed: now)
        groundSpeed = Geodesy.distance(Geodesy.geodetic(ofEarthFixed: before), Geodesy.geodetic(ofEarthFixed: after)) / (2 * h)
        angularSpeed = angularSeparation(lookBefore.unitVector, lookAfter.unitVector) / (2 * h)
    }
}

/// Maidenhead grid locators, as amateur radio uses for stations and satellite footprints.
public enum Maidenhead {
    /// Six characters, e.g. "FN31pr".
    public static func locator(_ place: Geodetic) -> String {
        let lon = min(max(place.longitude + 180, 0), 359.999_999)
        let lat = min(max(place.latitude + 90, 0), 179.999_999)
        func letter(_ i: Int, _ base: Character) -> Character {
            Character(UnicodeScalar(base.unicodeScalars.first!.value + UInt32(i))!)
        }
        let fieldLon = Int(lon / 20), fieldLat = Int(lat / 10)
        let squareLon = Int(lon.truncatingRemainder(dividingBy: 20) / 2), squareLat = Int(lat.truncatingRemainder(dividingBy: 10))
        let subLon = Int(lon.truncatingRemainder(dividingBy: 2) * 12), subLat = Int(lat.truncatingRemainder(dividingBy: 1) * 24)
        return String([letter(fieldLon, "A"), letter(fieldLat, "A")]) + "\(squareLon)\(squareLat)"
            + String([letter(subLon, "a"), letter(subLat, "a")])
    }
}

/// Doppler shift for a satellite moving at `rangeRate` km/s (positive receding).
public enum Doppler {
    public static let speedOfLight = 299_792.458

    /// What arrives on the ground for a downlink sent at `frequency`.
    public static func downlink(_ frequency: Double, rangeRate: Double) -> Double {
        frequency * (1 - rangeRate / speedOfLight)
    }

    /// What to transmit so the satellite hears `frequency`.
    public static func uplink(_ frequency: Double, rangeRate: Double) -> Double {
        frequency / (1 - rangeRate / speedOfLight)
    }
}

/// When a satellite goes into or comes out of the Earth's shadow.
public struct ShadowCrossing: Sendable, Equatable {
    public let date: Date
    /// True when it goes into shadow.
    public let entersShadow: Bool
}

extension SatellitePass {
    /// The shadow crossings during the pass, refined from the track's one-second samples by bisection.
    public func shadowCrossings(of target: SatelliteTarget, deltaT: TimeInterval = AstroTime.defaultDeltaT) -> [ShadowCrossing] {
        zip(track, track.dropFirst()).compactMap { a, b in
            guard a.sunlit != b.sunlit else { return nil }
            var lo = a.date, hi = b.date
            while hi.timeIntervalSince(lo) > 0.02 {
                let mid = lo + hi.timeIntervalSince(lo) / 2
                if ((try? target.isSunlit(at: AstroTime(mid, deltaT: deltaT))) ?? a.sunlit) == a.sunlit { lo = mid } else { hi = mid }
            }
            return ShadowCrossing(date: lo + hi.timeIntervalSince(lo) / 2, entersShadow: a.sunlit)
        }
    }
}

/// How a camera on the telescope sees a moving satellite.
public struct CameraOptics: Sendable, Equatable {
    /// mm.
    public var focalLength: Double
    /// µm.
    public var pixelSize: Double

    public init(focalLength: Double, pixelSize: Double) {
        self.focalLength = focalLength
        self.pixelSize = pixelSize
    }

    /// Arcseconds per pixel.
    public var imageScale: Double { 206.265 * pixelSize / focalLength }

    /// The longest exposure, in seconds, before something moving at `rate` °/s smears by one pixel.
    public func exposureForOnePixel(rate: Double) -> Double? {
        rate > 0 ? imageScale / (rate * 3600) : nil
    }

    /// Frames per second for under a pixel of movement between frames.
    public func framesPerSecond(rate: Double) -> Double { rate * 3600 / imageScale }

    /// Pixels across an object `size` metres long at `range` km.
    public func pixels(size: Double, range: Double) -> Double {
        (size / (range * 1000)).degrees * 3600 / imageScale
    }
}
