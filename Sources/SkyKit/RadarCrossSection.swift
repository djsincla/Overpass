import Foundation

/// Radar cross-sections (m²) from CelesTrak's satellite catalogue (SATCAT): a rough guide to a
/// satellite's size, and so to how bright it can get. Many objects, Starlink and most newer
/// launches among them, have none published.
public enum RadarCrossSection {
    /// About 7 MB, regenerated daily.
    public static let catalogURL = URL(string: "https://celestrak.org/pub/satcat.csv")!

    /// Catalogue number → RCS in m², for the objects that have one.
    public static func parse(_ csv: String) -> [String: Double] {
        var lines = csv.split(whereSeparator: \.isNewline).makeIterator()
        guard let header = lines.next()?.split(separator: ",", omittingEmptySubsequences: false),
              let idColumn = header.firstIndex(of: "NORAD_CAT_ID"),
              let rcsColumn = header.firstIndex(of: "RCS") else { return [:] }
        var out: [String: Double] = [:]
        while let line = lines.next() {
            let fields = fields(line)
            guard fields.count > max(idColumn, rcsColumn),
                  let rcs = Double(fields[rcsColumn]), rcs > 0 else { continue }
            out[key(fields[idColumn])] = rcs
        }
        return out
    }

    /// Catalogue numbers without leading zeros, so "00005" and "5" match.
    public static func key<S: StringProtocol>(_ noradID: S) -> String {
        let trimmed = noradID.trimmingCharacters(in: .whitespaces)
        return Int(trimmed).map(String.init) ?? trimmed
    }

    /// One CSV row; object names can be quoted and contain commas.
    static func fields(_ line: Substring) -> [Substring] {
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
        return out
    }
}
