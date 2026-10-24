import Foundation
import Testing
@testable import SkyKit

@Suite struct TopocentricTests {
    let observer = Observer(latitude: 40, longitude: -75, refraction: false)

    /// Converting topocentric RA/Dec back to alt-az must land where `look` says.
    func altAz(ra: Double, dec: Double, _ time: AstroTime) -> Horizontal {
        let local = Mat3.rotZ(-time.gast) * Vec3.unit(longitude: ra, latitude: dec)
        return observer.horizontal(ofEarthFixed: observer.position + 1e9 * local)
    }

    @Test func roundTripsForMoonAndStar() throws {
        let time = AstroTime(Date(timeIntervalSince1970: 1_792_800_000))
        for object in [SkyObject.body(.moon), .star(BrightStars.all[0]), .body(.jupiter)] {
            let (ra, dec) = try observer.topocentricRADec(of: object.target, at: time)
            let expected = try observer.look(at: object.target, time)
            let got = altAz(ra: ra, dec: dec, time)
            #expect(angularSeparation(got.unitVector, expected.unitVector) < 1e-6)
        }
    }

    @Test func moonParallaxIsUpToADegree() throws {
        var maxShift = 0.0
        for hours in stride(from: 0.0, to: 48, by: 1) {
            let time = AstroTime(Date(timeIntervalSince1970: 1_792_800_000 + hours * 3600))
            let geo = SolarSystemBody.moon.raDec(time)
            let topo = try observer.topocentricRADec(of: SolarSystemBody.moon, at: time)
            maxShift = max(maxShift, angularSeparation(Vec3.unit(longitude: geo.ra, latitude: geo.dec),
                                                       Vec3.unit(longitude: topo.ra, latitude: topo.dec)))
        }
        #expect(maxShift > 0.5 && maxShift < 1.05)
    }
}

@Suite struct SkyObjectTests {
    @Test func idsAndPassiveTracking() throws {
        let iss = TLEParser.parse(issTLE)[0]
        #expect(SkyObject.satellite(iss).id == "sat:25544")
        #expect(SkyObject.body(.moon).id == "body:moon")
        #expect(SkyObject.body(.moon).passiveTracking == .lunar)
        #expect(SkyObject.body(.sun).passiveTracking == .solar)
        #expect(SkyObject.body(.mars).passiveTracking == .sidereal)
        #expect(SkyObject.satellite(iss).passiveTracking == nil)
    }

    @Test func recognisesGeostationary() throws {
        let geo = try SatelliteTarget(name: "GEO",
                                      line1: "1 28884U 05041A   08264.51782528  .00000100  00000-0  00000+0 0  9998",
                                      line2: "2 28884   0.0500  90.0000 0002000 270.0000  90.0000  1.00270000 11111")
        #expect(geo.isGeostationary)
        #expect(SkyObject.satellite(geo).passiveTracking == .holdPosition)
    }
}

@Suite struct StepTrackingTests {
    @Test func routeCrossing() {
        // Stop due north.
        #expect(StepTracking.shorterRouteCrossesStop(from: 350, to: 10, stop: 0))
        #expect(StepTracking.shorterRouteCrossesStop(from: 10, to: 350, stop: 0))
        #expect(!StepTracking.shorterRouteCrossesStop(from: 10, to: 60, stop: 0))
        #expect(!StepTracking.shorterRouteCrossesStop(from: 200, to: 160, stop: 0))
        // The margin widens the stop.
        #expect(StepTracking.shorterRouteCrossesStop(from: 20, to: 7, stop: 0, margin: 10))
        #expect(!StepTracking.shorterRouteCrossesStop(from: 20, to: 12, stop: 0, margin: 10))
    }

    @Test func aimsAhead() throws {
        let sat = TLEParser.parse(issTLE)[0]
        let observer = Observer(latitude: 40, longitude: -75)
        let now = sat.epoch + 3600
        let aimed = try StepTracking.aim(at: sat, observer: observer, now: now, lead: 1.5)
        let later = try observer.look(at: sat, AstroTime(now + 1.5))
        #expect(aimed == later)
        #expect(StepTracking.defaultLead(interval: 2) == 1.5)
    }
}

@Suite struct SmoothTrackingTests {
    @Test func planInterpolates() throws {
        let plan = try #require(MountPlanner().plan(lowPass(startAzimuth: 120)))
        let t0 = plan.samples[10].date
        let mid = try #require(plan.target(at: t0 + 0.5))
        let a = plan.samples[10].axes, b = plan.samples[11].axes
        #expect(abs(mid.axes.primary - (a.primary + b.primary) / 2) < 1e-9)
        #expect(abs(mid.primaryRate - (b.primary - a.primary)) < 1e-9)
        #expect(plan.target(at: t0 - 3600) == nil)
    }

    @Test func controllerFeedsForwardAndCorrects() {
        let c = RateController(limits: MountLimits())
        let on = c.rates(desired: AxisPosition(primary: 10, secondary: 20), primaryRate: 1, secondaryRate: -0.5,
                         current: AxisPosition(primary: 10, secondary: 20))
        #expect(on.primary == 1 && on.secondary == -0.5)
        let behind = c.rates(desired: AxisPosition(primary: 10, secondary: 20), primaryRate: 1, secondaryRate: 0,
                             current: AxisPosition(primary: 9.9, secondary: 20.1))
        #expect(behind.primary > 1 && behind.secondary < 0)
        // Big errors are capped, then clamped to the axis limit.
        let far = c.rates(desired: AxisPosition(primary: 100, secondary: 0), primaryRate: 5, secondaryRate: 0,
                          current: AxisPosition(primary: 0, secondary: 0))
        #expect(far.primary == 6)
    }

    @Test func unwrapperFollowsTurnsAndStartsInsideCableRange() {
        var limits = MountLimits()
        limits.cableStopAzimuth = 0
        var u = AxisUnwrapper(raw: -90, model: AlignmentModel(), limits: limits)
        #expect(u.unwrapped == 270)
        #expect(u.update(raw: -170) == 190)
        #expect(u.update(raw: 175) == 175)   // crossed ±180 going backwards: −15°
        var v = AxisUnwrapper(raw: 170, model: AlignmentModel(), limits: limits)
        #expect(v.update(raw: -170) == 190)
    }
}
