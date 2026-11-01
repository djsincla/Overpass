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

    @Test func parsesTrackingState() async throws {
        // GPS 2, system 1 (tracking), rate 1 (lunar), speed 5, source 1, north.
        let reply = "-43380000" + "45090000" + "211511" + "#"
        let client = NormalModeClient(transport: ScriptedTransport(replies: [reply]))
        let state = try await client.trackingState()
        #expect(state.system == 1)
        #expect(state.rate == 1)
    }

    @Test func parsesSite() async throws {
        // Longitude −120.5°, latitude 35.25° (+90° offset), GPS fix.
        let reply = "-43380000" + "45090000" + "210511" + "#"
        let client = NormalModeClient(transport: ScriptedTransport(replies: [reply]))
        let site = try await client.site()
        #expect(abs(site.longitude + 120.5) < 1e-9)
        #expect(abs(site.latitude - 35.25) < 1e-9)
        #expect(site.hasFix)
    }

    @Test func readsTheFullReport() async throws {
        // GPS fix, stopped, sidereal, speed 5, time from GPS, north; then firmware and the clock.
        let status = "-43380000" + "45090000" + "200531" + "#"
        let transport = ScriptedTransport(replies: [status, "230512xxxxxx#", "221103221104#", "+0000" + "0846720000000" + "#"])
        let report = try await NormalModeClient(transport: transport).report()
        #expect(transport.written == [":GLS#", ":FW1#", ":FW2#", ":GUT#"])
        #expect(report.site.hasFix && report.system == 0 && report.trackingRate == 0)
        #expect(report.moveSpeed == 5 && report.timeSource == 3 && report.northernHemisphere)
        #expect(report.mainBoard == "2023-05-12" && report.handController == nil)
        #expect(report.azimuthBoard == "2022-11-03" && report.altitudeBoard == "2022-11-04")
        #expect(report.utcOffsetMinutes == 0 && report.daylightSaving == false)
        #expect(report.clock == Date(timeIntervalSince1970: 946_728_000 + 846_720_000))
    }

    @Test func reportSurvivesUnansweredExtras() async throws {
        let status = "+00000000" + "32400000" + "010510" + "#"
        let report = try await NormalModeClient(transport: ScriptedTransport(replies: [status, "<timeout>", "12#", "<timeout>"])).report()
        #expect(!report.northernHemisphere && report.timeSource == 1)
        #expect(report.mainBoard == nil && report.clock == nil)
    }

    @Test func maximumSlewSpeedIsClamped() {
        #expect(NormalCommand.setMaximumSlewSpeed(9).wire == ":MSR9#")
        #expect(NormalCommand.setMaximumSlewSpeed(12).wire == ":MSR9#")
        #expect(NormalCommand.setMaximumSlewSpeed(3).wire == ":MSR7#")
    }
}

#if os(macOS)
@Suite struct SerialPortNameTests {
    @Test func recognisesUSBSerialAdapters() {
        for name in ["cu.usbserial-1410", "cu.usbmodem14201", "cu.wchusbserial1420", "cu.SLAB_USBtoUART",
                     "cu.PL2303G-USBtoUART210"] {
            #expect(SerialTransport.isLikelyUSBSerial(name), "\(name)")
        }
        for name in ["cu.Bluetooth-Incoming-Port", "cu.debug-console", "cu.JBLFlip3", "tty.usbserial-1410"] {
            #expect(!SerialTransport.isLikelyUSBSerial(name), "\(name)")
        }
    }
}
#endif
