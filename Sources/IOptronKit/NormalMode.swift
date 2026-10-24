import Foundation

/// iOptron RS-232 Command Language V3.10 ("normal mode"): the subset Overpass uses.
/// Available over WiFi and USB. See docs/iOptron-Special-Mode-Protocol.md.
public enum NormalCommand: Equatable, Sendable {
    case mountInfo
    /// Altitude and azimuth as the mount sees them.
    case getAltAz
    case setAltitude(centiarcsec: Int)
    case setAzimuth(centiarcsec: Int)
    /// Slew to the last altitude/azimuth. Replies 1, or 0 if below the altitude limit.
    case slewAltAz
    case setRightAscension(centiarcsec: Int)
    case setDeclination(centiarcsec: Int)
    /// Slew to the last RA/Dec; tracking starts automatically afterwards.
    case slewRADec
    /// Sync to the last coordinates set.
    case sync
    case stop
    case trackingRate(TrackingRate)
    case tracking(Bool)
    /// Arrow-button speed, shared by both axes.
    case moveRate(MoveRate)
    case move(Direction)
    case stopAzimuthMove
    case stopAltitudeMove
    case setUTC(millisecondsSinceJ2000: Int)
    case setUTCOffset(minutes: Int)
    case setDaylightSaving(Bool)
    case setLongitude(centiarcsec: Int)
    case setLatitude(centiarcsec: Int)

    public enum TrackingRate: Int, Sendable { case sidereal = 0, lunar, solar, king, custom }

    /// `:SRn#` speeds in multiples of the sidereal rate (15.04″/s).
    public enum MoveRate: Int, CaseIterable, Sendable {
        case x1 = 1, x2, x8, x16, x64, x128, x256, x512, max

        public var siderealMultiple: Double? {
            switch self {
            case .x1: 1
            case .x2: 2
            case .x8: 8
            case .x16: 16
            case .x64: 64
            case .x128: 128
            case .x256: 256
            case .x512: 512
            case .max: nil
            }
        }

        /// Degrees per second, where known.
        public var degreesPerSecond: Double? { siderealMultiple.map { $0 * 15.041 / 3600 } }
    }

    /// Alt-az mounts: north/south move altitude, east/west move azimuth.
    public enum Direction: Sendable { case north, south, east, west }

    public var wire: String {
        switch self {
        case .mountInfo: ":MountInfo#"
        case .getAltAz: ":GAC#"
        case .setAltitude(let v): ":Sa\(Command.signed(v, digits: 8, range: -32_400_000...32_400_000))#"
        case .setAzimuth(let v): ":Sz\(Self.unsigned(normalized(v), digits: 9))#"
        case .slewAltAz: ":MSS#"
        case .setRightAscension(let v): ":SRA\(Self.unsigned(normalized(v), digits: 9))#"
        case .setDeclination(let v): ":Sd\(Command.signed(v, digits: 8, range: -32_400_000...32_400_000))#"
        case .slewRADec: ":MS1#"
        case .sync: ":CM#"
        case .stop: ":Q#"
        case .trackingRate(let r): ":RT\(r.rawValue)#"
        case .tracking(let on): on ? ":ST1#" : ":ST0#"
        case .moveRate(let r): ":SR\(r.rawValue)#"
        case .move(let d):
            switch d {
            case .north: ":mn#"
            case .south: ":ms#"
            case .east: ":me#"
            case .west: ":mw#"
            }
        case .stopAzimuthMove: ":qR#"
        case .stopAltitudeMove: ":qD#"
        case .setUTC(let ms): ":SUT\(Self.unsigned(ms, digits: 13))#"
        case .setUTCOffset(let m): ":SG\(Command.signed(m, digits: 3, range: -720...780))#"
        case .setDaylightSaving(let on): on ? ":SDS1#" : ":SDS0#"
        case .setLongitude(let v): ":SLO\(Command.signed(v, digits: 8, range: -64_800_000...64_800_000))#"
        case .setLatitude(let v): ":SLA\(Command.signed(v, digits: 8, range: -32_400_000...32_400_000))#"
        }
    }

    public var expectedReply: ReplyFormat {
        switch self {
        case .mountInfo: .fixed(4)
        case .getAltAz: .terminated
        case .move: .none
        default: .fixed(1)
        }
    }

    /// Wraps a full-circle angle into [0, 360°).
    private func normalized(_ v: Int) -> Int {
        let full = 129_600_000
        return ((v % full) + full) % full
    }

    static func unsigned(_ value: Int, digits: Int) -> String {
        let s = String(max(0, value))
        return String(repeating: "0", count: max(0, digits - s.count)) + s
    }
}

public enum NormalModeError: Error, Equatable {
    /// The mount refused a slew: below its altitude limit or past a mechanical limit.
    case slewRefused
    case notNormalMode(String)
}

/// Drives the mount with the normal command language.
public actor NormalModeClient {
    private let transport: MountTransport
    public private(set) var identity: MountIdentity?

    public init(transport: MountTransport) {
        self.transport = transport
    }

    private let serial = SerialExecutor()

    @discardableResult
    func send(_ command: NormalCommand) async throws -> String {
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

    private func ack(_ command: NormalCommand) async throws {
        try Reply.ack(try await send(command))
    }

    public func identify() async throws -> MountIdentity {
        let identity = MountIdentity(code: try await send(.mountInfo))
        self.identity = identity
        return identity
    }

    /// Tells the mount where and when it is, in UTC. Required before alt-az or RA/Dec work.
    public func configure(latitude: Double, longitude: Double, date: Date = .now) async throws {
        try await ack(.setLongitude(centiarcsec: Centiarcsec.fromDegrees(longitude)))
        try await ack(.setLatitude(centiarcsec: Centiarcsec.fromDegrees(latitude)))
        try await ack(.setUTCOffset(minutes: 0))
        try await ack(.setDaylightSaving(false))
        let j2000 = Date(timeIntervalSince1970: 946_728_000)  // 2000-01-01 12:00 UTC
        try await ack(.setUTC(millisecondsSinceJ2000: Int(date.timeIntervalSince(j2000) * 1000)))
    }

    /// (altitude, azimuth) in degrees.
    public func altAz() async throws -> (altitude: Double, azimuth: Double) {
        let reply = try await send(.getAltAz)
        let body = Array(reply.dropLast())
        guard reply.hasSuffix("#"), body.count == 18, let sign = body.first, sign == "+" || sign == "-",
              let alt = Int(String(body[1..<9])), let az = Int(String(body[9..<18])) else {
            throw ReplyError.malformed(reply)
        }
        return (Centiarcsec.toDegrees(sign == "-" ? -alt : alt), Centiarcsec.toDegrees(az))
    }

    public func slew(altitude: Double, azimuth: Double) async throws {
        try await ack(.setAltitude(centiarcsec: Centiarcsec.fromDegrees(altitude)))
        try await ack(.setAzimuth(centiarcsec: Centiarcsec.fromDegrees(azimuth)))
        guard try await send(.slewAltAz) == "1" else { throw NormalModeError.slewRefused }
    }

    /// Slews to RA/Dec (degrees, equator and equinox of date) and lets the mount track.
    public func slew(rightAscension: Double, declination: Double, rate: NormalCommand.TrackingRate) async throws {
        try await ack(.setRightAscension(centiarcsec: Centiarcsec.fromDegrees(rightAscension)))
        try await ack(.setDeclination(centiarcsec: Centiarcsec.fromDegrees(declination)))
        guard try await send(.slewRADec) == "1" else { throw NormalModeError.slewRefused }
        try await ack(.trackingRate(rate))
    }

    public func sync(altitude: Double, azimuth: Double) async throws {
        try await ack(.setAltitude(centiarcsec: Centiarcsec.fromDegrees(altitude)))
        try await ack(.setAzimuth(centiarcsec: Centiarcsec.fromDegrees(azimuth)))
        try await ack(.sync)
    }

    public func setTracking(_ on: Bool) async throws { try await ack(.tracking(on)) }

    public func setMoveRate(_ rate: NormalCommand.MoveRate) async throws { try await ack(.moveRate(rate)) }

    public func startMove(_ direction: NormalCommand.Direction) async throws { try await send(.move(direction)) }

    public func stopMove(_ direction: NormalCommand.Direction) async throws {
        switch direction {
        case .east, .west: try await ack(.stopAzimuthMove)
        case .north, .south: try await ack(.stopAltitudeMove)
        }
    }

    /// Stops slews and arrow moves. Tracking is left as it was.
    public func stop() async throws {
        try await ack(.stop)
        try await ack(.stopAzimuthMove)
        try await ack(.stopAltitudeMove)
    }
}
