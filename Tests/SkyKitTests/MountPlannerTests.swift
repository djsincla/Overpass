import Foundation
import Testing
@testable import SkyKit

/// A synthetic pass, one sample per second.
func syntheticTrack(_ points: [(az: Double, alt: Double)]) -> [PassSample] {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    return points.enumerated().map { i, p in
        PassSample(date: t0 + Double(i), position: Horizontal(azimuth: normalizedDegrees(p.az), altitude: p.alt),
                   sunlit: true, azimuthRate: 0, altitudeRate: 0)
    }
}

/// A low pass sweeping 120° of azimuth from `startAzimuth`, peaking at 40°.
func lowPass(startAzimuth: Double) -> [PassSample] {
    var points: [(az: Double, alt: Double)] = []
    for i in 0...120 {
        let x = Double(i)
        let altitude: Double = 10 + 30 * sin(x / 120 * Double.pi)
        points.append((az: startAzimuth + x, alt: altitude))
    }
    return syntheticTrack(points)
}

/// Rises in the north-west, passes north, sets in the north-east: crosses azimuth 0.
let northernPass = lowPass(startAzimuth: 300)

/// Straight through the zenith from south-west to north-east.
let zenithPass: [PassSample] = {
    var points: [(az: Double, alt: Double)] = []
    for i in 0...180 {
        let elevation = Double(i)  // sweeps 0…180 along the great circle
        points.append(elevation <= 90 ? (az: 225, alt: elevation) : (az: 45, alt: 180 - elevation))
    }
    return syntheticTrack(points)
}()

@Suite struct MountPlannerTests {
    func planner(overTheTop: Bool) -> MountPlanner {
        var limits = MountLimits()
        limits.cableStopAzimuth = 0
        limits.maximumAltitudeAxis = overTheTop ? 180 : 90
        return MountPlanner(limits: limits)
    }

    func expectWithinLimits(_ plan: MountPlan, _ limits: MountLimits) {
        for (a, b) in zip(plan.samples, plan.samples.dropFirst()) {
            let dt = b.date.timeIntervalSince(a.date)
            #expect(abs(b.axes.primary - a.axes.primary) / dt <= limits.maximumAzimuthRate + 1e-9)
            #expect(abs(b.axes.secondary - a.axes.secondary) / dt <= limits.maximumAltitudeRate + 1e-9)
        }
        let lo = limits.cableStopAzimuth + limits.cableMargin
        for s in plan.samples { #expect((lo...(lo + 360 - 2 * limits.cableMargin)).contains(s.axes.primary)) }
    }

    @Test func cableStopBlocksNormalTracking() {
        #expect(planner(overTheTop: false).plan(northernPass) == nil)
    }

    @Test func overTheTopAvoidsCableStop() throws {
        let p = planner(overTheTop: true)
        let plan = try #require(p.plan(northernPass))
        #expect(plan.orientation == MountPlan.Orientation.overTheTop)
        #expect(plan.secondsOffTarget == 0)
        expectWithinLimits(plan, p.limits)
    }

    @Test func passAwayFromStopStaysNormal() throws {
        let southern = lowPass(startAzimuth: 120)
        let plan = try #require(planner(overTheTop: true).plan(southern))
        #expect(plan.orientation == MountPlan.Orientation.normal)
        #expect(plan.maximumError < 1e-9)
    }

    @Test func zenithPassFlipsAtCulmination() throws {
        let normalOnly = try #require(planner(overTheTop: false).plan(zenithPass))
        let p = planner(overTheTop: true)
        let flipped = try #require(p.plan(zenithPass))
        // A 180° azimuth swing at 6°/s takes 30 s, so normal tracking loses the target.
        #expect(normalOnly.secondsOffTarget > 10)
        #expect(flipped.orientation != MountPlan.Orientation.normal)
        #expect(flipped.secondsOffTarget == 0)
        expectWithinLimits(flipped, p.limits)
    }

    @Test func nearZenithIssPassCutsTheCorner() throws {
        let sat = TLEParser.parse(issTLE)[0]
        let passes = try PassPredictor(observer: Observer(latitude: 40, longitude: -75))
            .passes(of: sat, from: sat.epoch, to: sat.epoch + 30 * 86_400)
        let high = try #require(passes.filter { $0.maxAltitude > 83 && !$0.truncated }.first)
        var p = planner(overTheTop: true)
        p.limits.cableStopAzimuth = normalizedDegrees(high.culmination.position.azimuth + 180)
        let plan = try #require(p.plan(high.track))
        expectWithinLimits(plan, p.limits)
        // Keyhole is intrinsic: some time is lost, but only around the top.
        #expect(plan.secondsOffTarget > 0 && plan.secondsOffTarget < 60)
        for s in plan.samples where s.error > p.tolerance {
            #expect(abs(s.date.timeIntervalSince(high.culmination.date)) < 60)
        }
    }

    @Test func filterUsesPlanner() throws {
        let sat = TLEParser.parse(issTLE)[0]
        let passes = try PassPredictor(observer: Observer(latitude: 40, longitude: -75))
            .passes(of: sat, from: sat.epoch, to: sat.epoch + 3 * 86_400)
        var filter = PassFilter()
        filter.minimumMaxAltitude = 0
        filter.mountPlanner = planner(overTheTop: true)
        filter.maximumSecondsOffTarget = 0
        for pass in passes.filter(filter.matches) {
            #expect(filter.mountPlanner!.plan(pass.track)!.secondsOffTarget == 0)
        }
    }
}
