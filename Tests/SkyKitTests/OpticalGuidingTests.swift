import Foundation
import Testing
@testable import SkyKit

/// A noisy sky with a Gaussian spot at (x, y).
func syntheticFrame(width: Int = 320, height: Int = 240, spot: (x: Double, y: Double)?, peak: Double = 120,
                    sigma: Double = 1.6, background: Double = 20, noise: Double = 3, extra: [(Double, Double, Double)] = []) -> GrayFrame {
    var rng = SystemRandomNumberGenerator()
    var pixels = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            var v = background + Double.random(in: -noise...noise, using: &rng)
            for (sx, sy, p) in (spot.map { [($0.x, $0.y, peak)] } ?? []) + extra {
                let d2 = (Double(x) - sx) * (Double(x) - sx) + (Double(y) - sy) * (Double(y) - sy)
                v += p * exp(-d2 / (2 * sigma * sigma))
            }
            pixels[y * width + x] = UInt8(max(0, min(255, v)))
        }
    }
    return GrayFrame(width: width, height: height, pixels: pixels, timestamp: .now)
}

@Suite struct SpotDetectorTests {
    @Test func findsSpotToSubPixel() throws {
        let spot = try #require(SpotDetector().find(in: syntheticFrame(spot: (171.3, 108.7))))
        #expect(abs(spot.x - 171.3) < 0.2 && abs(spot.y - 108.7) < 0.2)
        #expect(spot.signalToNoise > 8)
    }

    @Test func ignoresEmptySky() {
        #expect(SpotDetector().find(in: syntheticFrame(spot: nil)) == nil)
    }

    @Test func ignoresBrightObjectOutsideSearchArea() throws {
        // A brighter object near the corner shouldn't steal the lock from the target near the centre.
        let frame = syntheticFrame(spot: (150, 130), peak: 90, extra: [(10, 10, 200)])
        let spot = try #require(SpotDetector().find(in: frame))
        #expect(abs(spot.x - 150) < 0.5 && abs(spot.y - 130) < 0.5)
    }
}

@Suite struct CameraCalibrationTests {
    /// A camera rotated 30° and mirrored, at 12″/px, calibrated at 40° altitude.
    let calibration: CameraCalibration = {
        let scale = 3600.0 / 12
        let r = 30.0.radians
        // Altitude moves the image along (cos r, sin r); azimuth along the perpendicular, mirrored.
        return CameraCalibration(primaryShift: (x: -sin(r) * scale * cos(40.0.radians) * 0.5, y: cos(r) * scale * cos(40.0.radians) * 0.5),
                                 primaryDegrees: 0.5,
                                 secondaryShift: (x: cos(r) * scale * 0.2, y: sin(r) * scale * 0.2), secondaryDegrees: 0.2,
                                 altitude: 40)
    }()

    @Test func scaleAndRotation() {
        #expect(abs(calibration.arcsecondsPerPixel - 12) < 1e-9)
        #expect(abs(calibration.rotation - 30) < 1e-9)
        #expect(!calibration.isDegenerate)
    }

    @Test func correctionUndoesAKnownMove() throws {
        // If the mount were off by (+0.1° az, −0.05° alt), the spot would sit at this offset…
        let p = 0.1, s = -0.05
        let offset = (x: -(calibration.primaryX * p + calibration.secondaryX * s),
                      y: -(calibration.primaryY * p + calibration.secondaryY * s))
        // …and the correction recovers exactly that move.
        let c = try #require(calibration.axisCorrection(offset: offset, altitude: 40))
        #expect(abs(c.primary - p) < 1e-9 && abs(c.secondary - s) < 1e-9)
    }

    @Test func azimuthScaleFollowsAltitude() throws {
        // Higher up, the same image offset needs a bigger azimuth move.
        let low = try #require(calibration.axisCorrection(offset: (x: 10, y: 0), altitude: 40))
        let high = try #require(calibration.axisCorrection(offset: (x: 10, y: 0), altitude: 70))
        #expect(abs(high.primary) > abs(low.primary))
        // The camera's axes are perpendicular here, so the altitude part doesn't depend on altitude.
        #expect(abs(high.secondary - low.secondary) < 1e-9)
        #expect(abs(high.primary / low.primary - cos(40.0.radians) / cos(70.0.radians)) < 1e-9)
    }
}

@Suite struct OpticalGuideTests {
    let zero = OpticalGuide.Update(timeOffset: 0, azimuthOffset: 0, altitudeOffset: 0)

    @Test func alongTrackErrorBecomesTime() {
        var guide = OpticalGuide()
        guide.gain = 1
        // Moving straight up at 1°/s; the target is 0.1° further along (needs +0.1° altitude).
        let u = guide.update(zero, correction: (primary: 0, secondary: 0.1), azimuthRate: 0, altitudeRate: 1, altitude: 30)
        #expect(abs(u.timeOffset - 0.1) < 1e-9)
        #expect(abs(u.azimuthOffset) < 1e-9 && abs(u.altitudeOffset) < 1e-9)
    }

    @Test func crossTrackErrorBecomesOffset() {
        var guide = OpticalGuide()
        guide.gain = 1
        let u = guide.update(zero, correction: (primary: 0.1, secondary: 0), azimuthRate: 0, altitudeRate: 1, altitude: 0)
        #expect(abs(u.timeOffset) < 1e-9)
        #expect(abs(u.azimuthOffset - 0.1) < 1e-9)
    }

    @Test func stationaryTargetUsesOffsetsOnly() {
        var guide = OpticalGuide()
        guide.gain = 1
        let u = guide.update(zero, correction: (primary: 0.05, secondary: -0.02), azimuthRate: 0, altitudeRate: 0, altitude: 45)
        #expect(u.timeOffset == 0)
        #expect(abs(u.azimuthOffset - 0.05) < 1e-9 && abs(u.altitudeOffset + 0.02) < 1e-9)
    }

    @Test func wildDetectionIsCapped() {
        let guide = OpticalGuide()
        let u = guide.update(zero, correction: (primary: 0, secondary: 10), azimuthRate: 1, altitudeRate: 0, altitude: 0)
        #expect(abs(u.altitudeOffset) <= guide.gain * guide.maximumStep + 1e-9)
    }
}
