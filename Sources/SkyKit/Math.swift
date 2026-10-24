import Foundation

public struct Vec3: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (s: Double, v: Vec3) -> Vec3 { Vec3(s * v.x, s * v.y, s * v.z) }

    public func dot(_ o: Vec3) -> Double { x * o.x + y * o.y + z * o.z }
    public var length: Double { dot(self).squareRoot() }
    public var normalized: Vec3 { (1 / length) * self }

    /// Unit vector from spherical angles in degrees (longitude measured from +x towards +y).
    public static func unit(longitude: Double, latitude: Double) -> Vec3 {
        let lon = longitude.radians, lat = latitude.radians
        return Vec3(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
    }

    /// (longitude in [0, 360), latitude) in degrees.
    public var spherical: (longitude: Double, latitude: Double) {
        let r = length
        return (normalizedDegrees(atan2(y, x).degrees), asin(max(-1, min(1, z / r))).degrees)
    }
}

/// Angle between two directions, in degrees.
public func angularSeparation(_ a: Vec3, _ b: Vec3) -> Double {
    acos(max(-1, min(1, a.normalized.dot(b.normalized)))).degrees
}

/// Row-major 3×3 matrix. Rotation helpers are active (they rotate vectors, not axes).
public struct Mat3: Sendable {
    public var r0: Vec3, r1: Vec3, r2: Vec3

    public init(_ r0: Vec3, _ r1: Vec3, _ r2: Vec3) {
        self.r0 = r0
        self.r1 = r1
        self.r2 = r2
    }

    public static let identity = Mat3(Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1))

    public static func * (m: Mat3, v: Vec3) -> Vec3 { Vec3(m.r0.dot(v), m.r1.dot(v), m.r2.dot(v)) }

    public static func * (a: Mat3, b: Mat3) -> Mat3 {
        let t = b.transposed
        return Mat3(Vec3(a.r0.dot(t.r0), a.r0.dot(t.r1), a.r0.dot(t.r2)),
                    Vec3(a.r1.dot(t.r0), a.r1.dot(t.r1), a.r1.dot(t.r2)),
                    Vec3(a.r2.dot(t.r0), a.r2.dot(t.r1), a.r2.dot(t.r2)))
    }

    public var transposed: Mat3 {
        Mat3(Vec3(r0.x, r1.x, r2.x), Vec3(r0.y, r1.y, r2.y), Vec3(r0.z, r1.z, r2.z))
    }

    public static func rotX(_ degrees: Double) -> Mat3 {
        let c = cos(degrees.radians), s = sin(degrees.radians)
        return Mat3(Vec3(1, 0, 0), Vec3(0, c, -s), Vec3(0, s, c))
    }

    public static func rotY(_ degrees: Double) -> Mat3 {
        let c = cos(degrees.radians), s = sin(degrees.radians)
        return Mat3(Vec3(c, 0, s), Vec3(0, 1, 0), Vec3(-s, 0, c))
    }

    public static func rotZ(_ degrees: Double) -> Mat3 {
        let c = cos(degrees.radians), s = sin(degrees.radians)
        return Mat3(Vec3(c, -s, 0), Vec3(s, c, 0), Vec3(0, 0, 1))
    }
}

extension Double {
    public var radians: Double { self * .pi / 180 }
    public var degrees: Double { self * 180 / .pi }
}

/// Wraps to [0, 360).
public func normalizedDegrees(_ x: Double) -> Double {
    let r = x.truncatingRemainder(dividingBy: 360)
    return r < 0 ? r + 360 : r
}

/// Wraps to (-180, 180].
public func wrap180(_ x: Double) -> Double {
    let r = normalizedDegrees(x)
    return r > 180 ? r - 360 : r
}
