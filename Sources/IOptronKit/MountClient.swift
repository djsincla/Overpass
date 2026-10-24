/// A byte channel to the mount (TCP over WiFi, or serial on macOS).
public protocol MountTransport: Sendable {
    func write(_ text: String) async throws
    /// Reads exactly `count` bytes.
    func read(count: Int) async throws -> String
    /// Reads up to and including `terminator`.
    func read(until terminator: Character) async throws -> String
}

/// Serialises Special Mode commands over a transport. One command is in flight at a time,
/// because replies carry no command identifier.
public actor MountClient {
    private let transport: MountTransport
    public private(set) var identity: MountIdentity?

    public init(transport: MountTransport) {
        self.transport = transport
    }

    private let serial = SerialExecutor()

    @discardableResult
    func send(_ command: Command) async throws -> String {
        let transport = transport
        return try await serial.run {
            try await transport.write(command.wire)
            switch command.expectedReply {
            case .none: return ""
            case .fixed(let count): return try await transport.read(count: count)
            case .terminated: return try await transport.read(until: "#")
            }
        }
    }

    public func identify() async throws -> MountIdentity {
        let identity = MountIdentity(code: try await send(.mountInfo))
        self.identity = identity
        return identity
    }

    /// Puts the mount in Special Mode if it isn't already. The mode survives power cycles,
    /// so callers should pair this with `exitSpecialMode()`.
    public func enterSpecialMode() async throws -> MountIdentity {
        let current = try await identify()
        if current.isSpecialMode { return current }
        try await send(.toggleMode)
        return try await identify()
    }

    public func exitSpecialMode() async throws -> MountIdentity {
        let current = try await identify()
        guard current.isSpecialMode else { return current }
        try await stop()
        try await send(.toggleMode)
        return try await identify()
    }

    /// Current (primary, secondary) positions in degrees.
    public func positions() async throws -> (primary: Double, secondary: Double) {
        let values: [Int]
        if identity?.model.supportsCombinedCommands ?? false {
            values = try Reply.signedFields(try await send(.positions), digits: 9)
        } else {
            values = try Reply.signedFields(try await send(.position(.primary)), digits: 9)
                + Reply.signedFields(try await send(.position(.secondary)), digits: 9)
        }
        guard values.count == 2 else { throw ReplyError.malformed(values.description) }
        return (Centiarcsec.toDegrees(values[0]), Centiarcsec.toDegrees(values[1]))
    }

    /// Sets both axis speeds in degrees per second.
    public func setSpeeds(primary: Double, secondary: Double) async throws {
        let p = Centiarcsec.fromDegrees(primary)
        let s = Centiarcsec.fromDegrees(secondary)
        if identity?.model.supportsCombinedCommands ?? false {
            try Reply.ack(try await send(.speeds(primary: p, secondary: s)))
        } else {
            try Reply.ack(try await send(.speed(.primary, centiarcsecPerSecond: p)))
            try Reply.ack(try await send(.speed(.secondary, centiarcsecPerSecond: s)))
        }
    }

    /// Special Mode has no stop command; zero speed on both axes stops the mount.
    public func stop() async throws {
        try Reply.ack(try await send(.speed(.primary, centiarcsecPerSecond: 0)))
        try Reply.ack(try await send(.speed(.secondary, centiarcsecPerSecond: 0)))
    }

    public func slew(primary: Double, secondary: Double) async throws {
        try Reply.ack(try await send(.slew(.primary, centiarcsec: Centiarcsec.fromDegrees(primary))))
        try Reply.ack(try await send(.slew(.secondary, centiarcsec: Centiarcsec.fromDegrees(secondary))))
    }

    /// Only use while the axes are stationary.
    public func sync(primary: Double, secondary: Double) async throws {
        try Reply.ack(try await send(.sync(.primary, centiarcsec: Centiarcsec.fromDegrees(primary))))
        try Reply.ack(try await send(.sync(.secondary, centiarcsec: Centiarcsec.fromDegrees(secondary))))
    }
}
