import Testing
@testable import SkyKit

@Suite struct CableRouteTests {
    @Test func shortTurnIsOneGoto() throws {
        // Stop at north; 100° → 200° doesn't cross it.
        let legs = try #require(CableRoute.legs(from: Horizontal(azimuth: 100, altitude: 20),
                                                to: Horizontal(azimuth: 200, altitude: 40), stop: 0))
        #expect(legs.count == 1)
        #expect(legs[0].azimuth == 200 && legs[0].altitude == 40)
    }

    @Test func goesTheLongWayRoundTheStop() throws {
        // 350° → 10° is 20° the short way, through the stop at 0°. It must go back round: −340°.
        let legs = try #require(CableRoute.legs(from: Horizontal(azimuth: 350, altitude: 30),
                                                to: Horizontal(azimuth: 10, altitude: 30), stop: 0))
        #expect(legs.count == 2)
        #expect(abs(legs[0].azimuth - 180) < 1e-9)
        #expect(abs(legs[1].azimuth - 10) < 1e-9)
        // Every leg turns the same way (decreasing azimuth) by under 180°, so the mount's
        // shorter way is the intended way.
        var previous = 350.0
        for leg in legs {
            let step = wrap180(leg.azimuth - previous)
            #expect(step < 0 && step > -CableRoute.maximumLeg - 1e-9)
            previous = leg.azimuth
        }
    }

    @Test func stopAnywhere() throws {
        // Stop at 135°: 120° → 150° must turn −330°, never passing 135°.
        let legs = try #require(CableRoute.legs(from: Horizontal(azimuth: 120, altitude: 10),
                                                to: Horizontal(azimuth: 150, altitude: 50), stop: 135))
        #expect(legs.count == 2)
        var previous = 120.0
        for leg in legs {
            #expect(!StepTracking.shorterRouteCrossesStop(from: previous, to: leg.azimuth, stop: 135))
            previous = leg.azimuth
        }
        #expect(legs.last!.altitude == 50)
    }

    @Test func targetInsideTheMarginIsRefused() {
        #expect(CableRoute.legs(from: Horizontal(azimuth: 90, altitude: 10),
                                to: Horizontal(azimuth: 2, altitude: 10), stop: 0, margin: 5) == nil)
        #expect(CableRoute.legs(from: Horizontal(azimuth: 90, altitude: 10),
                                to: Horizontal(azimuth: 357, altitude: 10), stop: 0, margin: 5) == nil)
    }
}
