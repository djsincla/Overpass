import Foundation
import Testing
@testable import SkyKit

@Suite struct SatelliteStatusTests {
    let iss = TLEParser.parse(issTLE)[0]
    let observer = Observer(latitude: 40, longitude: -75)

    func passes(days: Double = 2) throws -> [SatellitePass] {
        try PassPredictor(observer: observer).passes(of: iss, from: iss.epoch, to: iss.epoch + days * 86_400).filter { !$0.truncated }
    }

    @Test func speedsAndHeightAreTheISSs() throws {
        let state = try SatelliteState(iss, observer: observer, at: iss.epoch + 3600)
        #expect(abs(state.orbitalSpeed - 7.66) < 0.05)
        #expect((6.9...7.5).contains(state.groundSpeed))
        #expect((330...380).contains(state.subpoint.height))
    }

    @Test func rangeRateChangesSignAtCulmination() throws {
        let pass = try #require(try passes().first)
        let rising = try SatelliteState(iss, observer: observer, at: pass.culmination.date - 60)
        let setting = try SatelliteState(iss, observer: observer, at: pass.culmination.date + 60)
        #expect(rising.rangeRate < 0 && setting.rangeRate > 0)
        #expect(abs(rising.rangeRate) < 7.7 && abs(setting.rangeRate) < 7.7)
        let peak = try SatelliteState(iss, observer: observer, at: pass.culmination.date)
        let sample = try #require(pass.track.min { abs($0.date.timeIntervalSince(pass.culmination.date)) < abs($1.date.timeIntervalSince(pass.culmination.date)) })
        let axisRate = hypot(sample.azimuthRate * cos(sample.position.altitude.radians), sample.altitudeRate)
        #expect(abs(peak.angularSpeed - axisRate) < 0.02)
    }

    @Test func maidenheadLocators() {
        #expect(Maidenhead.locator(Geodetic(latitude: 41.714775, longitude: -72.727260)) == "FN31pr")
        #expect(Maidenhead.locator(Geodetic(latitude: -33.8688, longitude: 151.2093)) == "QF56od")
        #expect(Maidenhead.locator(Geodetic(latitude: 90, longitude: 180)) == "RR99xx")
    }

    @Test func dopplerShift() {
        let shifted = Doppler.downlink(437e6, rangeRate: -7)
        #expect(abs((shifted - 437e6) - 10_204) < 1)
        // The satellite hears what was sent, shifted back.
        let sent = Doppler.uplink(145.99e6, rangeRate: 5)
        #expect(abs(sent * (1 - 5 / Doppler.speedOfLight) - 145.99e6) < 1e-6)
    }

    @Test func shadowCrossingsMatchSunlitFlips() throws {
        let pass = try #require(try passes(days: 10).first { p in zip(p.track, p.track.dropFirst()).contains { $0.sunlit != $1.sunlit } })
        let crossings = pass.shadowCrossings(of: iss)
        #expect(!crossings.isEmpty)
        for c in crossings {
            let before = try iss.isSunlit(at: AstroTime(c.date - 0.05)), after = try iss.isSunlit(at: AstroTime(c.date + 0.05))
            #expect(before == c.entersShadow && after == !c.entersShadow)
        }
    }

    @Test func exposureMath() throws {
        let optics = CameraOptics(focalLength: 1000, pixelSize: 3.76)
        #expect(abs(optics.imageScale - 0.7756) < 0.0001)
        let exposure = try #require(optics.exposureForOnePixel(rate: 1))
        #expect(abs(exposure - 0.000_215) < 0.000_001)
        // The ISS (109 m) at 400 km: about 56″.
        #expect(abs(optics.pixels(size: 109, range: 400) * optics.imageScale - 56.2) < 0.2)
    }

    @Test func parsesSatNOGSTransmitters() throws {
        let json = """
        [{"uuid":"a","description":"Mode V/U FM","alive":true,"type":"Transceiver","uplink_low":145990000,"uplink_high":null,
          "downlink_low":437800000,"downlink_high":null,"mode":"FM","invert":false,"baud":null,"status":"active"},
         {"uuid":"b","description":"Old","alive":false,"type":"Transmitter","uplink_low":null,"downlink_low":145800000,
          "mode":"SSTV","invert":false,"baud":null,"status":"inactive"}]
        """
        let list = SatNOGS.sorted(try SatNOGS.parseTransmitters(Data(json.utf8)))
        #expect(list.map(\.id) == ["a", "b"])
        #expect(list[0].uplink == 145_990_000 && list[0].downlink == 437_800_000 && list[0].isActive)
        #expect(!list[1].isActive && list[1].uplink == nil)
    }
}
