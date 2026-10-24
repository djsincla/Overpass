import Foundation
import Testing
@testable import SkyKit

@Suite struct MagnitudeTests {
    @Test func venusMeeus41a() throws {
        // 1992 Dec 20.0 TD: r = 0.724604, Δ = 0.910947, i = 72.96°, m = −4.2.
        let time = AstroTime(jdTT: 2_448_976.5)
        let g = try #require(SolarSystemBody.venus.planetGeometry(time))
        #expect(abs(g.r - 0.724604) < 0.002 && abs(g.delta - 0.910947) < 0.002)
        #expect(abs(g.phase - 72.96) < 0.3)
        #expect(abs(SolarSystemBody.venus.apparentMagnitude(time) - -4.2) < 0.1)
    }

    @Test func planetsStayInTheirUsualRanges() {
        // Over a few years every planet should stay within its known brightness range.
        for day in stride(from: 0.0, to: 3 * 365, by: 13) {
            let time = AstroTime(jdTT: 2_461_000.5 + day)
            #expect((-4.9 ... -3.7).contains(SolarSystemBody.venus.apparentMagnitude(time)))
            #expect((-3.0 ... 2.0).contains(SolarSystemBody.mars.apparentMagnitude(time)))
            #expect((-3.0 ... -1.5).contains(SolarSystemBody.jupiter.apparentMagnitude(time)))
            #expect((5.3 ... 6.1).contains(SolarSystemBody.uranus.apparentMagnitude(time)))
            #expect((7.6 ... 8.0).contains(SolarSystemBody.neptune.apparentMagnitude(time)))
        }
    }

    @Test func fullMoonIsAboutMinus12_7() {
        // Scan a month for the brightest moment.
        let brightest = stride(from: 0.0, to: 30, by: 0.25)
            .map { SolarSystemBody.moon.apparentMagnitude(AstroTime(jdTT: 2_461_000.5 + $0)) }.min()!
        // −12.73 needs a 0° phase angle; the Moon's orbital tilt usually leaves a few degrees,
        // so real full Moons come out about −12.5 to −12.7.
        #expect((-12.74 ... -12.45).contains(brightest))
    }

    @Test func satellitePhaseLaw() throws {
        let sat = TLEParser.parse(issTLE)[0]
        let observer = Observer(latitude: 40, longitude: -75)
        let pass = try #require(try PassPredictor(observer: observer).passes(of: sat, from: sat.epoch, to: sat.epoch + 86_400)
            .first { pass in pass.track.contains { $0.sunlit } })
        let sample = try #require(pass.track.first { $0.sunlit })
        let m = try #require(try sat.apparentMagnitude(standard: -1.8, observer: observer, at: AstroTime(sample.date)))
        // Farther than 1,000 km away near the horizon, so dimmer than the standard magnitude.
        #expect(sample.position.range > 1000 && m > -1.8)
        // In the Earth's shadow there's no magnitude at all.
        if let dark = pass.track.first(where: { !$0.sunlit }) {
            #expect(try sat.apparentMagnitude(standard: -1.8, observer: observer, at: AstroTime(dark.date)) == nil)
        }
    }

    @Test func starsUseCatalogue() {
        let vega = BrightStars.all.first { $0.name == "Vega" }!
        #expect(SkyObject.star(vega).apparentMagnitude(observer: Observer(latitude: 0, longitude: 0), at: AstroTime(.now)) == 0.03)
    }
}
