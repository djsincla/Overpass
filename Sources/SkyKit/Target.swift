import Foundation
import SatelliteKit

/// Anything the mount can point at.
public protocol Target: Sendable {
    var name: String { get }
    /// Geocentric Earth-fixed position in km.
    func earthFixedPosition(at time: AstroTime) throws -> Vec3
}

/// A fixed star or deep-sky object at J2000 coordinates (proper motion ignored).
public struct Star: Target, Hashable {
    public let name: String
    /// J2000 right ascension in degrees.
    public let ra: Double
    /// J2000 declination in degrees.
    public let dec: Double
    public let magnitude: Double

    public init(name: String, ra: Double, dec: Double, magnitude: Double) {
        self.name = name
        self.ra = ra
        self.dec = dec
        self.magnitude = magnitude
    }

    /// Far enough that observer parallax is irrelevant.
    static let distance = 1e12

    public func equatorialOfDate(_ time: AstroTime) -> Vec3 {
        precessionFromJ2000(to: time) * Vec3.unit(longitude: ra, latitude: dec)
    }

    public func earthFixedPosition(at time: AstroTime) -> Vec3 {
        Self.distance * earthFixed(equatorialOfDate(time), siderealAngle: time.gast)
    }
}

/// An Earth satellite propagated from a TLE with SGP4/SDP4.
public struct SatelliteTarget: Target {
    public let satellite: Satellite

    public var name: String { satellite.commonName }
    public var noradID: String { satellite.noradIdent }

    /// Orbital period in minutes.
    public var period: Double { 2 * .pi / satellite.tle.n₀ }

    /// Epoch of the element set.
    public var epoch: Date { Date(timeIntervalSince1970: (satellite.t₀Days1950 + JD.epoch1950 - 2_440_587.5) * 86_400) }

    public init(_ satellite: Satellite) {
        self.satellite = satellite
    }

    public init(name: String, line1: String, line2: String) throws {
        let parsed = try Elements(name, line1, line2)
        // SatelliteKit 2.1.2 reads B*'s exponent digit as its character code ("-3" becomes
        // "-51"), which loses atmospheric drag: a low orbit then runs late by an amount growing
        // with the square of the days since epoch (ISS: ~0.6 s after 1 day, ~25 s after 7).
        // Rebuild the elements from the TLE columns with B* read correctly.
        let f = try TLEFields(line1: line1, line2: line2)
        let fixed = Elements(commonName: parsed.commonName, noradIndex: parsed.noradIndex, launchName: parsed.launchName,
                             t₀: Date(ds1950: parsed.t₀), e₀: f.eccentricity, i₀: f.inclination, ω₀: f.argumentOfPerigee,
                             Ω₀: f.rightAscension, M₀: f.meanAnomaly, n₀: f.meanMotion,
                             ephemType: parsed.ephemType, tleClass: parsed.tleClass, tleNumber: parsed.tleNumber,
                             revNumber: parsed.revNumber, dragCoeff: f.bstar)
        satellite = Satellite(withTLE: fixed)
    }

    /// TEME position in km.
    public func temePosition(at time: AstroTime) throws -> Vec3 {
        let p = try satellite.position(julianDays: time.jdUT)
        return Vec3(p.x, p.y, p.z)
    }

    /// TEME is rotated to Earth-fixed by GMST (polar motion ignored).
    public func earthFixedPosition(at time: AstroTime) throws -> Vec3 {
        earthFixed(try temePosition(at: time), siderealAngle: time.gmst)
    }

    /// True when the Earth's shadow (cylindrical model) does not cover the satellite.
    public func isSunlit(at time: AstroTime) throws -> Bool {
        let r = try temePosition(at: time)
        let sun = SolarSystemBody.sun.equatorialOfDate(time).normalized
        let along = r.dot(sun)
        if along > 0 { return true }
        return (r - along * sun).length > Observer.wgs84A
    }
}

/// The SGP4 inputs read straight from the TLE's fixed columns (angles in degrees, mean motion
/// in revolutions per day).
public struct TLEFields: Equatable, Sendable {
    public let inclination: Double
    public let rightAscension: Double
    public let eccentricity: Double
    public let argumentOfPerigee: Double
    public let meanAnomaly: Double
    public let meanMotion: Double
    public let bstar: Double

    public init(line1: String, line2: String) throws {
        let a = Array(line1), b = Array(line2)
        guard a.count >= 61, b.count >= 63 else { throw TLEFieldError.tooShort }
        func field(_ chars: [Character], _ range: ClosedRange<Int>) throws -> Double {
            let text = String(chars[range]).trimmingCharacters(in: .whitespaces)
            guard let value = Double(text) else { throw TLEFieldError.unreadable(text) }
            return value
        }
        inclination = try field(b, 8...15)
        rightAscension = try field(b, 17...24)
        eccentricity = try field(["0", "."] + Array(b[26...32]), 0...8)
        argumentOfPerigee = try field(b, 34...41)
        meanAnomaly = try field(b, 43...50)
        meanMotion = try field(b, 52...62)
        // B*: sign, five digits with an implied leading decimal point, exponent sign and digit,
        // e.g. " 14938-3" = 0.14938e-3.
        let sign: Double = a[53] == "-" ? -1 : 1
        let mantissa = try field(["0", "."] + Array(a[54...58]), 0...6)
        let exponentSign: Double = a[59] == "-" ? -1 : 1
        guard let exponent = a[60].wholeNumberValue else { throw TLEFieldError.unreadable(String(a[60])) }
        bstar = sign * mantissa * pow(10, exponentSign * Double(exponent))
    }
}

public enum TLEFieldError: Error, Equatable {
    case tooShort
    case unreadable(String)
}

public enum TLEParser {
    /// Parses two- or three-line element sets; unnamed sets are named by catalogue number.
    public static func parse(_ text: String) -> [SatelliteTarget] {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var targets: [SatelliteTarget] = []
        var i = 0
        while i < lines.count {
            if lines[i].hasPrefix("1 "), i + 1 < lines.count, lines[i + 1].hasPrefix("2 ") {
                append(name: "", lines[i], lines[i + 1])
                i += 2
            } else if i + 2 < lines.count, lines[i + 1].hasPrefix("1 "), lines[i + 2].hasPrefix("2 ") {
                append(name: lines[i].hasPrefix("0 ") ? String(lines[i].dropFirst(2)) : lines[i], lines[i + 1], lines[i + 2])
                i += 3
            } else {
                i += 1
            }
        }
        return targets

        func append(name: String, _ l1: String, _ l2: String) {
            if let t = try? SatelliteTarget(name: name, line1: l1, line2: l2) { targets.append(t) }
        }
    }
}

public enum CelesTrak {
    /// e.g. "visual", "stations", "amateur", "starlink".
    public static func groupURL(_ group: String) -> URL {
        URL(string: "https://celestrak.org/NORAD/elements/gp.php?GROUP=\(group)&FORMAT=tle")!
    }

    public static func catalogURL(_ noradID: Int) -> URL {
        URL(string: "https://celestrak.org/NORAD/elements/gp.php?CATNR=\(noradID)&FORMAT=tle")!
    }

    public static func fetch(_ url: URL, session: URLSession = .shared) async throws -> [SatelliteTarget] {
        let (data, _) = try await session.data(from: url)
        return TLEParser.parse(String(decoding: data, as: UTF8.self))
    }
}
