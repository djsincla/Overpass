import Foundation
import Testing
@testable import SkyKit

/// A 480 × 270 frame of rippled water with a boat on it: blocks of light hull and dark cabin,
/// nothing like a bright point. `noise` adds a different speckle to every frame.
private func scene(at t: Double, boat: (x: Double, y: Double)?, noise: UInt64 = 1, background shift: Double = 0) -> GrayFrame {
    let w = 480, h = 270
    var pixels = [UInt8](repeating: 0, count: w * h)
    var seed = UInt64(t * 1000) &+ 17
    for y in 0..<h {
        for x in 0..<w {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let wx = Double(x) - shift
            var v = 110 + 35 * sin(wx / 7 + Double(y) / 3) + 25 * sin(Double(y) / 11 - wx / 23) + Double(seed >> 62) * Double(noise)
            if let boat {
                // 48 × 20, its top-left corner at the given point.
                let bx = Double(x) - boat.x, by = Double(y) - boat.y
                if bx >= 0, bx < 48, by >= 0, by < 20 {
                    v = by < 8 ? (bx > 14 && bx < 30 ? 40 : 200) : (by < 16 ? 225 : 70)
                }
            }
            pixels[y * w + x] = UInt8(max(0, min(255, v)))
        }
    }
    return GrayFrame(width: w, height: h, pixels: pixels, timestamp: Date(timeIntervalSinceReferenceDate: t))
}

/// The boat's centre, from its top-left corner.
private func centre(_ corner: (x: Double, y: Double)) -> (x: Double, y: Double) { (corner.x + 23.5, corner.y + 9.5) }

@Suite struct PatchTrackerTests {
    /// The case the sky tracker can't do: something that isn't a spot, over a busy background
    /// that stays put while it moves.
    @Test func followsABoatOverStillWater() throws {
        func boat(_ t: Double) -> (x: Double, y: Double) { (60 + 90 * t, 120 - 12 * t) }
        let c = centre(boat(0))
        var tracker = try #require(PatchTracker(frame: scene(at: 0, boat: boat(0)), centre: (c.x + 2, c.y - 1), width: 52, height: 24))
        for i in 1...90 {
            let t = Double(i) / 30
            let found = tracker.follow(scene(at: t, boat: boat(t)))
            #expect(found, "frame \(i)")
            // Picked 2 px right and 1 px up of the boat's centre, so the patch stays that far off it.
            let truth = centre(boat(t))
            #expect(hypot(tracker.x - 2 - truth.x, tracker.y + 1 - truth.y) < 1.5, "frame \(i): \(tracker.x), \(tracker.y) vs \(truth)")
        }
        // The boat is drawn in whole pixels, so it climbs in 1 px jumps every 2.5 frames and the
        // filtered speed jitters by a few px/s. (The mount fits its own line over a second.)
        #expect(abs(tracker.vx - 90) < 5 && abs(tracker.vy + 12) < 8, "\(tracker.vx), \(tracker.vy)")
        #expect(tracker.state == .locked)
    }

    /// Following with the mount: the boat stays near the middle while the water slides past.
    @Test func mountMotionMovesTheBackgroundNotTheBoat() throws {
        let corner = (x: 216.0, y: 125.0)
        var tracker = try #require(PatchTracker(frame: scene(at: 0, boat: corner), centre: centre(corner), width: 48, height: 20))
        for i in 1...60 {
            let t = Double(i) / 30
            // The mount turns to follow, so the image shifts 3 px a frame and the boat's own motion cancels it.
            let found = tracker.follow(scene(at: t, boat: corner, background: -3 * Double(i)), mountShift: (-3, 0))
            #expect(found)
        }
        #expect(hypot(tracker.x - centre(corner).x, tracker.y - centre(corner).y) < 1)
        #expect(abs(tracker.vx - 90) < 6, "its own speed, which the mount is matching: \(tracker.vx)")
    }

    @Test func coastsBehindSomethingThenFindsItAgain() throws {
        func boat(_ t: Double) -> (x: Double, y: Double) { (80 + 60 * t, 120) }
        var tracker = try #require(PatchTracker(frame: scene(at: 0, boat: boat(0)), centre: centre(boat(0)), width: 48, height: 20))
        for i in 1...15 { tracker.follow(scene(at: Double(i) / 30, boat: boat(Double(i) / 30))) }
        // Hidden for half a second (behind a moored boat, say).
        for i in 16...30 { tracker.follow(scene(at: Double(i) / 30, boat: nil)) }
        #expect(tracker.state == .coasting)
        let t = 31.0 / 30
        let found = tracker.follow(scene(at: t, boat: boat(t)))
        #expect(found)
        #expect(hypot(tracker.x - centre(boat(t)).x, tracker.y - centre(boat(t)).y) < 1.5)
        // Gone for good.
        for i in 32...110 { tracker.follow(scene(at: Double(i) / 30, boat: nil)) }
        #expect(tracker.state == .lost)
    }

    @Test func subPixelPosition() throws {
        let start = (x: 200.0, y: 120.0)
        var tracker = try #require(PatchTracker(frame: scene(at: 0, boat: start, noise: 0), centre: centre(start), width: 48, height: 20))
        // A boat drawn whole pixels further on can't show a fraction; check the peak fit stays put
        // rather than snapping a half pixel.
        let moved = (x: 203.0, y: 121.0)
        let found = tracker.follow(scene(at: 1.0 / 30, boat: moved, noise: 0))
        #expect(found)
        #expect(abs(tracker.x - centre(moved).x) < 0.25 && abs(tracker.y - centre(moved).y) < 0.25)
        #expect(tracker.score > 0.95)
    }

    @Test func flatPatchIsRefused() {
        let sky = GrayFrame(width: 200, height: 100, pixels: [UInt8](repeating: 140, count: 20_000), timestamp: .now)
        #expect(PatchTracker(frame: sky, centre: (100, 50), width: 40, height: 20) == nil)
    }

    @Test func boxNearTheEdgeStaysInsideTheFrame() throws {
        let tracker = try #require(PatchTracker(frame: scene(at: 0, boat: (0, 0)), centre: (2, 3), width: 48, height: 20))
        #expect(tracker.x == 23.5 && tracker.y == 9.5)
    }

    @Test func fastEnoughForEveryFrame() throws {
        let frames = (0..<30).map { scene(at: Double($0) / 30, boat: (100 + 3 * Double($0), 120)) }
        var tracker = try #require(PatchTracker(frame: frames[0], centre: centre((100, 120)), width: 96, height: 40))
        let start = Date.now
        for f in frames.dropFirst() { tracker.follow(f) }
        let perFrame = Date.now.timeIntervalSince(start) / 29
        // Generous: debug builds are several times slower than the app.
        #expect(perFrame < 0.03, "\(perFrame * 1000) ms a frame")
    }
}
