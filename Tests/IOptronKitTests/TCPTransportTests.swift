import Foundation
import Network
import Testing
@testable import IOptronKit

/// A local TCP server that answers like a HAZ46 in Special Mode, splitting replies into
/// fragments so the transport's buffering is exercised.
final class FakeMountServer: @unchecked Sendable {
    let listener: NWListener
    var port: UInt16 { listener.port!.rawValue }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            Self.serve(connection)
        }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { state in
                if case .ready = state { once.run { c.resume() } }
                if case .failed(let e) = state { once.run { c.resume(throwing: e) } }
            }
            listener.start(queue: .global())
        }
    }

    static func serve(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, done, _ in
            guard let data, !done else { return }
            let command = String(decoding: data, as: UTF8.self)
            let reply: String = switch command {
            case ":MountInfo#": "8052"
            case ":P2#": "+016200000-000360000#"
            default: "1"
            }
            // Send in two pieces to make the client reassemble.
            let bytes = Data(reply.utf8)
            let mid = bytes.count / 2
            connection.send(content: bytes.prefix(mid), completion: .idempotent)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
                connection.send(content: bytes.suffix(from: mid), completion: .idempotent)
                serve(connection)
            }
        }
    }
}

@Suite struct TCPTransportTests {
    @Test func talksToFakeMount() async throws {
        let server = try FakeMountServer()
        try await server.start()
        defer { server.listener.cancel() }

        let transport = TCPTransport(host: "127.0.0.1", port: server.port)
        try await transport.open()
        let client = MountClient(transport: transport)

        let identity = try await client.identify()
        #expect(identity.model == .haz46 && identity.isSpecialMode)
        try await client.setSpeeds(primary: 0.5, secondary: -0.5)
        let position = try await client.positions()
        #expect(position.primary == 45 && position.secondary == -1)
        try await client.stop()
        await transport.close()
    }

    @Test func timesOutWithNoReply() async throws {
        // Accepts the connection but never answers.
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.start(queue: .global()) }
        let server = FakeMountServer.self
        _ = server
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { if case .ready = $0 { once.run { c.resume() } } }
            listener.start(queue: .global())
        }
        defer { listener.cancel() }

        let transport = TCPTransport(host: "127.0.0.1", port: listener.port!.rawValue, timeout: 0.3)
        try await transport.open()
        await #expect(throws: TransportError.timedOut) {
            _ = try await MountClient(transport: transport).identify()
        }
        await transport.close()
    }
}
