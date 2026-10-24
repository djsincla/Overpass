/// Angles and rates on the wire are in 0.01 arcsecond units.
public enum Centiarcsec {
    public static let perDegree: Double = 3600 * 100

    /// Position range accepted by `:S0/:S1/:T0/:T1` and returned by `:P0/:P1`.
    public static let positionRange: ClosedRange<Int> = -64_799_799...64_800_000

    /// Sign plus 7 digits caps the speed field at about 27.7°/s; the mount's own limit is lower.
    public static let speedRange: ClosedRange<Int> = -9_999_999...9_999_999

    public static func fromDegrees(_ degrees: Double) -> Int {
        Int((degrees * perDegree).rounded())
    }

    public static func toDegrees(_ value: Int) -> Double {
        Double(value) / perDegree
    }
}
