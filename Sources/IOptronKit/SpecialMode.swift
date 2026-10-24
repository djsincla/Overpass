/// iOptron Special Mode command language (2023-05-08).
/// See docs/iOptron-Special-Mode-Protocol.md.

public enum Axis: Int, Sendable {
    /// Azimuth on alt-az mounts, RA on equatorial.
    case primary = 0
    /// Altitude on alt-az mounts, Dec on equatorial.
    case secondary = 1
}

public enum MountModel: Equatable, Sendable {
    case azMountPro
    case haz31
    case haz46
    case hae29
    case hae43
    case unknown(String)

    /// Models that lack the combined `:P2#` / `:M2#` commands.
    public var supportsCombinedCommands: Bool {
        switch self {
        case .hae29, .hae43: false
        default: true
        }
    }
}

public struct MountIdentity: Equatable, Sendable {
    public let model: MountModel
    public let isSpecialMode: Bool
    public let rawCode: String

    /// Parses the 4-character `:MountInfo#` reply. Special mode is indicated by a leading 8 or 9.
    public init(code: String) {
        rawCode = code
        guard code.count == 4, let first = code.first else {
            model = .unknown(code)
            isSpecialMode = false
            return
        }
        isSpecialMode = first == "8" || first == "9"
        switch code.dropFirst() {
        case "035" where first == "5" || first == "9": model = .azMountPro
        case "035": model = .haz31
        case "052": model = .haz46
        case "033", "034": model = .hae29
        case "050", "051": model = .hae43
        default: model = .unknown(code)
        }
    }
}

public enum Command: Equatable, Sendable {
    case mountInfo
    case toggleMode
    case position(Axis)
    case positions
    case sync(Axis, centiarcsec: Int)
    case speed(Axis, centiarcsecPerSecond: Int)
    case speeds(primary: Int?, secondary: Int?)
    case actualSpeed(Axis)
    case slew(Axis, centiarcsec: Int)

    public var wire: String {
        switch self {
        case .mountInfo: ":MountInfo#"
        case .toggleMode: ":ZZZ#"
        case .position(let axis): ":P\(axis.rawValue)#"
        case .positions: ":P2#"
        case .sync(let axis, let value): ":S\(axis.rawValue)\(Self.signed(value, digits: 9, range: Centiarcsec.positionRange))#"
        case .speed(let axis, let value): ":M\(axis.rawValue)\(Self.signed(value, digits: 7, range: Centiarcsec.speedRange))#"
        case .speeds(let p, let s): ":M2\(Self.optionalSpeed(p))\(Self.optionalSpeed(s))#"
        case .actualSpeed(let axis): ":Q\(axis.rawValue)#"
        case .slew(let axis, let value): ":T\(axis.rawValue)\(Self.signed(value, digits: 9, range: Centiarcsec.positionRange))#"
        }
    }

    public var expectedReply: ReplyFormat {
        switch self {
        case .mountInfo: .fixed(4)
        case .toggleMode: .none
        case .position, .actualSpeed: .terminated
        case .positions: .terminated
        case .sync, .speed, .speeds, .slew: .fixed(1)
        }
    }

    static func signed(_ value: Int, digits: Int, range: ClosedRange<Int>) -> String {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        let magnitude = String(abs(clamped))
        let padded = String(repeating: "0", count: max(0, digits - magnitude.count)) + magnitude
        return (clamped < 0 ? "-" : "+") + padded
    }

    /// `:M2` skips an axis when its sign character is neither `+` nor `-`.
    static func optionalSpeed(_ value: Int?) -> String {
        guard let value else { return "*0000000" }
        return signed(value, digits: 7, range: Centiarcsec.speedRange)
    }
}

public enum ReplyFormat: Equatable, Sendable {
    case none
    case fixed(Int)
    /// Read up to and including `#`.
    case terminated
}

public enum ReplyError: Error, Equatable {
    case malformed(String)
    case rejected(String)
}

public enum Reply {
    /// Parses one or more `±digits` fields from a `#`-terminated reply, e.g. `+000012345#`
    /// or the `:P2#` form `+000012345-000067890#`.
    public static func signedFields(_ reply: String, digits: Int) throws -> [Int] {
        guard reply.hasSuffix("#") else { throw ReplyError.malformed(reply) }
        let body = Array(reply.dropLast())
        let width = digits + 1
        guard !body.isEmpty, body.count % width == 0 else { throw ReplyError.malformed(reply) }

        return try stride(from: 0, to: body.count, by: width).map { start in
            let field = body[start..<start + width]
            guard let sign = field.first, sign == "+" || sign == "-",
                  let magnitude = Int(String(field.dropFirst())) else {
                throw ReplyError.malformed(reply)
            }
            return sign == "-" ? -magnitude : magnitude
        }
    }

    public static func ack(_ reply: String) throws {
        guard reply == "1" else { throw ReplyError.rejected(reply) }
    }
}
