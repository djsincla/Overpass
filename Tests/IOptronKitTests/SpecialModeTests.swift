import Testing
@testable import IOptronKit

@Suite struct CommandEncodingTests {
    @Test func documentExampleSpeed() {
        // From the spec: 5°/s negative on the primary axis.
        #expect(Command.speed(.primary, centiarcsecPerSecond: Centiarcsec.fromDegrees(-5)).wire == ":M0-1800000#")
    }

    @Test func combinedSpeedSkipsAxis() {
        #expect(Command.speeds(primary: nil, secondary: -12345).wire == ":M2*0000000-0012345#")
        #expect(Command.speeds(primary: 1, secondary: 0).wire == ":M2+0000001+0000000#")
    }

    @Test func combinedSpeedSignPositions() {
        // The spec checks characters 4 and 12 (1-based) for the signs.
        let wire = Array(Command.speeds(primary: 5, secondary: -5).wire)
        #expect(wire[3] == "+")
        #expect(wire[11] == "-")
    }

    @Test func positionsAndClamping() {
        #expect(Command.slew(.secondary, centiarcsec: Centiarcsec.fromDegrees(45)).wire == ":T1+016200000#")
        #expect(Command.sync(.primary, centiarcsec: -1).wire == ":S0-000000001#")
        #expect(Command.slew(.primary, centiarcsec: 999_999_999).wire == ":T0+064800000#")
        #expect(Command.speed(.secondary, centiarcsecPerSecond: -99_999_999).wire == ":M1-9999999#")
    }

    @Test func simpleCommands() {
        #expect(Command.mountInfo.wire == ":MountInfo#")
        #expect(Command.toggleMode.wire == ":ZZZ#")
        #expect(Command.positions.wire == ":P2#")
        #expect(Command.actualSpeed(.primary).wire == ":Q0#")
    }
}

@Suite struct ReplyParsingTests {
    @Test func singlePosition() throws {
        #expect(try Reply.signedFields("-032400000#", digits: 9) == [-32_400_000])
    }

    @Test func combinedPositions() throws {
        #expect(try Reply.signedFields("+016200000-000000123#", digits: 9) == [16_200_000, -123])
    }

    @Test func speed() throws {
        #expect(try Reply.signedFields("+1800000#", digits: 7) == [1_800_000])
    }

    @Test func malformed() {
        #expect(throws: ReplyError.self) { try Reply.signedFields("+0162#", digits: 9) }
        #expect(throws: ReplyError.self) { try Reply.signedFields("+016200000", digits: 9) }
        #expect(throws: ReplyError.self) { try Reply.signedFields("x016200000#", digits: 9) }
        #expect(throws: ReplyError.self) { try Reply.ack("0") }
    }
}

@Suite struct IdentityTests {
    @Test func haz46() {
        #expect(MountIdentity(code: "0052") == MountIdentity(code: "0052"))
        #expect(MountIdentity(code: "0052").model == .haz46)
        #expect(!MountIdentity(code: "0052").isSpecialMode)
        #expect(MountIdentity(code: "8052").model == .haz46)
        #expect(MountIdentity(code: "8052").isSpecialMode)
    }

    @Test func otherModels() {
        #expect(MountIdentity(code: "5035").model == .azMountPro)
        #expect(MountIdentity(code: "9035").model == .azMountPro)
        #expect(MountIdentity(code: "9035").isSpecialMode)
        #expect(MountIdentity(code: "0035").model == .haz31)
        #expect(MountIdentity(code: "8034").model == .hae29)
        #expect(MountIdentity(code: "8051").model == .hae43)
        #expect(!MountIdentity(code: "8051").model.supportsCombinedCommands)
        #expect(MountIdentity(code: "0099").model == .unknown("0099"))
    }
}

/// Replays canned replies and records what was written.
final class ScriptedTransport: MountTransport, @unchecked Sendable {
    var replies: [String]
    var written: [String] = []

    init(replies: [String]) { self.replies = replies }

    func write(_ text: String) async throws { written.append(text) }
    /// A reply of "<timeout>" stands for the mount not answering.
    func read(count: Int) async throws -> String { try next() }
    func read(until terminator: Character) async throws -> String { try next() }

    private func next() throws -> String {
        let reply = replies.removeFirst()
        if reply == "<timeout>" { throw TransportError.timedOut }
        return reply
    }
}

@Suite struct MountClientTests {
    @Test func entersSpecialModeOnHAZ46() async throws {
        let transport = ScriptedTransport(replies: ["0052", "8052"])
        let identity = try await MountClient(transport: transport).enterSpecialMode()
        #expect(identity.model == .haz46 && identity.isSpecialMode)
        #expect(transport.written == [":MountInfo#", ":ZZZ#", ":MountInfo#"])
    }

    @Test func waitsForTheModeSwitch() async throws {
        // Silent while switching, then still Normal once, then Special: one toggle, three asks.
        let transport = ScriptedTransport(replies: ["0052", "<timeout>", "0052", "8052"])
        let identity = try await MountClient(transport: transport, modeSwitchSettle: .zero).enterSpecialMode()
        #expect(identity.isSpecialMode)
        #expect(transport.written == [":MountInfo#", ":ZZZ#", ":MountInfo#", ":MountInfo#", ":MountInfo#"])
    }

    @Test func givesUpIfTheModeNeverChanges() async throws {
        let transport = ScriptedTransport(replies: ["0052"] + Array(repeating: "0052", count: 5))
        await #expect(throws: MountClientError.modeDidNotChange) {
            try await MountClient(transport: transport, modeSwitchSettle: .zero).enterSpecialMode()
        }
        #expect(transport.written.filter { $0 == ":ZZZ#" }.count == 1)
    }

    @Test func doesNotToggleWhenAlreadySpecial() async throws {
        let transport = ScriptedTransport(replies: ["8052"])
        _ = try await MountClient(transport: transport).enterSpecialMode()
        #expect(transport.written == [":MountInfo#"])
    }

    @Test func haz46UsesCombinedCommands() async throws {
        let transport = ScriptedTransport(replies: ["8052", "1", "+016200000-000360000#"])
        let client = MountClient(transport: transport)
        _ = try await client.identify()
        try await client.setSpeeds(primary: 1, secondary: -0.5)
        let pos = try await client.positions()
        #expect(transport.written == [":MountInfo#", ":M2+0360000-0180000#", ":P2#"])
        #expect(pos.primary == 45 && pos.secondary == -1)
    }

    @Test func haeUsesPerAxisCommands() async throws {
        let transport = ScriptedTransport(replies: ["8050", "1", "1", "+000000100#", "-000000200#"])
        let client = MountClient(transport: transport)
        _ = try await client.identify()
        try await client.setSpeeds(primary: 0, secondary: 0)
        _ = try await client.positions()
        #expect(transport.written == [":MountInfo#", ":M0+0000000#", ":M1+0000000#", ":P0#", ":P1#"])
    }

    @Test func exitStopsBeforeToggling() async throws {
        let transport = ScriptedTransport(replies: ["8052", "1", "1", "0052"])
        let identity = try await MountClient(transport: transport).exitSpecialMode()
        #expect(!identity.isSpecialMode)
        #expect(transport.written == [":MountInfo#", ":M0+0000000#", ":M1+0000000#", ":ZZZ#", ":MountInfo#"])
    }
}
