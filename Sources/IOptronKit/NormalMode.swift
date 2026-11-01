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
    /// Longitude, latitude and status digits, including whether the mount is slewing.
    case getStatus
    /// Maximum goto speed: 7 = 256×, 8 = 512×, 9 = the mount's maximum. Saved in the mount.
    case setMaximumSlewSpeed(Int)
    /// Main board and hand controller firmware dates.
    case firmwareMain
    /// The two motor boards' firmware dates.
    case firmwareMotors
    /// The mount's clock: UTC offset, daylight saving and milliseconds since J2000.
    case getTime

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
        case .getStatus: ":GLS#"
        case .setMaximumSlewSpeed(let n): ":MSR\(min(max(n, 7), 9))#"
        case .firmwareMain: ":FW1#"
        case .firmwareMotors: ":FW2#"
        case .getTime: ":GUT#"
        }
    }

    public var expectedReply: ReplyFormat {
        switch self {
        case .mountInfo: .fixed(4)
        case .getAltAz, .getStatus, .firmwareMain, .firmwareMotors, .getTime: .terminated
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

/// The mount's own idea of where it is.
public struct MountSite: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    /// 0 no GPS, 1 GPS without a fix yet, 2 GPS fix.
    public var gps: Int

    public var hasFix: Bool { gps == 2 }
}

/// What the mount says about itself: `:GLS#` in full, its firmware and its clock.
public struct MountReport: Equatable, Sendable {
    public var site: MountSite
    /// 0 stopped, 1 tracking, 2 slewing, 3 guiding, 4 meridian flip, 5 tracking (PEC), 6 parked, 7 stopped at home.
    public var system: Int
    /// 0 sidereal, 1 lunar, 2 solar, 3 King, 4 custom.
    public var trackingRate: Int
    /// The arrow-button speed, 1–9 as in `:SRn#`.
    public var moveSpeed: Int
    /// 1 RS-232 or Ethernet, 2 hand controller, 3 GPS.
    public var timeSource: Int
    public var northernHemisphere: Bool
    /// Firmware dates as "2023-05-12", nil when not reported (a hand controller that isn't plugged in).
    public var mainBoard: String?
    public var handController: String?
    public var azimuthBoard: String?
    public var altitudeBoard: String?
    /// The mount's clock in UTC when read, and the offset and daylight saving it was set with.
    public var clock: Date?
    public var utcOffsetMinutes: Int?
    public var daylightSaving: Bool?

    public static func systemName(_ n: Int) -> String {
        switch n {
        case 0: "Stopped"
        case 1: "Tracking"
        case 2: "Slewing"
        case 3: "Guiding"
        case 4: "Meridian flip"
        case 5: "Tracking with PEC"
        case 6: "Parked"
        case 7: "Stopped at home"
        default: "Status \(n)"
        }
    }

    public static func rateName(_ n: Int) -> String {
        switch n {
        case 0: "Sidereal"
        case 1: "Lunar"
        case 2: "Solar"
        case 3: "King"
        case 4: "Custom"
        default: "Rate \(n)"
        }
    }

    public static func timeSourceName(_ n: Int) -> String {
        switch n {
        case 1: "Computer"
        case 2: "Hand controller"
        case 3: "GPS"
        default: "Source \(n)"
        }
    }

    /// `:FW1#` and `:FW2#` reply two dates, `YYMMDDYYMMDD#`.
    static func firmwareDates(_ reply: String) -> (String?, String?)? {
        let body = Array(reply.dropLast())
        guard reply.hasSuffix("#"), body.count == 12 else { return nil }
        func date(_ s: ArraySlice<Character>) -> String? {
            let digits = String(s)
            guard digits.allSatisfy(\.isNumber), let m = Int(digits.dropFirst(2).prefix(2)), (1...12).contains(m) else { return nil }
            return "20\(digits.prefix(2))-\(digits.dropFirst(2).prefix(2))-\(digits.suffix(2))"
        }
        return (date(body[0..<6]), date(body[6..<12]))
    }

    /// `:GUT#` replies `sMMMdXXXXXXXXXXXXX#`: UTC offset in minutes, daylight saving, then
    /// milliseconds since J2000 (UTC).
    static func clock(_ reply: String) -> (date: Date, offset: Int, dst: Bool)? {
        let body = Array(reply.dropLast())
        guard reply.hasSuffix("#"), body.count == 18, let sign = body.first, sign == "+" || sign == "-",
              let offset = Int(String(body[1..<4])), let dst = Int(String(body[4])), let ms = Int(String(body[5..<18])) else { return nil }
        let j2000 = Date(timeIntervalSince1970: 946_728_000)
        return (j2000 + Double(ms) / 1000, sign == "-" ? -offset : offset, dst == 1)
    }
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

    /// The `:GLS#` system status digit: 0 stopped, 1 tracking, 2 slewing, 3 guiding,
    /// 4 meridian flip, 5 tracking (PEC), 6 parked, 7 stopped at home.
    public func systemStatus() async throws -> Int {
        try await status().system
    }

    /// Where the mount thinks it is, from `:GLS#`: its GPS position when it has a fix, otherwise
    /// what was last set in it.
    public func site() async throws -> MountSite {
        let status = try await status()
        return MountSite(latitude: status.latitude, longitude: status.longitude, gps: status.gps)
    }

    /// Whether the mount is tracking by itself, and at which rate (`:GLS#`): the system digit
    /// (1 tracking, 5 tracking with PEC) and the rate digit (0 sidereal, 1 lunar, 2 solar, 3 King, 4 custom).
    public func trackingState() async throws -> (system: Int, rate: Int) {
        let status = try await status()
        return (status.system, status.rate)
    }

    public func setTrackingRate(_ rate: NormalCommand.TrackingRate) async throws { try await ack(.trackingRate(rate)) }

    /// Everything the mount reports about itself. Only the status is required: older firmware
    /// may not answer the firmware or clock commands.
    public func report() async throws -> MountReport {
        let status = try await status()
        var report = MountReport(site: MountSite(latitude: status.latitude, longitude: status.longitude, gps: status.gps),
                                 system: status.system, trackingRate: status.rate, moveSpeed: status.speed,
                                 timeSource: status.source, northernHemisphere: status.north)
        if let reply = try? await send(.firmwareMain), let dates = MountReport.firmwareDates(reply) {
            (report.mainBoard, report.handController) = dates
        }
        if let reply = try? await send(.firmwareMotors), let dates = MountReport.firmwareDates(reply) {
            (report.azimuthBoard, report.altitudeBoard) = dates
        }
        if let reply = try? await send(.getTime), let clock = MountReport.clock(reply) {
            (report.clock, report.utcOffsetMinutes, report.daylightSaving) = (clock.date, clock.offset, clock.dst)
        }
        return report
    }

    private func status() async throws -> (longitude: Double, latitude: Double, gps: Int, system: Int, rate: Int, speed: Int, source: Int, north: Bool) {
        let reply = try await send(.getStatus)
        // Sign, 8 longitude digits, 8 latitude digits (+90°), then GPS, system, rate, speed, time source, hemisphere.
        let body = Array(reply.dropLast())
        guard reply.hasSuffix("#"), body.count == 23, let sign = body.first, sign == "+" || sign == "-",
              let longitude = Int(String(body[1..<9])), let latitude = Int(String(body[9..<17])),
              let gps = Int(String(body[17])), let system = Int(String(body[18])), let rate = Int(String(body[19])),
              let speed = Int(String(body[20])), let source = Int(String(body[21])) else {
            throw ReplyError.malformed(reply)
        }
        return (Centiarcsec.toDegrees(sign == "-" ? -longitude : longitude), Centiarcsec.toDegrees(latitude) - 90,
                gps, system, rate, speed, source, body[22] != "0")
    }

    public func isSlewing() async throws -> Bool { try await systemStatus() == 2 }

    public func setMaximumSlewSpeed(_ speed: Int) async throws { try await ack(.setMaximumSlewSpeed(speed)) }

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
