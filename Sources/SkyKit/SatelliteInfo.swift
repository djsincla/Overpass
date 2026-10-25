import Foundation

/// What's known about a satellite beyond its orbit: from CelesTrak's satellite catalogue (SATCAT)
/// and Jonathan McDowell's General Catalog of Artificial Space Objects (GCAT, CC BY 4.0).
/// Neither needs an account. Any field can be missing.
public struct SatelliteInfo: Codable, Sendable, Equatable {
    /// International designator, "1998-067A".
    public var cosparID: String?
    /// SATCAT's PAY, R/B, DEB or UNK.
    public var objectType: String?
    /// SATCAT's owner code: US, PRC, CIS, ESA, JPN…
    public var owner: String?
    /// "1998-11-20".
    public var launchDate: String?
    /// Minutes.
    public var period: Double?
    /// Degrees.
    public var inclination: Double?
    /// Kilometres above the surface.
    public var perigee: Double?
    public var apogee: Double?
    /// Radar cross-section in m², where published (most objects launched since about 2017 have none).
    public var radarCrossSection: Double?
    /// Physical dimensions in metres (GCAT). Span is across solar panels or booms.
    public var length: Double?
    public var diameter: Double?
    public var span: Double?
    /// GCAT's shape, such as "Cyl + 2 Pan".
    public var shape: String?

    public init() {}

    public var largestDimension: Double? { [length, diameter, span].compactMap { $0 }.max() }

    /// Small, medium or large: from the radar cross-section where there is one (Space-Track's
    /// classes: under 0.1 m², up to 1 m², over 1 m²), otherwise from the largest dimension
    /// (under 0.3 m, up to 1 m, over 1 m).
    public var sizeClass: SizeClass? {
        if let rcs = radarCrossSection { return rcs < 0.1 ? .small : rcs <= 1 ? .medium : .large }
        if let size = largestDimension { return size < 0.3 ? .small : size <= 1 ? .medium : .large }
        return nil
    }

    public var objectTypeName: String? {
        switch objectType {
        case "PAY": "Payload"
        case "R/B": "Rocket body"
        case "DEB": "Debris"
        case "UNK": "Unknown type"
        default: objectType
        }
    }

    /// Launch as a decimal year (2020.5 is mid-2020), for sorting and comparing.
    public var launchYear: Double? { launchDate.flatMap(Self.decimalYear) }

    /// "2020", "2020-06" or "2020-06-15" as a decimal year at the start of that period.
    static func decimalYear(_ text: String) -> Double? {
        let parts = text.split(separator: "-").map { Int($0) }
        guard let year = parts.first ?? nil, (1900...2200).contains(year) else { return nil }
        let month = parts.count > 1 ? parts[1] ?? 1 : 1
        let day = parts.count > 2 ? parts[2] ?? 1 : 1
        return Double(year) + (Double(month - 1) * 30.44 + Double(day - 1)) / 365.25
    }

    public enum SizeClass: Int, Codable, Sendable, Comparable, CaseIterable {
        case small, medium, large
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
        public var name: String {
            switch self {
            case .small: "Small"
            case .medium: "Medium"
            case .large: "Large"
            }
        }
    }
}

public enum SatelliteCatalogInfo {
    /// About 7 MB, regenerated daily.
    public static let celesTrakURL = URL(string: "https://celestrak.org/pub/satcat.csv")!
    /// About 19 MB, updated every few days.
    public static let gcatURL = URL(string: "https://planet4589.org/space/gcat/tsv/cat/satcat.tsv")!

    /// Catalogue numbers without leading zeros, so "00005" and "5" match.
    public static func key<S: StringProtocol>(_ noradID: S) -> String {
        let trimmed = noradID.trimmingCharacters(in: .whitespaces)
        return Int(trimmed).map(String.init) ?? trimmed
    }

    /// Objects still in orbit, by catalogue number.
    public static func parseCelesTrak(_ csv: String) -> [String: SatelliteInfo] {
        var lines = csv.split(whereSeparator: \.isNewline).makeIterator()
        guard let header = lines.next().map({ csvFields($0).map(String.init) }) else { return [:] }
        func column(_ name: String) -> Int? { header.firstIndex(of: name) }
        guard let id = column("NORAD_CAT_ID") else { return [:] }
        let decay = column("DECAY_DATE")
        var out: [String: SatelliteInfo] = [:]
        while let line = lines.next() {
            let fields = csvFields(line).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == header.count else { continue }
            if let decay, !fields[decay].isEmpty { continue }
            func text(_ name: String) -> String? { column(name).map { fields[$0] }.flatMap { $0.isEmpty ? nil : $0 } }
            func number(_ name: String) -> Double? { text(name).flatMap(Double.init) }
            var info = SatelliteInfo()
            info.cosparID = text("OBJECT_ID")
            info.objectType = text("OBJECT_TYPE")
            info.owner = text("OWNER")
            info.launchDate = text("LAUNCH_DATE")
            info.period = number("PERIOD")
            info.inclination = number("INCLINATION")
            info.perigee = number("PERIGEE")
            info.apogee = number("APOGEE")
            info.radarCrossSection = number("RCS").flatMap { $0 > 0 ? $0 : nil }
            out[key(fields[id])] = info
        }
        return out
    }

    /// Adds GCAT's dimensions and shape to the objects already listed.
    public static func addGCAT(_ tsv: String, to info: inout [String: SatelliteInfo]) {
        var columns: [String: Int] = [:]
        for line in tsv.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#") {
                if columns.isEmpty, line.hasPrefix("#JCAT") {
                    for (i, name) in line.dropFirst().split(separator: "\t", omittingEmptySubsequences: false).enumerated() {
                        columns["#" + name] = i  // keep "#JCAT" as the first name
                        columns[String(name)] = i
                    }
                }
                continue
            }
            guard let satcat = columns["Satcat"] else { return }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count > satcat else { continue }
            let id = key(fields[satcat])
            guard info[id] != nil else { continue }
            func value(_ name: String) -> String? {
                guard let i = columns[name], i < fields.count else { return nil }
                let v = fields[i].trimmingCharacters(in: .whitespaces)
                return v.isEmpty || v == "-" ? nil : v
            }
            func metres(_ name: String) -> Double? { value(name).flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil } }
            info[id]?.length = metres("Length")
            info[id]?.diameter = metres("Diameter")
            info[id]?.span = metres("Span")
            info[id]?.shape = value("Shape")
        }
    }

    /// One CSV row; names can be quoted and contain commas.
    static func csvFields(_ line: Substring) -> [Substring] {
        guard line.contains("\"") else { return line.split(separator: ",", omittingEmptySubsequences: false) }
        var out: [Substring] = []
        var start = line.startIndex, quoted = false, i = line.startIndex
        while i < line.endIndex {
            if line[i] == "\"" { quoted.toggle() } else if line[i] == ",", !quoted {
                out.append(line[start..<i])
                start = line.index(after: i)
            }
            i = line.index(after: i)
        }
        out.append(line[start...])
        return out.map { $0.hasPrefix("\"") && $0.hasSuffix("\"") && $0.count > 1 ? $0.dropFirst().dropLast() : $0 }
    }
}

/// Search text for satellites: plain words match the name, numbers, owner, type, launch date and
/// shape; `key<value`, `key>value`, `key<=value`, `key>=value` and `key=value` compare attributes.
/// Every term has to match. "launched>2020 period<100 owner=US" is three terms.
public struct SatelliteQuery: Sendable, Equatable {
    public enum Attribute: String, CaseIterable, Sendable {
        case launched, period, perigee, apogee, inclination, rcs, length, diameter, span, size, owner, type

        static func named(_ text: String) -> Attribute? {
            switch text.lowercased() {
            case "launched", "launch", "year": .launched
            case "period": .period
            case "perigee": .perigee
            case "apogee": .apogee
            case "inclination", "inc", "incl": .inclination
            case "rcs", "radar": .rcs
            case "length": .length
            case "diameter", "dia": .diameter
            case "span": .span
            case "size": .size
            case "owner", "country": .owner
            case "type": .type
            default: nil
            }
        }
    }

    enum Comparison: String, Sendable { case lessOrEqual = "<=", greaterOrEqual = ">=", less = "<", greater = ">", equal = "=" }

    enum Term: Sendable, Equatable {
        case word(String)
        case compare(Attribute, Comparison, String)
    }

    let terms: [Term]

    public init(_ text: String) {
        terms = text.split(whereSeparator: \.isWhitespace).map { token in
            for op in [Comparison.lessOrEqual, .greaterOrEqual, .less, .greater, .equal] {
                if let range = token.range(of: op.rawValue) {
                    let key = String(token[..<range.lowerBound]), value = String(token[range.upperBound...])
                    if let attribute = Attribute.named(key), !value.isEmpty { return .compare(attribute, op, value) }
                }
            }
            // "owner:PRC" reads as equality too.
            if let colon = token.firstIndex(of: ":"), let attribute = Attribute.named(String(token[..<colon])),
               token.index(after: colon) < token.endIndex {
                return .compare(attribute, .equal, String(token[token.index(after: colon)...]))
            }
            return .word(String(token))
        }
    }

    public var isEmpty: Bool { terms.isEmpty }
    /// True when the query compares attributes, which only satellites have.
    public var comparesAttributes: Bool { terms.contains { if case .compare = $0 { true } else { false } } }

    public func matches(name: String, noradID: String, info: SatelliteInfo?) -> Bool {
        terms.allSatisfy { term in
            switch term {
            case .word(let word):
                let haystack = [name, noradID, info?.cosparID, info?.owner, info?.objectType, info?.objectTypeName,
                                info?.launchDate, info?.shape, info?.sizeClass?.name].compactMap { $0 }
                return haystack.contains { $0.localizedCaseInsensitiveContains(word) }
                    || SatelliteCatalogInfo.key(word) == SatelliteCatalogInfo.key(noradID)
            case .compare(let attribute, let op, let value):
                guard let info else { return false }
                return Self.compare(attribute, op, value, info)
            }
        }
    }

    static func compare(_ attribute: Attribute, _ op: Comparison, _ value: String, _ info: SatelliteInfo) -> Bool {
        switch attribute {
        case .owner:
            guard let owner = info.owner else { return false }
            return op == .equal ? owner.caseInsensitiveCompare(value) == .orderedSame : false
        case .type:
            guard op == .equal, let type = info.objectType else { return false }
            return type.caseInsensitiveCompare(value) == .orderedSame
                || (info.objectTypeName ?? "").lowercased().hasPrefix(value.lowercased())
                || (value.lowercased().hasPrefix("rocket") && type == "R/B")
        case .size:
            if let target = SatelliteInfo.SizeClass.allCases.first(where: { $0.name.lowercased().hasPrefix(value.lowercased()) }) {
                guard let size = info.sizeClass else { return false }
                return ordered(Double(size.rawValue), op, Double(target.rawValue), within: 0.5)
            }
            return numeric(info.largestDimension, op, value)
        case .launched:
            guard let launched = info.launchYear, let start = SatelliteInfo.decimalYear(value) else { return false }
            // "launched=2020" means during 2020; "launched=2020-06" during June.
            let parts = value.split(separator: "-").count
            let end = parts == 1 ? start + 1 : parts == 2 ? start + 30.44 / 365.25 : start + 1 / 365.25
            switch op {
            case .equal: return launched >= start && launched < end
            case .less: return launched < start
            case .lessOrEqual: return launched < end
            case .greater: return launched >= end
            case .greaterOrEqual: return launched >= start
            }
        case .period: return numeric(info.period, op, value)
        case .perigee: return numeric(info.perigee, op, value)
        case .apogee: return numeric(info.apogee, op, value)
        case .inclination: return numeric(info.inclination, op, value)
        case .rcs: return numeric(info.radarCrossSection, op, value)
        case .length: return numeric(info.length, op, value)
        case .diameter: return numeric(info.diameter, op, value)
        case .span: return numeric(info.span, op, value)
        }
    }

    /// "=" matches to the precision typed: period=92 is 91.5 to 92.5, period=92.9 is 92.85 to 92.95.
    static func numeric(_ actual: Double?, _ op: Comparison, _ text: String) -> Bool {
        guard let actual, let target = Double(text) else { return false }
        let decimals = text.split(separator: ".").dropFirst().first?.count ?? 0
        return ordered(actual, op, target, within: 0.5 * pow(10, -Double(decimals)))
    }

    static func ordered(_ actual: Double, _ op: Comparison, _ target: Double, within tolerance: Double) -> Bool {
        switch op {
        case .equal: abs(actual - target) <= tolerance
        case .less: actual < target
        case .lessOrEqual: actual <= target
        case .greater: actual > target
        case .greaterOrEqual: actual >= target
        }
    }
}
