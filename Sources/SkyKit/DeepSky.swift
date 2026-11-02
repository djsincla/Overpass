import Foundation

/// A galaxy, cluster or nebula from the Messier or Caldwell list, at J2000 coordinates.
public struct DeepSkyObject: Target, Hashable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case galaxy, openCluster, globularCluster, clusterWithNebula, nebula, darkNebula
        case planetaryNebula, supernovaRemnant, asterism, star, doubleStar

        public var name: String {
            switch self {
            case .galaxy: String(localized: "Galaxy", bundle: .module)
            case .openCluster: String(localized: "Open cluster", bundle: .module)
            case .globularCluster: String(localized: "Globular cluster", bundle: .module)
            case .clusterWithNebula: String(localized: "Cluster and nebula", bundle: .module)
            case .nebula: String(localized: "Nebula", bundle: .module)
            case .darkNebula: String(localized: "Dark nebula", bundle: .module)
            case .planetaryNebula: String(localized: "Planetary nebula", bundle: .module)
            case .supernovaRemnant: String(localized: "Supernova remnant", bundle: .module)
            case .asterism: String(localized: "Asterism", bundle: .module)
            case .star: String(localized: "Star", bundle: .module)
            case .doubleStar: String(localized: "Double star", bundle: .module)
            }
        }
    }

    /// "M31", "C14".
    public let id: String
    /// The common name, "Andromeda Galaxy", or empty.
    public let commonName: String
    /// "NGC 224", or empty.
    public let designation: String
    public let kind: Kind
    /// IAU abbreviation, "And".
    public let constellation: String
    /// J2000, degrees.
    public let ra: Double
    public let dec: Double
    public let magnitude: Double?
    /// Major axis, arcminutes.
    public let size: Double?
    /// Its number in other lists, "M31" for NGC 224.
    public let alsoKnownAs: String?

    public init(id: String, name: String, designation: String, kind: Kind, constellation: String,
                ra: Double, dec: Double, magnitude: Double?, size: Double?, alsoKnownAs: String? = nil) {
        self.id = id
        commonName = name
        self.designation = designation
        self.kind = kind
        self.constellation = constellation
        self.ra = ra
        self.dec = dec
        self.magnitude = magnitude
        self.size = size
        self.alsoKnownAs = alsoKnownAs
    }

    /// "M31 Andromeda Galaxy", or "M102 (NGC 5866)" without a common name.
    public var name: String {
        if !commonName.isEmpty { return "\(id) \(commonName)" }
        return designation.isEmpty || designation == id ? id : "\(id) (\(designation))"
    }

    public func equatorialOfDate(_ time: AstroTime) -> Vec3 {
        precessionFromJ2000(to: time) * Vec3.unit(longitude: ra, latitude: dec)
    }

    public func earthFixedPosition(at time: AstroTime) -> Vec3 {
        Star.distance * earthFixed(equatorialOfDate(time), siderealAngle: time.gast)
    }
}

/// The Messier and Caldwell lists (`DeepSkyData.swift`), and NGC and IC (`NGCICData.swift`), the
/// numbers the hand controller uses.
public enum DeepSky {
    public static var all: [DeepSkyObject] { messier + caldwell + ngc + ic }

    public static func object(_ id: String) -> DeepSkyObject? { byID[id] }

    private static let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    public static let ngc: [DeepSkyObject] = ngcIC.filter { $0.id.hasPrefix("NGC") }
    public static let ic: [DeepSkyObject] = ngcIC.filter { $0.id.hasPrefix("IC") }

    private static let ngcIC: [DeepSkyObject] = ngcICText.split(separator: "\n").compactMap(parse)

    /// designation|kind|constellation|ra|dec|magnitude|size|common name|Messier number.
    static func parse(_ line: Substring) -> DeepSkyObject? {
        let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 9, let kind = DeepSkyObject.Kind(rawValue: f[1]), let ra = Double(f[3]), let dec = Double(f[4]) else { return nil }
        return DeepSkyObject(id: f[0], name: f[7], designation: f[0], kind: kind, constellation: f[2], ra: ra, dec: dec,
                             magnitude: Double(f[5]), size: Double(f[6]), alsoKnownAs: Int(f[8]).map { "M\($0)" })
    }

    /// "m 31", "NGC891", "ngc 891" → "M31", "NGC 891": the form ids take, for jumping straight to one.
    public static func normalisedID(_ text: String) -> String? {
        let compact = text.uppercased().filter { !$0.isWhitespace }
        for prefix in ["NGC", "IC", "M", "C"] where compact.hasPrefix(prefix) {
            let number = compact.dropFirst(prefix.count)
            guard let first = number.first, first.isNumber else { continue }
            return prefix == "NGC" || prefix == "IC" ? "\(prefix) \(number)" : "\(prefix)\(number)"
        }
        return nil
    }
}

/// Every IAU-named star to magnitude 4, in `NamedStarsData.swift`.
public enum NamedStars {
    public static func star(_ name: String) -> Star? { byName[name] }

    private static let byName = Dictionary((all + BrightStars.all).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
}
