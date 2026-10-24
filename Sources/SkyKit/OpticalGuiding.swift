import Foundation

/// An 8-bit grayscale camera frame (the luma plane is enough to find a bright spot).
public struct GrayFrame: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]
    /// When the light was captured, not when the frame arrived; the guide loop corrects for the gap.
    public let timestamp: Date

    public init(width: Int, height: Int, pixels: [UInt8], timestamp: Date) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
        self.timestamp = timestamp
    }

    public subscript(x: Int, y: Int) -> UInt8 { pixels[y * width + x] }

    public var center: (x: Double, y: Double) { (Double(width - 1) / 2, Double(height - 1) / 2) }
}

public struct Spot: Sendable, Equatable {
    /// Sub-pixel centroid.
    public let x: Double
    public let y: Double
    /// Peak brightness above the background, in units of the background noise.
    public let signalToNoise: Double
}

/// Finds the brightest compact spot in a frame: a satellite, star or planet against the sky.
public struct SpotDetector: Sendable {
    /// How far above the background noise the peak must be to count.
    public var minimumSignalToNoise: Double = 8
    /// Half-width of the box used for the centroid, in pixels.
    public var centroidRadius = 4
    /// Only look within this fraction of the frame's shorter side from the centre, so a bright
    /// object at the edge (the Moon, a streetlight) doesn't steal the lock.
    public var searchFraction = 0.4

    public init() {}

    public func find(in frame: GrayFrame) -> Spot? {
        let (background, noise) = backgroundLevel(frame)
        let (cx, cy) = frame.center
        let radius = searchFraction * Double(min(frame.width, frame.height))
        let x0 = max(0, Int(cx - radius)), x1 = min(frame.width - 1, Int(cx + radius))
        let y0 = max(0, Int(cy - radius)), y1 = min(frame.height - 1, Int(cy + radius))
        guard x0 < x1, y0 < y1 else { return nil }

        var best = (x: 0, y: 0, value: UInt8(0))
        for y in y0...y1 {
            for x in x0...x1 where frame[x, y] > best.value {
                best = (x, y, frame[x, y])
            }
        }
        let snr = (Double(best.value) - background) / max(noise, 1)
        guard snr >= minimumSignalToNoise else { return nil }

        // Background-subtracted centroid around the peak.
        let r = centroidRadius
        var sum = 0.0, sx = 0.0, sy = 0.0
        for y in max(0, best.y - r)...min(frame.height - 1, best.y + r) {
            for x in max(0, best.x - r)...min(frame.width - 1, best.x + r) {
                let w = Double(frame[x, y]) - background - noise
                if w > 0 {
                    sum += w
                    sx += w * Double(x)
                    sy += w * Double(y)
                }
            }
        }
        guard sum > 0 else { return nil }
        return Spot(x: sx / sum, y: sy / sum, signalToNoise: snr)
    }

    /// Median and a robust spread (from the median absolute deviation) of a pixel sample.
    func backgroundLevel(_ frame: GrayFrame) -> (median: Double, noise: Double) {
        let stride = max(1, frame.pixels.count / 20_000)
        var sample = [UInt8]()
        sample.reserveCapacity(frame.pixels.count / stride + 1)
        for i in Swift.stride(from: 0, to: frame.pixels.count, by: stride) { sample.append(frame.pixels[i]) }
        sample.sort()
        let median = Double(sample[sample.count / 2])
        var deviations = sample.map { abs(Double($0) - median) }
        deviations.sort()
        return (median, 1.4826 * deviations[deviations.count / 2])
    }
}

/// How the image moves when the mount moves, measured by jogging each axis.
///
/// The camera rides on the tube of an alt-az mount, so these directions stay fixed in the image
/// as the mount moves; only the azimuth scale changes, shrinking with cos(altitude).
public struct CameraCalibration: Codable, Sendable, Equatable {
    /// Image motion, in pixels, per degree of primary (azimuth) axis at `altitude`.
    public var primaryX: Double
    public var primaryY: Double
    /// Image motion, in pixels, per degree of secondary (altitude) axis.
    public var secondaryX: Double
    public var secondaryY: Double
    /// The altitude the azimuth step was measured at.
    public var altitude: Double

    public init(primaryShift: (x: Double, y: Double), primaryDegrees: Double,
                secondaryShift: (x: Double, y: Double), secondaryDegrees: Double, altitude: Double) {
        primaryX = primaryShift.x / primaryDegrees
        primaryY = primaryShift.y / primaryDegrees
        secondaryX = secondaryShift.x / secondaryDegrees
        secondaryY = secondaryShift.y / secondaryDegrees
        self.altitude = altitude
    }

    /// Arc-seconds per pixel, from the altitude axis (which doesn't foreshorten).
    public var arcsecondsPerPixel: Double { 3600 / (secondaryX * secondaryX + secondaryY * secondaryY).squareRoot() }

    /// Angle of the altitude axis's motion in the image, degrees (for showing the camera's rotation).
    public var rotation: Double { atan2(secondaryY, secondaryX).degrees }

    /// The two axes' image directions are too close to separate errors reliably.
    public var isDegenerate: Bool {
        abs(primaryX * secondaryY - primaryY * secondaryX) < 1e-6 * max(1, primaryX * primaryX + secondaryY * secondaryY)
    }

    /// The axis moves (degrees) that would bring a spot at `offset` pixels from the centre to the centre.
    public func axisCorrection(offset: (x: Double, y: Double), altitude now: Double) -> (primary: Double, secondary: Double)? {
        // Azimuth steps foreshorten with cos(altitude) relative to when this was measured.
        let scale = cos(now.radians) / max(cos(altitude.radians), 1e-3)
        let a = primaryX * scale, b = secondaryX, c = primaryY * scale, d = secondaryY
        let det = a * d - b * c
        guard abs(det) > 1e-9 else { return nil }
        // Solve [a b; c d]·[p s] = −offset: move so the spot's image shifts back to the centre.
        let p = (-offset.x * d + offset.y * b) / det
        let s = (-offset.y * a + offset.x * c) / det
        return (p, s)
    }
}

/// Turns measured pointing errors into the tracker's fine-tune offsets.
///
/// Error along the satellite's track is nearly all TLE timing, so it goes into the time offset,
/// which also corrects the predicted rates. Error across the track goes into azimuth/altitude.
public struct OpticalGuide: Sendable {
    /// Fraction of each measured error corrected per frame.
    public var gain = 0.3
    /// Cap on a single correction, degrees, so one wild detection can't jerk the mount.
    public var maximumStep = 0.25

    public init() {}

    public struct Update: Sendable, Equatable {
        public var timeOffset: TimeInterval
        public var azimuthOffset: Double
        public var altitudeOffset: Double

        public init(timeOffset: TimeInterval, azimuthOffset: Double, altitudeOffset: Double) {
            self.timeOffset = timeOffset
            self.azimuthOffset = azimuthOffset
            self.altitudeOffset = altitudeOffset
        }
    }

    /// - Parameters:
    ///   - correction: axis moves (degrees) that would centre the target.
    ///   - azimuthRate, altitudeRate: the target's motion now, degrees per second.
    ///   - altitude: the target's altitude, for azimuth foreshortening.
    public func update(_ current: Update, correction: (primary: Double, secondary: Double),
                       azimuthRate: Double, altitudeRate: Double, altitude: Double) -> Update {
        let cosAlt = max(cos(altitude.radians), 1e-3)
        // Work in true angles on the sky.
        var ex = correction.primary * cosAlt, ey = correction.secondary
        let size = (ex * ex + ey * ey).squareRoot()
        if size > maximumStep {
            ex *= maximumStep / size
            ey *= maximumStep / size
        }
        var next = current
        let vx = azimuthRate * cosAlt, vy = altitudeRate
        let speed = (vx * vx + vy * vy).squareRoot()
        if speed > 0.01 {
            // Along-track: the target is ahead (positive) or behind; shift the clock to match.
            let along = (ex * vx + ey * vy) / speed
            next.timeOffset += gain * along / speed
            ex -= along * vx / speed
            ey -= along * vy / speed
        }
        next.azimuthOffset += gain * ex / cosAlt
        next.altitudeOffset += gain * ey
        return next
    }
}
