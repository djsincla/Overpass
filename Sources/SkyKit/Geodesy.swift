import Foundation

/// A place on the WGS84 ellipsoid.
public struct Geodetic: Equatable, Sendable, Codable {
    /// Degrees, north positive.
    public var latitude: Double
    /// Degrees, east positive, in (−180, 180].
    public var longitude: Double
    /// Height above the ellipsoid, km.
    public var height: Double

    public init(latitude: Double, longitude: Double, height: Double = 0) {
        self.latitude = latitude
        self.longitude = longitude
        self.height = height
    }

    public var observer: Observer { Observer(latitude: latitude, longitude: longitude, height: height * 1000, refraction: false) }
}

extension Vec3 {
    public func cross(_ o: Vec3) -> Vec3 {
        Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x)
    }
}

/// Earth-fixed ↔ geodetic conversion, rays meeting the ground, and distances on it.
public enum Geodesy {
    /// Mean Earth radius for distances and bearings, km.
    public static let meanRadius = 6371.0088

    static var e2: Double { Observer.wgs84F * (2 - Observer.wgs84F) }

    /// The inverse of `Observer`'s geodetic → Earth-fixed conversion (iterated to well under a metre).
    public static func geodetic(ofEarthFixed p: Vec3) -> Geodetic {
        let a = Observer.wgs84A
        let r = (p.x * p.x + p.y * p.y).squareRoot()
        var lat = atan2(p.z, r * (1 - e2))
        var h = 0.0
        for _ in 0..<8 {
            let n = a / (1 - e2 * sin(lat) * sin(lat)).squareRoot()
            h = r / cos(lat) - n
            lat = atan2(p.z, r * (1 - e2 * n / (n + h)))
        }
        return Geodetic(latitude: lat.degrees, longitude: atan2(p.y, p.x).degrees, height: h)
    }

    public static func earthFixed(_ g: Geodetic) -> Vec3 { g.observer.position }

    /// Where the ray `origin + λ·direction` (λ > 0) first meets the ellipsoid, or nil if it misses.
    public static func intersectEllipsoid(origin o: Vec3, direction d: Vec3) -> Vec3? {
        let a = Observer.wgs84A, b = a * (1 - Observer.wgs84F)
        // Scale z so the ellipsoid becomes the unit sphere.
        let os = Vec3(o.x / a, o.y / a, o.z / b), ds = Vec3(d.x / a, d.y / a, d.z / b)
        let qa = ds.dot(ds), qb = 2 * os.dot(ds), qc = os.dot(os) - 1
        let disc = qb * qb - 4 * qa * qc
        guard qa > 0, disc >= 0 else { return nil }
        let root = disc.squareRoot()
        let near = (-qb - root) / (2 * qa), far = (-qb + root) / (2 * qa)
        let lambda = near > 0 ? near : far
        guard lambda > 0 else { return nil }
        return o + lambda * d
    }

    /// Great-circle distance, km.
    public static func distance(_ a: Geodetic, _ b: Geodetic) -> Double {
        let p1 = a.latitude.radians, p2 = b.latitude.radians
        let dp = p2 - p1, dl = (b.longitude - a.longitude).radians
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * meanRadius * asin(min(1, h.squareRoot()))
    }

    /// The point `angle` degrees of arc from `start` along `bearing` (degrees east of north), on a sphere.
    public static func destination(from start: Geodetic, bearing: Double, angle: Double) -> Geodetic {
        let lat1 = start.latitude.radians, lon1 = start.longitude.radians
        let theta = bearing.radians, delta = angle.radians
        let lat2 = asin(sin(lat1) * cos(delta) + cos(lat1) * sin(delta) * cos(theta))
        let lon2 = lon1 + atan2(sin(theta) * sin(delta) * cos(lat1), cos(delta) - sin(lat1) * sin(lat2))
        return Geodetic(latitude: lat2.degrees, longitude: wrap180(lon2.degrees))
    }

    /// Initial bearing from `a` to `b`, degrees east of north.
    public static func bearing(from a: Geodetic, to b: Geodetic) -> Double {
        let p1 = a.latitude.radians, p2 = b.latitude.radians, dl = (b.longitude - a.longitude).radians
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return normalizedDegrees(atan2(y, x).degrees)
    }

    /// Shortest distance from `point` to a polyline (km), treating each segment as straight in a
    /// local flat projection: fine over the few hundred km a transit path spans.
    public static func distance(from point: Geodetic, toPath path: [Geodetic]) -> Double {
        guard let first = path.first else { return .infinity }
        guard path.count > 1 else { return distance(point, first) }
        let k = cos(point.latitude.radians)
        func flat(_ g: Geodetic) -> (x: Double, y: Double) {
            (wrap180(g.longitude - point.longitude).radians * k * meanRadius, (g.latitude - point.latitude).radians * meanRadius)
        }
        var best = Double.infinity
        for (a, b) in zip(path, path.dropFirst()) {
            let p = flat(a), q = flat(b)
            let dx = q.x - p.x, dy = q.y - p.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared > 0 ? max(0, min(1, -(p.x * dx + p.y * dy) / lengthSquared)) : 0
            let x = p.x + t * dx, y = p.y + t * dy
            best = min(best, (x * x + y * y).squareRoot())
        }
        return best
    }

    /// The point `distance` km from `start` on `bearing`.
    public static func destination(from start: Geodetic, bearing: Double, distance: Double) -> Geodetic {
        let d = distance / meanRadius, t = bearing.radians, p1 = start.latitude.radians
        let p2 = asin(sin(p1) * cos(d) + cos(p1) * sin(d) * cos(t))
        let l2 = start.longitude.radians + atan2(sin(t) * sin(d) * cos(p1), cos(d) - sin(p1) * sin(p2))
        return Geodetic(latitude: p2.degrees, longitude: wrap180(l2.degrees))
    }
}
