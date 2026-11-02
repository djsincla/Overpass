import Foundation

/// Distances and heights in the units chosen in Settings. Everything is stored and computed in
/// kilometres and metres; only what's shown changes.
struct Units: Equatable {
    var imperial: Bool

    static let kmPerMile = 1.609344
    static let metresPerFoot = 0.3048

    /// "km" or "mi".
    var distanceUnit: String { imperial ? "mi" : "km" }
    /// "m" or "ft".
    var lengthUnit: String { imperial ? "ft" : "m" }

    /// A distance given in kilometres, in km or miles, with `decimals` places: "12 km", "7.5 mi".
    /// The number follows the locale ("7,5 mi" in German); the unit symbol doesn't change.
    func distance(_ km: Double, decimals: Int = 0) -> String {
        let value = imperial ? km / Self.kmPerMile : km
        return value.formatted(.number.precision(.fractionLength(decimals)).grouping(.never)) + " " + distanceUnit
    }

    /// A length given in metres, in metres or feet, with up to one decimal place.
    func length(_ metres: Double) -> String {
        lengthNumber(metres) + " " + lengthUnit
    }

    /// The number alone, for a list of lengths sharing one unit ("12.6 × 4.2 m").
    func lengthNumber(_ metres: Double) -> String {
        (imperial ? metres / Self.metresPerFoot : metres).formatted(.number.precision(.fractionLength(0...1)))
    }

    /// Search radii offered in Conjunctions, in kilometres: round numbers in the chosen unit.
    var radii: [Double] {
        imperial ? [5.0, 10, 25, 50, 100].map { $0 * Self.kmPerMile } : [10, 25, 50, 100, 200]
    }
}
