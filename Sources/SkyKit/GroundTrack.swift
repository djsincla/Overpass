import Foundation

/// A point under a satellite at a moment: where on the ground it is directly overhead.
public struct GroundPoint: Sendable, Equatable {
    public let date: Date
    public let place: Geodetic
}

/// Ground tracks: the path on the Earth directly below a satellite.
public enum GroundTrack {
    /// Points under `satellite` from `start` to `end`, every `step` seconds (the end included).
    public static func points(of satellite: SatelliteTarget, from start: Date, to end: Date,
                              step: TimeInterval = 20) -> [GroundPoint] {
        guard end > start, step > 0 else { return [] }
        var dates = Array(stride(from: start, to: end, by: step))
        dates.append(end)
        return dates.compactMap { date in
            guard let p = try? satellite.earthFixedPosition(at: AstroTime(date)) else { return nil }
            return GroundPoint(date: date, place: Geodesy.geodetic(ofEarthFixed: p))
        }
    }

    /// The track split wherever it crosses the 180° meridian, so no segment draws a line across
    /// the whole map. Each crossing gets a point on the meridian at both ends, so the line meets it.
    public static func segments(_ points: [GroundPoint]) -> [[Geodetic]] {
        guard let first = points.first else { return [] }
        var segments: [[Geodetic]] = [[first.place]]
        for (a, b) in zip(points, points.dropFirst()) {
            let la = a.place.longitude, lb = b.place.longitude
            if abs(lb - la) > 180 {
                // Unwrap b next to a, find where the line between them meets ±180°.
                let unwrapped = lb + (lb < la ? 360 : -360)
                let edge = la > 0 ? 180.0 : -180.0
                let f = (edge - la) / (unwrapped - la)
                let latitude = a.place.latitude + f * (b.place.latitude - a.place.latitude)
                segments[segments.count - 1].append(Geodetic(latitude: latitude, longitude: edge))
                segments.append([Geodetic(latitude: latitude, longitude: -edge), b.place])
            } else {
                segments[segments.count - 1].append(b.place)
            }
        }
        return segments
    }

    /// The window drawn for a pass on the globe: half an orbit either side of it, so the track
    /// shows where the satellite comes from and goes, capped for slow, high orbits.
    public static func window(for pass: SatellitePass, period minutes: Double) -> (start: Date, end: Date) {
        let half = min(minutes * 60 / 2, 3 * 3600)
        return (pass.start.date - half, pass.end.date + half)
    }
}
