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

@Suite struct MountAlignmentCaptureTests {
    @Test func axesAlreadyInSkyCoordinates() throws {
        let sky = Horizontal(azimuth: 123.4, altitude: 37.5)
        let model = try #require(AlignmentModel.fromMount(sky: sky, axes: AxisPosition(primary: 123.4, secondary: 37.5)))
        #expect(model.azimuthSense == 1)
        #expect(abs(wrap180(model.yaw)) < 1e-6 && abs(model.altitudeOffset) < 1e-6)
    }

    @Test func offsetAxesMapBackToTheSky() throws {
        // Axis zero 3° off north and 0.5° off the horizon; another direction still maps correctly.
        let sky = Horizontal(azimuth: 200, altitude: 40)
        let axes = AxisPosition(primary: wrap180(200 + 3), secondary: 40.5)
        let model = try #require(AlignmentModel.fromMount(sky: sky, axes: axes))
        let back = model.sky(for: AxisPosition(primary: wrap180(90 + 3), secondary: 20.5))
        #expect(abs(wrap180(back.azimuth - 90)) < 1e-6 && abs(back.altitude - 20) < 1e-6)
    }

    @Test func reversedAzimuthAxis() throws {
        let sky = Horizontal(azimuth: 60, altitude: 30)
        let model = try #require(AlignmentModel.fromMount(sky: sky, axes: AxisPosition(primary: -60, secondary: 30)))
        #expect(model.azimuthSense == -1)
        let back = model.sky(for: AxisPosition(primary: -100, secondary: 50))
        #expect(abs(wrap180(back.azimuth - 100)) < 1e-6 && abs(back.altitude - 50) < 1e-6)
    }
}

@Suite struct AxisSlewTests {
    @Test func shortMoveIsOneSlew() {
        #expect(AxisSlew.next(current: 10, goal: 100) == .slew(raw: 100, unwrapped: 100))
        // On a later turn: the raw target drops the whole turns.
        #expect(AxisSlew.next(current: 370, goal: 400) == .slew(raw: 40, unwrapped: 400))
    }

    @Test func longMoveIsSplit() {
        #expect(AxisSlew.next(current: -170, goal: 170) == .slew(raw: 0, unwrapped: 0))
    }

    @Test func stopsShortOfTheWrapThenCrossesIt() {
        // 150 → 200 passes raw +180: first to 179, then across under rate control, then on.
        #expect(AxisSlew.next(current: 150, goal: 200) == .slew(raw: 179, unwrapped: 179))
        #expect(AxisSlew.next(current: 179, goal: 200) == .crossWrap(direction: 1))
        #expect(AxisSlew.next(current: 182, goal: 200) == .slew(raw: -160, unwrapped: 200))
        // And the other way.
        #expect(AxisSlew.next(current: -150, goal: -200) == .slew(raw: -179, unwrapped: -179))
        #expect(AxisSlew.next(current: -179, goal: -200) == .crossWrap(direction: -1))
    }
}

@Suite struct AltitudeSenseTests {
    /// A HAZ-like mount whose altitude axis counts down as the tube rises.
    func reversed(_ sky: Horizontal) -> AxisPosition { AxisPosition(primary: wrap180(sky.azimuth + 2), secondary: 90 - sky.altitude) }

    @Test func fitFindsAReversedAltitudeAxis() throws {
        let skies = [Horizontal(azimuth: 30, altitude: 20), Horizontal(azimuth: 150, altitude: 60), Horizontal(azimuth: 260, altitude: 35)]
        let points = skies.map { AlignmentPoint(targetName: "", date: .now, sky: $0, axes: reversed($0)) }
        let model = try #require(AlignmentModel.fit(points))
        #expect(model.altitudeSense == -1 && model.azimuthSense == 1)
        #expect(model.rms(points) < 1e-6)
        // Low on the horizon really is low, not straight up.
        let horizon = model.sky(for: reversed(Horizontal(azimuth: 200, altitude: 0)))
        #expect(abs(horizon.altitude) < 1e-6)
    }

    @Test func sensesFromTwoComparisons() {
        let a = AlignmentPoint(targetName: "", date: .now, sky: Horizontal(azimuth: 100, altitude: 30),
                               axes: AxisPosition(primary: 100, secondary: 60))
        let b = AlignmentPoint(targetName: "", date: .now, sky: Horizontal(azimuth: 100, altitude: 35),
                               axes: AxisPosition(primary: 100, secondary: 55))
        let senses = AlignmentModel.axisSenses(a, b)
        #expect(senses.altitude == -1 && senses.azimuth == nil)
    }

    @Test func oldSavedModelsStillDecode() throws {
        let json = #"{"yaw":1.5,"tiltNorth":0,"tiltEast":0,"altitudeOffset":-0.2,"azimuthSense":1}"#
        let model = try JSONDecoder().decode(AlignmentModel.self, from: Data(json.utf8))
        #expect(model.altitudeSense == 1 && model.yaw == 1.5)
    }
}

@Suite struct IOptronSpecialModeTests {
    // Measured: the Moon at az 121.92°, alt 51.46° read P0 −58.77°, P1 39.04° (centring within about half a degree).
    let model = AlignmentModel.iOptronSpecialMode

    @Test func matchesTheMoonReading() {
        let sky = model.sky(for: AxisPosition(primary: -58.77, secondary: 39.04))
        #expect(abs(wrap180(sky.azimuth - 121.92)) < 1 && abs(sky.altitude - 51.46) < 1)
        let axes = model.axes(for: Horizontal(azimuth: 121.92, altitude: 51.46))
        #expect(abs(axes.primary - -58.08) < 1e-6 && abs(axes.secondary - 38.54) < 1e-6)
    }

    @Test func horizonIsNinetyDegreesFromVertical() {
        #expect(abs(model.axes(for: Horizontal(azimuth: 180, altitude: 0)).secondary - 90) < 1e-6)
        #expect(abs(model.axes(for: Horizontal(azimuth: 180, altitude: 90)).secondary) < 1e-6)
        #expect(abs(model.axes(for: Horizontal(azimuth: 180, altitude: 10)).primary) < 1e-6)
    }
}
