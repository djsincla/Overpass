import Foundation
import Testing
@testable import SkyKit

@Suite struct VisibilityTests {
    let observer = Observer(latitude: 40, longitude: -75, refraction: false)
    let date = Date(timeIntervalSince1970: 1_792_800_000)

    @Test func starPeaksAtMeridianAltitude() throws {
        // A star culminates at 90° − |latitude − declination| (proper motion and precession aside).
        let vega = BrightStars.all.first { $0.name == "Vega" }!
        let v = try observer.visibility(of: vega, at: date)
        let dec = vega.equatorialOfDate(AstroTime(date)).spherical.latitude
        #expect(abs(try #require(v.maxAltitude) - (90 - abs(40 - dec))) < 0.05)
    }

    @Test func riseAndSetBracketThePeak() throws {
        let v = try observer.visibility(of: SolarSystemBody.jupiter, at: date)
        let rise = try #require(v.rise), set = try #require(v.set), peak = try #require(v.peak)
        #expect(rise < peak && peak < set)
        #expect(abs(try observer.look(at: SolarSystemBody.jupiter, AstroTime(rise)).altitude) < 0.05)
        #expect(abs(try observer.look(at: SolarSystemBody.jupiter, AstroTime(set)).altitude) < 0.05)
        // Up roughly half a day.
        #expect((6 * 3600...18 * 3600).contains(set.timeIntervalSince(rise)))
    }

    @Test func trendMatchesMotion() throws {
        let v = try observer.visibility(of: SolarSystemBody.moon, at: date)
        let later = try observer.look(at: SolarSystemBody.moon, AstroTime(date + 60)).altitude
        #expect((later > v.altitude) == (v.trend == .rising))
    }

    @Test func circumpolarStarHasNoRiseOrSet() throws {
        let polaris = BrightStars.all.first { $0.name == "Polaris" }!
        let v = try observer.visibility(of: polaris, at: date)
        #expect(v.isUp && v.rise == nil && v.set == nil)
        #expect(abs(try #require(v.maxAltitude) - 40.7) < 0.3)
    }

    @Test func passStatus() throws {
        let sat = TLEParser.parse(issTLE)[0]
        let pass = try #require(try PassPredictor(observer: observer).passes(of: sat, from: sat.epoch, to: sat.epoch + 86_400).first { !$0.truncated })
        #expect(pass.status(at: pass.start.date + 5)?.trend == .rising)
        #expect(pass.status(at: pass.end.date - 5)?.trend == .setting)
        #expect(pass.status(at: pass.start.date - 60) == nil)
    }
}

@Test func eclipsedFilter() throws {
    let sat = TLEParser.parse(issTLE)[0]
    let passes = try PassPredictor(observer: Observer(latitude: 40, longitude: -75))
        .passes(of: sat, from: sat.epoch, to: sat.epoch + 3 * 86_400)
    var filter = PassFilter()
    filter.minimumMaxAltitude = 0
    filter.excludeEclipsed = true
    let kept = passes.filter(filter.matches)
    #expect(kept.allSatisfy { !$0.isEclipsed })
    // Over three days the ISS has both lit and fully shadowed passes, so the filter does something.
    #expect(passes.contains { $0.isEclipsed })
    #expect(kept.count < passes.count && !kept.isEmpty)
}
