import Foundation

/// Raw mount axis readings, in degrees (from `:P0#` / `:P1#`).
public struct AxisPosition: Equatable, Sendable, Codable {
    public var primary: Double
    public var secondary: Double

    public init(primary: Double, secondary: Double) {
        self.primary = primary
        self.secondary = secondary
    }
}

/// One alignment sighting: where the target really was, and where the axes were when it was centred.
public struct AlignmentPoint: Sendable {
    public let targetName: String
    public let date: Date
    public let sky: Horizontal
    public let axes: AxisPosition

    public init(targetName: String, date: Date, sky: Horizontal, axes: AxisPosition) {
        self.targetName = targetName
        self.date = date
        self.sky = sky
        self.axes = axes
    }
}

/// Maps the true sky to the mount's axes for an alt-az mount.
///
/// The mount frame is the sky frame rotated by a yaw (azimuth zero offset) and two small tilts
/// (from not being level). The altitude axis has its own zero offset, and the azimuth axis may
/// count either way round. One star fixes the two offsets; two or more also fix the tilt.
public struct AlignmentModel: Sendable, Codable, Equatable {
    /// Azimuth zero offset, degrees.
    public var yaw: Double = 0
    /// Tilt of the azimuth axis about north and east, degrees.
    public var tiltNorth: Double = 0
    public var tiltEast: Double = 0
    /// Added to the mount-frame altitude to get the secondary axis reading.
    public var altitudeOffset: Double = 0
    /// +1 if the primary axis reading increases clockwise from above (north → east), −1 otherwise.
    public var azimuthSense: Double = 1
    /// +1 if the secondary axis reading increases as the tube rises, −1 if it counts the other way.
    public var altitudeSense: Double = 1

    public init() {}

    enum CodingKeys: String, CodingKey {
        case yaw, tiltNorth, tiltEast, altitudeOffset, azimuthSense, altitudeSense
    }

    /// Fields added later decode to their defaults, so saved alignments keep working.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        yaw = try c.decodeIfPresent(Double.self, forKey: .yaw) ?? 0
        tiltNorth = try c.decodeIfPresent(Double.self, forKey: .tiltNorth) ?? 0
        tiltEast = try c.decodeIfPresent(Double.self, forKey: .tiltEast) ?? 0
        altitudeOffset = try c.decodeIfPresent(Double.self, forKey: .altitudeOffset) ?? 0
        azimuthSense = try c.decodeIfPresent(Double.self, forKey: .azimuthSense) ?? 1
        altitudeSense = try c.decodeIfPresent(Double.self, forKey: .altitudeSense) ?? 1
    }

    var rotation: Mat3 { Mat3.rotX(tiltNorth) * Mat3.rotY(tiltEast) * Mat3.rotZ(yaw) }

    public func axes(for sky: Horizontal) -> AxisPosition {
        let m = (rotation * sky.unitVector).spherical
        return AxisPosition(primary: wrap180(azimuthSense * m.longitude), secondary: altitudeSense * m.latitude + altitudeOffset)
    }

    /// The direction in the mount's own frame (after yaw and tilt), in degrees.
    public func mountFrame(_ sky: Horizontal) -> (azimuth: Double, altitude: Double) {
        let m = (rotation * sky.unitVector).spherical
        return (m.longitude, m.latitude)
    }

    /// Axis readings for a mount-frame direction. The azimuth is not wrapped, so turns are kept,
    /// and altitudes past 90° describe pointing over the top.
    public func axes(mountAzimuth: Double, mountAltitude: Double) -> AxisPosition {
        AxisPosition(primary: azimuthSense * mountAzimuth, secondary: altitudeSense * mountAltitude + altitudeOffset)
    }

    public func sky(for axes: AxisPosition) -> Horizontal {
        let m = Vec3.unit(longitude: azimuthSense * axes.primary, latitude: altitudeSense * (axes.secondary - altitudeOffset))
        let s = (rotation.transposed * m).spherical
        return Horizontal(azimuth: s.longitude, altitude: s.latitude)
    }

    /// Angular error of each point under this model, in degrees.
    public func residuals(_ points: [AlignmentPoint]) -> [Double] {
        points.map { angularSeparation(sky(for: $0.axes).unitVector, $0.sky.unitVector) }
    }

    public func rms(_ points: [AlignmentPoint]) -> Double {
        let r = residuals(points)
        return r.isEmpty ? 0 : (r.map { $0 * $0 }.reduce(0, +) / Double(r.count)).squareRoot()
    }

    /// How far the azimuth axis leans from vertical, in degrees.
    public var tilt: Double { angularSeparation(rotation.transposed * Vec3(0, 0, 1), Vec3(0, 0, 1)) }

    /// A levelled mount won't be tilted more than this; fits needing more are rejected.
    public static let maximumTilt = 10.0

    /// Fits a model to sightings. With one point the mount is assumed level and `azimuthSense`
    /// must be supplied; with two or more both senses are tried and the better plausible fit kept.
    /// Two points fit exactly (no error check); three or more give a meaningful `rms`.
    /// The altitude axis's direction works the same way: given, or tried both ways with two or more points.
    public static func fit(_ points: [AlignmentPoint], azimuthSense: Double? = nil, altitudeSense: Double? = nil) -> AlignmentModel? {
        guard let first = points.first else { return nil }
        let azimuthSenses: [Double] = azimuthSense.map { [$0] } ?? (points.count > 1 ? [1, -1] : [1])
        let altitudeSenses: [Double] = altitudeSense.map { [$0] } ?? (points.count > 1 ? [1, -1] : [1])
        let senses = azimuthSenses.flatMap { a in altitudeSenses.map { (a, $0) } }
        // With two points both senses fit exactly, but the wrong one needs an impossible tilt.
        return senses.map { (sense, altSense) in
            var model = AlignmentModel()
            model.azimuthSense = sense
            model.altitudeSense = altSense
            model.yaw = wrap180(sense * first.axes.primary - first.sky.azimuth)
            model.altitudeOffset = first.axes.secondary - altSense * first.sky.altitude
            if points.count > 1 { model.refine(points) }
            return model
        }
        .filter { $0.tilt <= maximumTilt }
        .min { $0.rms(points) < $1.rms(points) }
    }

    /// Gauss–Newton on (yaw, tiltNorth, tiltEast, altitudeOffset) with a numeric Jacobian.
    mutating func refine(_ points: [AlignmentPoint]) {
        func errors(_ p: [Double]) -> [Double] {
            var m = self
            (m.yaw, m.tiltNorth, m.tiltEast, m.altitudeOffset) = (p[0], p[1], p[2], p[3])
            return points.flatMap { point -> [Double] in
                let predicted = m.axes(for: point.sky)
                // Scale azimuth error by cos(alt) so both components are true angles.
                return [wrap180(predicted.primary - point.axes.primary) * cos(point.sky.altitude.radians),
                        predicted.secondary - point.axes.secondary]
            }
        }

        var p = [yaw, tiltNorth, tiltEast, altitudeOffset]
        for _ in 0..<20 {
            let e = errors(p)
            let h = 1e-6
            let jacobian = (0..<4).map { k -> [Double] in
                var q = p
                q[k] += h
                return zip(errors(q), e).map { ($0 - $1) / h }
            }
            // Normal equations JᵀJ Δ = −Jᵀe, with a little damping so two-star fits stay stable.
            var a = (0..<4).map { i in (0..<4).map { j in zip(jacobian[i], jacobian[j]).map(*).reduce(0, +) } }
            for i in 0..<4 { a[i][i] += 1e-9 }
            let b = (0..<4).map { i in -zip(jacobian[i], e).map(*).reduce(0, +) }
            guard let delta = solve4(a, b) else { break }
            p = zip(p, delta).map(+)
            if delta.map(abs).max()! < 1e-10 { break }
        }
        (yaw, tiltNorth, tiltEast, altitudeOffset) = (wrap180(p[0]), p[1], p[2], p[3])
    }
}

/// Gaussian elimination with partial pivoting.
func solve4(_ a: [[Double]], _ b: [Double]) -> [Double]? {
    var m = zip(a, b).map { $0 + [$1] }
    let n = b.count
    for col in 0..<n {
        guard let pivot = (col..<n).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }), abs(m[pivot][col]) > 1e-15 else {
            return nil
        }
        m.swapAt(col, pivot)
        for row in 0..<n where row != col {
            let f = m[row][col] / m[col][col]
            for k in col...n { m[row][k] -= f * m[col][k] }
        }
    }
    return (0..<n).map { m[$0][n] / m[$0][$0] }
}

/// Picks well-separated, bright alignment stars that are comfortably up.
public enum AlignmentStarPicker {
    public static func suggest(observer: Observer, date: Date, count: Int = 3,
                               minAltitude: Double = 20, maxAltitude: Double = 75,
                               stars: [Star] = BrightStars.all) -> [(star: Star, position: Horizontal)] {
        let time = AstroTime(date)
        let candidates = stars.compactMap { star -> (star: Star, position: Horizontal)? in
            let h = observer.horizontal(ofEarthFixed: star.earthFixedPosition(at: time))
            return (minAltitude...maxAltitude).contains(h.altitude) ? (star, h) : nil
        }.sorted { $0.star.magnitude < $1.star.magnitude }

        // Greedy: brightest first, then whichever star is farthest in azimuth from those chosen.
        guard let brightest = candidates.first else { return [] }
        var chosen = [brightest]
        while chosen.count < count {
            let remaining = candidates.filter { c in !chosen.contains { $0.star == c.star } }
            guard let next = remaining.max(by: { a, b in
                chosen.map { abs(wrap180($0.position.azimuth - a.position.azimuth)) }.min()!
                    < chosen.map { abs(wrap180($0.position.azimuth - b.position.azimuth)) }.min()!
            }) else { break }
            chosen.append(next)
        }
        return chosen
    }
}

extension AlignmentModel {
    /// The mount's own alignment, captured at the switch to Special mode: where the mount said
    /// it was pointing in Normal mode (`:GAC#`) just before, and the raw axes (`:P2#`) just after.
    /// One point, so the mount is taken as level. Which way the azimuth axis counts can't be
    /// told from one point; the sense needing the smaller zero offset is kept, since an aligned
    /// mount's axis zero sits near north.
    ///
    /// Axis directions measured earlier (see `axisSenses`) are used when given; without them the
    /// altitude axis is assumed to count upwards.
    public static func fromMount(sky: Horizontal, axes: AxisPosition,
                                 azimuthSense: Double? = nil, altitudeSense: Double? = nil) -> AlignmentModel? {
        let point = AlignmentPoint(targetName: "Mount", date: .now, sky: sky, axes: axes)
        let azimuthSenses = azimuthSense.map { [$0] } ?? [1.0, -1.0]
        return azimuthSenses.compactMap { fit([point], azimuthSense: $0, altitudeSense: altitudeSense ?? 1) }
            .min { abs(wrap180($0.yaw)) < abs(wrap180($1.yaw)) }
    }

    /// Which way each axis counts, from two comparisons of the mount's own pointing with the raw
    /// axes, before and after moving it. An axis that moved less than half a degree is left nil.
    public static func axisSenses(_ a: AlignmentPoint, _ b: AlignmentPoint) -> (azimuth: Double?, altitude: Double?) {
        let dAlt = b.sky.altitude - a.sky.altitude, dSecondary = b.axes.secondary - a.axes.secondary
        let dAz = wrap180(b.sky.azimuth - a.sky.azimuth), dPrimary = wrap180(b.axes.primary - a.axes.primary)
        let altitude: Double? = abs(dAlt) > 0.5 && abs(dSecondary) > 0.5 ? (dAlt * dSecondary > 0 ? 1 : -1) : nil
        let azimuth: Double? = abs(dAz) > 0.5 && abs(dPrimary) > 0.5 ? (dAz * dPrimary > 0 ? 1 : -1) : nil
        return (azimuth, altitude)
    }
}
