import Foundation
import Testing
@testable import IOptronKit

@Suite struct NormalCommandTests {
    @Test func encodings() {
        #expect(NormalCommand.setAltitude(centiarcsec: Centiarcsec.fromDegrees(45)).wire == ":Sa+16200000#")
        #expect(NormalCommand.setAltitude(centiarcsec: Centiarcsec.fromDegrees(-2)).wire == ":Sa-00720000#")
        #expect(NormalCommand.setAzimuth(centiarcsec: Centiarcsec.fromDegrees(270)).wire == ":Sz097200000#")
        // Azimuths wrap into [0, 360°).
        #expect(NormalCommand.setAzimuth(centiarcsec: Centiarcsec.fromDegrees(-90)).wire == ":Sz097200000#")
        #expect(NormalCommand.setRightAscension(centiarcsec: Centiarcsec.fromDegrees(101.5)).wire == ":SRA036540000#")
        #expect(NormalCommand.setDeclination(centiarcsec: Centiarcsec.fromDegrees(-16.75)).wire == ":Sd-06030000#")
        #expect(NormalCommand.slewAltAz.wire == ":MSS#")
        #expect(NormalCommand.slewRADec.wire == ":MS1#")
        #expect(NormalCommand.trackingRate(.lunar).wire == ":RT1#")
        #expect(NormalCommand.moveRate(.x64).wire == ":SR5#")
        #expect(NormalCommand.move(.east).wire == ":me#")
        #expect(NormalCommand.setUTC(millisecondsSinceJ2000: 845_000_000_000).wire == ":SUT0845000000000#")
        #expect(NormalCommand.setUTCOffset(minutes: 0).wire == ":SG+000#")
        #expect(NormalCommand.setLongitude(centiarcsec: Centiarcsec.fromDegrees(-75)).wire == ":SLO-27000000#")
        #expect(NormalCommand.setLatitude(centiarcsec: Centiarcsec.fromDegrees(40)).wire == ":SLA+14400000#")
    }

    @Test func moveRates() {
        #expect(abs(NormalCommand.MoveRate.x64.degreesPerSecond! - 0.2674) < 0.001)
        #expect(NormalCommand.MoveRate.max.degreesPerSecond == nil)
    }
}

@Suite struct NormalModeClientTests {
    @Test func readsAltAz() async throws {
        let transport = ScriptedTransport(replies: ["+16200000097200000#"])
        let position = try await NormalModeClient(transport: transport).altAz()
        #expect(position.altitude == 45 && position.azimuth == 270)
    }

    @Test func slewAltAzSequence() async throws {
        let transport = ScriptedTransport(replies: ["1", "1", "1"])
        try await NormalModeClient(transport: transport).slew(altitude: 30, azimuth: 120)
        #expect(transport.written == [":Sa+10800000#", ":Sz043200000#", ":MSS#"])
    }

    @Test func refusedSlewThrows() async {
        let transport = ScriptedTransport(replies: ["1", "1", "0"])
        await #expect(throws: NormalModeError.slewRefused) {
            try await NormalModeClient(transport: transport).slew(altitude: -10, azimuth: 0)
        }
    }

    @Test func passiveSlewSetsRate() async throws {
        let transport = ScriptedTransport(replies: ["1", "1", "1", "1"])
        try await NormalModeClient(transport: transport).slew(rightAscension: 90, declination: 20, rate: .solar)
        #expect(transport.written == [":SRA032400000#", ":Sd+07200000#", ":MS1#", ":RT2#"])
    }

    @Test func moveHasNoReply() async throws {
        let transport = ScriptedTransport(replies: ["1"])
        let client = NormalModeClient(transport: transport)
        try await client.startMove(.north)
        try await client.stopMove(.north)
        #expect(transport.written == [":mn#", ":qD#"])
    }
}

@Suite struct NormalStatusTests {
    @Test func parsesSlewingStatus() async throws {
        // Longitude −75°, latitude 40° (+90° offset), GPS 1, system 2 (slewing), rate 0, speed 5, source 1, north.
        // GPS and system digits differ, so reading the wrong position fails.
        let reply = "-27000000" + "46800000" + "120511" + "#"
        let transport = ScriptedTransport(replies: [reply, reply])
        let client = NormalModeClient(transport: transport)
        #expect(try await client.systemStatus() == 2)
        #expect(try await client.isSlewing())
        #expect(transport.written == [":GLS#", ":GLS#"])
    }

    @Test func maximumSlewSpeedIsClamped() {
        #expect(NormalCommand.setMaximumSlewSpeed(9).wire == ":MSR9#")
        #expect(NormalCommand.setMaximumSlewSpeed(12).wire == ":MSR9#")
        #expect(NormalCommand.setMaximumSlewSpeed(3).wire == ":MSR7#")
    }
}
