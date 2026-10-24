import Foundation
import Testing
@testable import IOptronKit

/// Answers each command with its own text after a pause, and logs the order of events,
/// so any overlap between exchanges shows up as an unpaired write.
actor EchoTransport: MountTransport {
    var log: [String] = []
    private var pending: [String] = []

    func write(_ text: String) async throws {
        log.append("w\(text)")
        pending.append(text)
        try await Task.sleep(for: .milliseconds(5))
    }

    func read(count: Int) async throws -> String {
        try await Task.sleep(for: .milliseconds(5))
        let reply = pending.removeFirst()
        log.append("r\(reply)")
        return "1"
    }

    func read(until terminator: Character) async throws -> String {
        try await Task.sleep(for: .milliseconds(5))
        let reply = pending.removeFirst()
        log.append("r\(reply)")
        return "+000000000#"
    }
}

@Test func concurrentCallsNeverInterleave() async throws {
    let transport = EchoTransport()
    let client = MountClient(transport: transport)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for i in 0..<10 {
            group.addTask { try await client.setSpeeds(primary: Double(i), secondary: 0) }
            group.addTask { _ = try await client.positions() }
        }
        try await group.waitForAll()
    }
    let log = await transport.log
    // Every write is immediately followed by the read of its own reply.
    var unpaired = 0
    for pair in stride(from: 0, to: log.count, by: 2) {
        let written: String = String(log[pair].dropFirst())
        let answered: String = String(log[pair + 1].dropFirst())
        if written != answered { unpaired += 1 }
    }
    #expect(unpaired == 0)
    // setSpeeds on an unidentified mount sends M0 and M1; positions sends P0 and P1.
    #expect(log.count == 80)
}
