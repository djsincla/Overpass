import Foundation
import Testing
@testable import SkyKit

/// `syntheticFrame` at a given time; `objects` are (x, y, peak), negative for dark ones.
private func frame(at t: Double, objects: [(Double, Double, Double)], background: Double = 20) -> GrayFrame {
    let f = syntheticFrame(spot: nil, background: background, extra: objects)
    return GrayFrame(width: f.width, height: f.height, pixels: f.pixels, timestamp: Date(timeIntervalSinceReferenceDate: t))
}

@Suite struct BlobFinderTests {
    @Test func findsBrightAndDarkBlobs() {
        let f = frame(at: 0, objects: [(100.4, 80.6, 120), (140, 90, -100)], background: 150)
        let blobs = BlobFinder().blobs(in: f, around: (120, 85), radius: 40)
        let bright = blobs.first { $0.polarity > 0 }, dark = blobs.first { $0.polarity < 0 }
        #expect(bright.map { abs($0.x - 100.4) < 0.3 && abs($0.y - 80.6) < 0.3 } == true)
        #expect(dark.map { abs($0.x - 140) < 0.3 && abs($0.y - 90) < 0.3 } == true)
    }

    @Test func emptySkyHasNoBlobs() {
        #expect(BlobFinder().blobs(in: frame(at: 0, objects: []), around: (160, 120), radius: 100).isEmpty)
    }
}

@Suite struct MovingObjectTrackerTests {
    /// A satellite crossing at 60 px/s, 30 frames a second, with a star it passes close to.
    @Test func followsAMovingObjectPastAStar() throws {
        let star = (180.0, 122.0, 150.0)
        func satellite(_ t: Double) -> (Double, Double) { (60 + 60 * t, 120 + 10 * t) }
        let start = satellite(0)
        var tracker = try #require(MovingObjectTracker(frame: frame(at: 0, objects: [(start.0, start.1, 100), star]),
                                                       at: (start.0 + 6, start.1 - 4)))
        for i in 1...90 {
            let t = Double(i) / 30
            let s = satellite(t)
            tracker.update(frame(at: t, objects: [(s.0, s.1, 100), star]))
            #expect(hypot(tracker.x - s.0, tracker.y - s.1) < 1, "frame \(i)")
        }
        #expect(abs(tracker.vx - 60) < 3 && abs(tracker.vy - 10) < 3)
        #expect(tracker.state == .locked)
    }

    /// With the mount moving, the object sits still in the image while the image as a whole shifts.
    @Test func mountShiftKeepsTheObjectsOwnVelocity() throws {
        var tracker = try #require(MovingObjectTracker(frame: frame(at: 0, objects: [(160, 120, 100)]), at: (160, 120)))
        for i in 1...30 {
            // The mount moves the image 2 px a frame, and the object's motion cancels it exactly.
            tracker.update(frame(at: Double(i) / 30, objects: [(160, 120, 100)]), mountShift: (2, 0))
        }
        #expect(abs(tracker.vx + 60) < 3 && abs(tracker.vy) < 3)
    }

    @Test func coastsThroughAGapThenLosesIt() throws {
        var tracker = try #require(MovingObjectTracker(frame: frame(at: 0, objects: [(100, 120, 100)]), at: (100, 120)))
        for i in 1...10 { tracker.update(frame(at: Double(i) / 30, objects: [(100 + 30 * Double(i) / 30, 120, 100)])) }
        // Behind a cloud for half a second: still predicted along its path, then picked up again.
        for i in 11...25 { tracker.update(frame(at: Double(i) / 30, objects: [])) }
        #expect(tracker.state == .coasting)
        tracker.update(frame(at: 26.0 / 30, objects: [(126, 120, 100)]))
        #expect(tracker.state == .locked)
        for i in 27...120 { tracker.update(frame(at: Double(i) / 30, objects: [])) }
        #expect(tracker.state == .lost)
    }

    @Test func nothingToLockOnto() {
        #expect(MovingObjectTracker(frame: frame(at: 0, objects: []), at: (160, 120)) == nil)
    }
}

@Suite struct MotionEstimatorTests {
    @Test func recoversRateAndExtrapolates() throws {
        var estimator = MotionEstimator()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        for i in 0..<30 {
            let t = Double(i) / 30
            estimator.add(AxisPosition(primary: 10 + 1.5 * t, secondary: 40 - 0.5 * t), at: t0 + t)
        }
        let e = try #require(estimator.estimate(at: t0 + 1.2))
        #expect(abs(e.primaryRate - 1.5) < 1e-9 && abs(e.secondaryRate + 0.5) < 1e-9)
        #expect(abs(e.position.primary - 11.8) < 1e-9 && abs(e.position.secondary - 39.4) < 1e-9)
    }

    @Test func needsAFewSightingsFirst() {
        var estimator = MotionEstimator()
        estimator.add(AxisPosition(primary: 0, secondary: 0), at: Date(timeIntervalSinceReferenceDate: 0))
        estimator.add(AxisPosition(primary: 0.1, secondary: 0), at: Date(timeIntervalSinceReferenceDate: 0.1))
        #expect(estimator.estimate(at: Date(timeIntervalSinceReferenceDate: 0.2)) == nil)
    }
}

@Suite struct CameraCalibrationShiftTests {
    @Test func imageShiftInvertsAxisCorrection() throws {
        let c = CameraCalibration(primaryShift: (300, 40), primaryDegrees: 1, secondaryShift: (-30, 280), secondaryDegrees: 1, altitude: 30)
        let shift = c.imageShift(primary: 0.2, secondary: -0.1, altitude: 50)
        // Moving the axes by the correction for that offset should undo it.
        let back = try #require(c.axisCorrection(offset: shift, altitude: 50))
        #expect(abs(back.primary + 0.2) < 1e-9 && abs(back.secondary - 0.1) < 1e-9)
    }
}
