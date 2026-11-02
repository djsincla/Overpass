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
    /// How far below the screen's middle the camera's centre is drawn, in points. In landscape the
    /// picture is cropped top and bottom, so it can slide down to put the horizon lower; the sky
    /// slides with it.
    public var verticalShift = 0.0

    public init(rotation: [[Double]], focal: Double, width: Double, height: Double, orientation: Orientation,
                verticalShift: Double = 0) {
        precondition(rotation.count == 3 && rotation.allSatisfy { $0.count == 3 })
        self.rotation = rotation
        self.focal = focal
        self.width = width
        self.height = height
        self.orientation = orientation
        self.verticalShift = verticalShift
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
        return (width / 2 + s.right * t, height / 2 + verticalShift - s.up * t)
    }

    /// The sky position under a screen point: the inverse of `point`.
    public func horizontal(atX x: Double, y: Double) -> Horizontal {
        let right = (x - width / 2) / focal, up = -(y - height / 2 - verticalShift) / focal
        // Screen right and up back to device x and y (the inverse of `screenAxes`); the camera looks along -z.
        let (dx, dy): (Double, Double) = switch orientation {
        case .portrait: (right, up)
        case .portraitUpsideDown: (-right, -up)
        case .landscapeRight: (up, -right)
        case .landscapeLeft: (-up, right)
        }
        let d = (dx, dy, -1.0)
        // Device to sky is the transpose of the sky-to-device rotation.
        let sx = rotation[0][0] * d.0 + rotation[1][0] * d.1 + rotation[2][0] * d.2
        let sy = rotation[0][1] * d.0 + rotation[1][1] * d.1 + rotation[2][1] * d.2
        let sz = rotation[0][2] * d.0 + rotation[1][2] * d.1 + rotation[2][2] * d.2
        let length = (sx * sx + sy * sy + sz * sz).squareRoot()
        return Horizontal(azimuth: normalizedDegrees(atan2(-sy, sx).degrees),
                          altitude: asin(max(-1, min(1, sz / length))).degrees, range: 0)
    }

    /// Core Motion's rotation with two corrections set by hand: `heading` degrees added to every
    /// azimuth (for a compass that's out), and `tilt` degrees turning the picture about the
    /// screen's horizontal, positive moving what's drawn up.
    public static func adjusted(_ rotation: [[Double]], heading: Double, tilt: Double, orientation: Orientation) -> [[Double]] {
        let h = heading.radians
        // Sky vectors turned so an azimuth az is taken as az + heading.
        let turn = [[cos(h), sin(h), 0.0], [-sin(h), cos(h), 0], [0, 0, 1]]
        // The screen's right in device axes, the axis tilting turns about.
        let a: (Double, Double, Double) = switch orientation {
        case .portrait: (1, 0, 0)
        case .portraitUpsideDown: (-1, 0, 0)
        case .landscapeRight: (0, -1, 0)
        case .landscapeLeft: (0, 1, 0)
        }
        let t = tilt.radians, c = cos(t), s = sin(t), k = 1 - c
        let tip = [[c + a.0 * a.0 * k, a.0 * a.1 * k - a.2 * s, a.0 * a.2 * k + a.1 * s],
                   [a.1 * a.0 * k + a.2 * s, c + a.1 * a.1 * k, a.1 * a.2 * k - a.0 * s],
                   [a.2 * a.0 * k - a.1 * s, a.2 * a.1 * k + a.0 * s, c + a.2 * a.2 * k]]
        func product(_ x: [[Double]], _ y: [[Double]]) -> [[Double]] {
            (0..<3).map { i in (0..<3).map { j in (0..<3).reduce(0) { $0 + x[i][$1] * y[$1][j] } } }
        }
        return product(tip, product(rotation, turn))
    }

    /// The field of view (degrees across the long side) that puts one star under two taps made
    /// with the device turned between them: wherever the star is, both taps must point the same
    /// way in the sky. Nil when the taps are too close on screen, or the device barely turned, to tell.
    public static func calibratedFieldOfView(first: (rotation: [[Double]], x: Double, y: Double),
                                             second: (rotation: [[Double]], x: Double, y: Double),
                                             width: Double, height: Double, orientation: Orientation,
                                             verticalShift: Double = 0) -> Double? {
        guard hypot(first.x - second.x, first.y - second.y) > min(width, height) / 4 else { return nil }
        func separation(_ fieldOfView: Double) -> Double {
            let focal = focal(longSide: max(width, height), fieldOfView: fieldOfView)
            func ray(_ tap: (rotation: [[Double]], x: Double, y: Double)) -> Horizontal {
                PhoneSkyProjection(rotation: tap.rotation, focal: focal, width: width, height: height,
                                   orientation: orientation, verticalShift: verticalShift)
                    .horizontal(atX: tap.x, y: tap.y)
            }
            let a = skyVector(ray(first)), b = skyVector(ray(second))
            return acos(max(-1, min(1, a.0 * b.0 + a.1 * b.1 + a.2 * b.2)))
        }
        // Scan, then narrow down on the best by golden sections.
        var best = stride(from: 10.0, through: 120, by: 0.5).min { separation($0) < separation($1) }!
        var low = max(10, best - 0.5), high = min(120, best + 0.5)
        let ratio = (5.0.squareRoot() - 1) / 2
        for _ in 0..<40 {
            let a = high - ratio * (high - low), b = low + ratio * (high - low)
            if separation(a) < separation(b) { high = b } else { low = a }
        }
        best = (low + high) / 2
        // A good fit leaves the two taps within a degree of each other; a miss means the taps weren't the same star.
        guard separation(best) < 1.0.radians, best > 10.5, best < 119.5 else { return nil }
        return best
    }

    /// Where the camera's centre is on screen: where `centre` is drawn.
    public var opticalCentre: (x: Double, y: Double) { (width / 2, height / 2 + verticalShift) }

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
