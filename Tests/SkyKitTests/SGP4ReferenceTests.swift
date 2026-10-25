import Foundation
import Testing
@testable import SkyKit

/// SatelliteKit against the reference SGP4 (Vallado's, via the `sgp4` package that Skyfield uses).
@Suite struct SGP4ReferenceTests {
    func position(_ sat: SatelliteTarget, minutes: Double) throws -> Vec3 {
        let p = try sat.satellite.position(minsAfterEpoch: minutes)
        return Vec3(p.x, p.y, p.z)
    }

    @Test func readsBStar() throws {
        #expect(try TLEFields(line1: "1 25544U 98067A   26297.20915682  .00007800  00000+0  14938-3 0  9991",
                              line2: "2 25544  51.6335  21.6229 0006884 302.9098  57.1228 15.49030149591752").bstar == 0.14938e-3)
        #expect(try TLEFields(line1: "1 00005U 58002B   00179.78495062  .00000023  00000-0 -11606-4 0  4753",
                              line2: "2 00005  34.2682 348.7242 1859667 331.7664  19.3264 10.82419157413667").bstar == -0.11606e-4)
    }

    /// Vanguard 1, the first case in Vallado's SGP4 verification set.
    @Test func vanguardMatchesReference() throws {
        let sat = try SatelliteTarget(name: "VANGUARD 1",
                                      line1: "1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753",
                                      line2: "2 00005  34.2682 348.7242 1859667 331.7664  19.3264 10.82419157413667")
        let reference: [(Double, Vec3)] = [
            (0, Vec3(7022.465293, -1400.082968, 0.039952)),
            (360, Vec3(-7154.031202, -3783.176825, -3536.194123)),
            (4320, Vec3(-9060.473736, 4658.709525, 813.686732)),
            (10_080, Vec3(-2591.255979, -6292.440774, -4558.812186)),
        ]
        for (minutes, expected) in reference {
            #expect((try position(sat, minutes: minutes) - expected).length < 0.01, "t = \(minutes) min")
        }
    }

    /// A low orbit where drag matters: the ISS, a week on.
    @Test func issWithDragMatchesReference() throws {
        let sat = try SatelliteTarget(name: "ISS (ZARYA)",
                                      line1: "1 25544U 98067A   26297.20915682  .00007800  00000+0  14938-3 0  9991",
                                      line2: "2 25544  51.6335  21.6229 0006884 302.9098  57.1228 15.49030149591752")
        #expect((try position(sat, minutes: 1440) - Vec3(-6509.008846, -1971.879294, -27.109462)).length < 0.01)
        #expect((try position(sat, minutes: 10_080) - Vec3(-6666.862514, 1323.136048, -269.983660)).length < 0.01)
    }
}
