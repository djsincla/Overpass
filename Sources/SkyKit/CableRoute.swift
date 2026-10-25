import Foundation

/// Gotos that never swing through the cable stop, for mounts that choose their own route.
///
/// In normal mode the mount always takes the shorter way round. The cable stop splits the
/// circle into one allowed range, so where the mount is, and which way it must turn to reach a
/// target, both follow from the azimuths alone. When the allowed way is the longer one, the
/// move is broken into legs each short enough that the mount's own shorter way is the right way.
public enum CableRoute {
    /// The longest leg sent as one goto. Under 180° with room to spare, so the mount can't
    /// pick the other way round.
    public static let maximumLeg = 170.0

    /// Azimuth measured from the stop, [0, 360): the position within the cable range.
    public static func offset(_ azimuth: Double, stop: Double) -> Double {
        normalizedDegrees(azimuth - stop)
    }

    /// The waypoints to go through, ending at `to`. One element when a plain goto is safe.
    /// Nil when the target sits inside the margin either side of the stop.
    public static func legs(from: Horizontal, to: Horizontal, stop: Double, margin: Double = 0,
                            maximumLeg: Double = maximumLeg) -> [Horizontal]? {
        let target = offset(to.azimuth, stop: stop)
        guard target >= margin, target <= 360 - margin else { return nil }
        // The signed turn that stays inside the range: up to ±360°, never through the stop.
        let turn = target - offset(from.azimuth, stop: stop)
        let count = max(1, Int((abs(turn) / maximumLeg).rounded(.up)))
        return (1...count).map { i in
            let f = Double(i) / Double(count)
            return Horizontal(azimuth: normalizedDegrees(from.azimuth + turn * f),
                              altitude: from.altitude + (to.altitude - from.altitude) * f)
        }
    }
}
