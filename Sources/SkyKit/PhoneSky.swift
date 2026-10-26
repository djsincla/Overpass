import Foundation

/// Where things in the sky land on a phone's screen when it's held up to the sky.
///
/// The phone's attitude comes as a rotation taking vectors in the sky frame (x north, y west,
/// z up, as Core Motion's true-north frame) into the device frame (x to the right of the screen,
/// y to its top, z out of the screen towards you). The back camera looks along -z.
public struct PhoneSkyProjection: Sendable {
    /// How the interface is turned relative to the device, which decides which way is up on screen.
    public enum Orientation: Sendable {
        case portrait, portraitUpsideDown
        /// Home side on the right: the device's top points left.
        case landscapeRight
        /// Home side on the left: the device's top points right.
        case landscapeLeft
    }

    /// Rows of the sky-to-device rotation (Core Motion's `rotationMatrix`, m11 m12 m13 first).
    public var rotation: [[Double]]
    /// Screen points per unit of tangent: half the long side over tan(half the long-side field of view).
    public var focal: Double
    public var width: Double
    public var height: Double
    public var orientation: Orientation

    public init(rotation: [[Double]], focal: Double, width: Double, height: Double, orientation: Orientation) {
        precondition(rotation.count == 3 && rotation.allSatisfy { $0.count == 3 })
        self.rotation = rotation
        self.focal = focal
        self.width = width
        self.height = height
        self.orientation = orientation
    }

    /// The focal length for a camera whose field of view spans `degrees` across the screen's long side.
    public static func focal(longSide: Double, fieldOfView degrees: Double) -> Double {
        longSide / 2 / tan(degrees.radians / 2)
    }

    /// The sky direction as a unit vector in the sky frame.
    static func skyVector(_ h: Horizontal) -> (Double, Double, Double) {
        let alt = h.altitude.radians, az = h.azimuth.radians
        return (cos(alt) * cos(az), -cos(alt) * sin(az), sin(alt))
    }

    private func device(_ h: Horizontal) -> (x: Double, y: Double, z: Double) {
        let v = Self.skyVector(h)
        func row(_ r: [Double]) -> Double { r[0] * v.0 + r[1] * v.1 + r[2] * v.2 }
        return (row(rotation[0]), row(rotation[1]), row(rotation[2]))
    }

    /// Device x and y turned into screen right and up.
    private func screenAxes(_ d: (x: Double, y: Double, z: Double)) -> (right: Double, up: Double) {
        switch orientation {
        case .portrait: (d.x, d.y)
        case .portraitUpsideDown: (-d.x, -d.y)
        case .landscapeRight: (-d.y, d.x)
        case .landscapeLeft: (d.y, -d.x)
        }
    }

    /// The screen point for a sky position, or nil when it's behind the camera.
    public func point(_ h: Horizontal) -> (x: Double, y: Double)? {
        let d = device(h)
        guard d.z < -1e-6 else { return nil }
        let s = screenAxes(d)
        let t = focal / -d.z
        return (width / 2 + s.right * t, height / 2 - s.up * t)
    }

    /// Whether a sky position is on screen, with `margin` points to spare.
    public func isOnScreen(_ h: Horizontal, margin: Double = 0) -> Bool {
        guard let p = point(h) else { return false }
        return p.x >= margin && p.x <= width - margin && p.y >= margin && p.y <= height - margin
    }

    /// Which way to turn to bring a sky position to the centre, as a screen angle (radians,
    /// 0 to the right, counter-clockwise, so π/2 is up). Works behind the camera too.
    public func turn(towards h: Horizontal) -> Double {
        let d = device(h)
        let s = screenAxes(d)
        if abs(s.right) < 1e-9 && abs(s.up) < 1e-9 { return -.pi / 2 }
        return atan2(s.up, s.right)
    }

    /// Where the back camera points.
    public var centre: Horizontal {
        // The sky-frame vector of device -z is minus the third row (the rotation is orthonormal).
        let x = -rotation[2][0], y = -rotation[2][1], z = -rotation[2][2]
        let altitude = asin(max(-1, min(1, z))).degrees
        let azimuth = normalizedDegrees(atan2(-y, x).degrees)
        return Horizontal(azimuth: azimuth, altitude: altitude, range: 0)
    }
}
