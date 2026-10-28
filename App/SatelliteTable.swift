import SkyKit
import SwiftUI

/// The columns of a source's satellite list. Each source sorts on its own; click a header to
/// sort by it, and again to reverse. Columns that don't fit the width are left out, least
/// useful first.
enum SatelliteColumn: String, CaseIterable, Codable, Identifiable {
    case name, number, cospar, type, owner, launched, period, perigee, apogee, inclination,
         dimensions, span, rcs, size, age

    var id: Self { self }

    func title(_ units: Units) -> String {
        switch self {
        case .name: "Name"
        case .number: "Number"
        case .cospar: "COSPAR"
        case .type: "Type"
        case .owner: "Owner"
        case .launched: "Launched"
        case .period: "Period min"
        case .perigee: "Perigee \(units.distanceUnit)"
        case .apogee: "Apogee \(units.distanceUnit)"
        case .inclination: "Incl."
        case .dimensions: "L × D \(units.lengthUnit)"
        case .span: "Span \(units.lengthUnit)"
        case .rcs: "RCS m²"
        case .size: "Size"
        case .age: "TLE age"
        }
    }

    func help(_ units: Units) -> String {
        let distance = units.imperial ? "miles" : "km", length = units.imperial ? "feet" : "metres"
        return switch self {
        case .name: "Name in the TLE source"
        case .number: "NORAD catalogue number"
        case .cospar: "International designator: launch year, launch number and piece"
        case .type: "Payload, rocket body or debris"
        case .owner: "Owner or operator country code"
        case .launched: "Launch date"
        case .period: "Orbital period, minutes"
        case .perigee: "Lowest height above the surface, \(distance)"
        case .apogee: "Highest height above the surface, \(distance)"
        case .inclination: "Orbital inclination, degrees"
        case .dimensions: "Length × diameter, \(length) (GCAT)"
        case .span: "Span across solar panels or booms, \(length) (GCAT)"
        case .rcs: "Radar cross-section, m², where published"
        case .size: "Small, medium or large: from the radar cross-section, or else the largest dimension"
        case .age: "Age of the orbital elements"
        }
    }

    /// Fixed width; the name takes what's left.
    var width: CGFloat {
        switch self {
        case .name: 0
        case .number: 54
        case .cospar: 82
        case .type: 76
        case .owner: 44
        case .launched: 78
        case .period, .perigee, .apogee: 58
        case .inclination: 44
        case .dimensions: 70
        case .span, .rcs: 50
        case .size: 52
        case .age: 50
        }
    }

    var numeric: Bool { ![.name, .cospar, .type, .owner, .size].contains(self) }

    /// Kept first when the list is narrow.
    static let byImportance: [SatelliteColumn] = [.age, .launched, .size, .period, .rcs, .dimensions, .span,
                                                  .owner, .type, .perigee, .apogee, .inclination, .number, .cospar]

    /// The name column grows to this and no further, so the numbers sit next to it on a wide screen.
    static let nameWidth: CGFloat = 260

    /// The columns that fit, in display order. The name keeps at least 170 points.
    static func fitting(_ width: CGFloat) -> [SatelliteColumn] {
        var room = width - 170 - 70  // the name, the tick and the list's own insets
        var shown: Set<SatelliteColumn> = []
        for column in byImportance where column.width + 8 <= room {
            shown.insert(column)
            room -= column.width + 8
        }
        return allCases.filter { $0 != .name && shown.contains($0) }
    }

    func text(_ sat: SatelliteTarget, _ info: SatelliteInfo?, _ units: Units) -> String {
        func number(_ v: Double?, _ digits: Int) -> String {
            v.map { $0.formatted(.number.precision(.fractionLength(digits)).grouping(.never)) } ?? "–"
        }
        func metres(_ v: Double?) -> String { v.map(units.lengthNumber) ?? "–" }
        func km(_ v: Double?) -> String { number(v.map { units.imperial ? $0 / Units.kmPerMile : $0 }, 0) }
        switch self {
        case .name: return sat.name
        case .number: return sat.noradID
        case .cospar: return info?.cosparID ?? "–"
        case .type: return info?.objectTypeName ?? "–"
        case .owner: return info?.owner ?? "–"
        case .launched: return info?.launchDate ?? "–"
        case .period: return number(info?.period, 1)
        case .perigee: return km(info?.perigee)
        case .apogee: return km(info?.apogee)
        case .inclination: return info?.inclination.map { String(format: "%.1f°", $0) } ?? "–"
        case .dimensions:
            let parts = [info?.length, info?.diameter].compactMap { $0 }
            return parts.isEmpty ? "–" : parts.map { metres($0) }.joined(separator: " × ")
        case .span: return metres(info?.span)
        case .rcs: return info?.radarCrossSection.map { $0 >= 10 ? number($0, 0) : number($0, $0 >= 1 ? 1 : 2) } ?? "–"
        case .size: return info?.sizeClass?.name ?? "–"
        case .age:
            let days = sat.elementAge() / 86_400
            return days < 1 ? "\(Int(days * 24)) h" : String(format: "%.1f d", days)
        }
    }

    enum Key: Comparable {
        case number(Double)
        case text(String)
    }

    func key(_ sat: SatelliteTarget, _ info: SatelliteInfo?) -> Key? {
        switch self {
        case .name: .text(sat.name.lowercased())
        case .number: Double(SatelliteCatalogInfo.key(sat.noradID)).map(Key.number) ?? .text(sat.noradID)
        case .cospar: info?.cosparID.map(Key.text)
        case .type: info?.objectTypeName.map(Key.text)
        case .owner: info?.owner.map(Key.text)
        case .launched: info?.launchYear.map(Key.number)
        case .period: info?.period.map(Key.number)
        case .perigee: info?.perigee.map(Key.number)
        case .apogee: info?.apogee.map(Key.number)
        case .inclination: info?.inclination.map(Key.number)
        case .dimensions: [info?.length, info?.diameter].compactMap { $0 }.max().map(Key.number)
        case .span: info?.span.map(Key.number)
        case .rcs: info?.radarCrossSection.map(Key.number)
        case .size: info?.sizeClass.map { .number(Double($0.rawValue)) }
        case .age: .number(sat.elementAge())
        }
    }
}

struct ColumnSort: Codable, Equatable {
    var column: SatelliteColumn = .name
    var ascending = true

    /// Satellites with nothing published for the column go last either way, by name.
    func sorted(_ satellites: [SatelliteTarget], info: (SatelliteTarget) -> SatelliteInfo?) -> [SatelliteTarget] {
        let keyed = satellites.map { ($0, column.key($0, info($0))) }
        return keyed.sorted { a, b in
            switch (a.1, b.1) {
            case let (x?, y?) where x != y: return ascending ? x < y : x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.0.name.localizedStandardCompare(b.0.name) == .orderedAscending
            }
        }.map(\.0)
    }
}

/// The column titles for one source; clicking one sorts by it, clicking again reverses.
struct SatelliteColumnHeader: View {
    @Environment(AppModel.self) private var model
    let columns: [SatelliteColumn]
    @Binding var sort: ColumnSort

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 20, height: 1)
            title(.name).frame(minWidth: 120, maxWidth: SatelliteColumn.nameWidth, alignment: .leading)
            ForEach(columns) { column in
                title(column).frame(width: column.width, alignment: column.numeric ? .trailing : .leading)
            }
            Spacer(minLength: 0)
        }
        .font(.caption.weight(.semibold))
    }

    private func title(_ column: SatelliteColumn) -> some View {
        let active = sort.column == column
        return Button {
            if active { sort.ascending.toggle() } else { sort = ColumnSort(column: column, ascending: true) }
        } label: {
            HStack(spacing: 2) {
                Text(column.title(model.units)).lineLimit(1).minimumScaleFactor(0.8)
                if active { Image(systemName: sort.ascending ? "chevron.up" : "chevron.down").font(.caption2.bold()) }
            }
            .foregroundStyle(active ? Color.accentColor : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(column.help(model.units))
        .accessibilityLabel(column.title(model.units))
        .accessibilityValue(active ? (sort.ascending ? "Sorted ascending" : "Sorted descending") : "")
        .accessibilityHint("Sorts by this column")
    }
}

/// One satellite as a row of columns, lined up with `SatelliteColumnHeader`.
struct SatelliteColumnRow: View {
    @Environment(AppModel.self) private var model
    let satellite: SatelliteTarget
    let info: SatelliteInfo?
    let columns: [SatelliteColumn]
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .frame(width: 20)
            Text(satellite.name).lineLimit(1).truncationMode(.tail)
                .frame(minWidth: 120, maxWidth: SatelliteColumn.nameWidth, alignment: .leading)
                .help(satellite.name)
            ForEach(columns) { column in
                Text(column.text(satellite, info, model.units))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(column == .age && satellite.elementAge() > 3 * 86_400 ? .orange : .secondary)
                    .lineLimit(1)
                    .frame(width: column.width, alignment: column.numeric ? .trailing : .leading)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
