import Foundation

/// A direction in the observer's local sky.
public struct Horizontal: Equatable, Sendable {
    /// Degrees east of north, [0, 360).
    public var azimuth: Double
    /// Degrees above the horizon.
    public var altitude: Double
    /// Distance in km.
    public var range: Double

    public init(azimuth: Double, altitude: Double, range: Double = .infinity) {
        self.azimuth = azimuth
        self.altitude = altitude
        self.range = range
    }

    /// Unit vector in the local (north, east, up) frame.
    public var unitVector: Vec3 { Vec3.unit(longitude: azimuth, latitude: altitude) }
}

public struct Observer: Sendable {
    public static let wgs84A = 6378.137
    public static let wgs84F = 1 / 298.257223563

    /// Geodetic latitude in degrees, north positive.
    public let latitude: Double
    /// Longitude in degrees, east positive.
    public let longitude: Double
    /// Height above the ellipsoid in metres.
    public let height: Double
    /// Earth-fixed position in km.
    public let position: Vec3
    /// Applies atmospheric refraction to returned altitudes.
    public var refraction: Bool

    public init(latitude: Double, longitude: Double, height: Double = 0, refraction: Bool = true) {
        self.latitude = latitude
        self.longitude = longitude
        self.height = height
        self.refraction = refraction

        let e2 = Self.wgs84F * (2 - Self.wgs84F)
        let lat = latitude.radians, lon = longitude.radians
        let n = Self.wgs84A / (1 - e2 * sin(lat) * sin(lat)).squareRoot()
        let h = height / 1000
        position = Vec3((n + h) * cos(lat) * cos(lon),
                        (n + h) * cos(lat) * sin(lon),
                        (n * (1 - e2) + h) * sin(lat))
    }

    /// Converts an Earth-fixed target position (km) to azimuth/altitude.
    public func horizontal(ofEarthFixed target: Vec3) -> Horizontal {
        let d = target - position
        let lat = latitude.radians, lon = longitude.radians
        let east = -sin(lon) * d.x + cos(lon) * d.y
        let north = -sin(lat) * cos(lon) * d.x - sin(lat) * sin(lon) * d.y + cos(lat) * d.z
        let up = cos(lat) * cos(lon) * d.x + cos(lat) * sin(lon) * d.y + sin(lat) * d.z
        let range = d.length
        var altitude = asin(up / range).degrees
        if refraction { altitude += Self.refraction(geometricAltitude: altitude) }
        return Horizontal(azimuth: normalizedDegrees(atan2(east, north).degrees), altitude: altitude, range: range)
    }

    /// Refraction in degrees for standard conditions (Sæmundsson, inverse of Bennett).
    /// Zero below −1° where the formula is meaningless.
    public static func refraction(geometricAltitude h: Double) -> Double {
        guard h > -1 else { return 0 }
        return 1.02 / tan((h + 10.3 / (h + 5.11)).radians) / 60
    }

    public func look(at target: some Target, _ time: AstroTime) throws -> Horizontal {
        horizontal(ofEarthFixed: try target.earthFixedPosition(at: time))
    }

    /// Position plus the angular rates a mount must follow, by central difference.
    public func track(_ target: some Target, at date: Date, deltaT: TimeInterval = AstroTime.defaultDeltaT) throws -> TrackPoint {
        let h = 0.5
        let before = try look(at: target, AstroTime(date - h, deltaT: deltaT))
        let now = try look(at: target, AstroTime(date, deltaT: deltaT))
        let after = try look(at: target, AstroTime(date + h, deltaT: deltaT))
        return TrackPoint(date: date, position: now,
                          azimuthRate: wrap180(after.azimuth - before.azimuth) / (2 * h),
                          altitudeRate: (after.altitude - before.altitude) / (2 * h))
    }
}

public struct TrackPoint: Sendable {
    public let date: Date
    public let position: Horizontal
    /// Degrees per second.
    public let azimuthRate: Double
    /// Degrees per second.
    public let altitudeRate: Double
}
