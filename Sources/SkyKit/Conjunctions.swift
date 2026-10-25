import Foundation

extension SolarSystemBody: Codable {}

/// Where a transit is seen at one instant: the ground point with the satellite on the centre of
/// the disc, and the two edges of the band where it's anywhere on the disc.
public struct ConjunctionPathPoint: Sendable, Codable, Equatable {
    public let date: Date
    public let centre: Geodetic
    public let left: Geodetic?
    public let right: Geodetic?
}

/// A satellite crossing the Moon or the Sun, seen from somewhere near the search centre.
public struct Conjunction: Sendable, Codable, Identifiable, Equatable {
    public var id: String { "\(noradID)-\(body.rawValue)-\(Int(closest.timeIntervalSince1970))" }

    public let satelliteName: String
    public let noradID: String
    public let body: SolarSystemBody
    /// When the centreline passes nearest the search centre.
    public let closest: Date
    public let closestPoint: Geodetic
    /// From the search centre to the centreline, km, and the bearing to go there.
    public let distance: Double
    public let bearing: Double
    /// Width of the band where the satellite is on the disc, km.
    public let width: Double
    /// How long the crossing lasts on the centreline, seconds.
    public let duration: TimeInterval
    /// Where to look from the closest point.
    public let bodyAltitude: Double
    public let bodyAzimuth: Double
    /// Satellite distance from the closest point, km.
    public let satelliteRange: Double
    /// Lit fraction of the Moon (nil for the Sun).
    public let illumination: Double?
    /// Epoch of the element set this was computed from.
    public let elementEpoch: Date
    /// Search centre and radius it was found with.
    public let centre: Geodetic
    public let radius: Double
    /// The band across the search area (out to twice the radius), every 0.05 s.
    public let path: [ConjunctionPathPoint]

    /// The search centre itself is inside the band: seen from home.
    public var visibleFromCentre: Bool { distance <= width / 2 }
}

/// How an event moved between two calculations (usually a newer element set).
public struct ConjunctionDrift: Sendable, Codable, Equatable {
    /// Later is positive.
    public let seconds: TimeInterval
    /// How far the centreline moved near the old closest point, and which way.
    public let distance: Double
    public let bearing: Double

    public init(from old: Conjunction, to new: Conjunction) {
        seconds = new.closest.timeIntervalSince(old.closest)
        let nearest = new.path.map(\.centre).min {
            Geodesy.distance($0, old.closestPoint) < Geodesy.distance($1, old.closestPoint)
        } ?? new.closestPoint
        distance = Geodesy.distance(old.closestPoint, nearest)
        bearing = Geodesy.bearing(from: old.closestPoint, to: nearest)
    }
}

/// Finds space-station (or any satellite) transits of the Moon and Sun near a place.
///
/// At each instant, the ray from the body's centre through the satellite meets the ground where
/// the satellite is seen on the disc's centre; rays from the limb bound the band. The band sweeps
/// across the ground in seconds, so the search screens cheaply from the centre first (pass
/// windows, then 1 s steps of separation), and only then traces the band every 0.05 s.
public struct ConjunctionFinder: Sendable {
    public var centre: Geodetic
    /// Search radius around the centre, km.
    public var radius: Double = 50
    public var bodies: [SolarSystemBody] = [.moon, .sun]
    /// The body must be at least this high where the band is.
    public var minimumBodyAltitude: Double = 10
    public var deltaT: TimeInterval = AstroTime.defaultDeltaT
    /// Shifts the satellite along its track (seconds): stands in for element-set timing error.
    var satelliteTimeOffset: TimeInterval = 0

    public init(centre: Geodetic) {
        self.centre = centre
    }

    public static func physicalRadius(_ body: SolarSystemBody) -> Double { body == .sun ? 695_700 : 1737.4 }

    func time(_ date: Date) -> AstroTime { AstroTime(date, deltaT: deltaT) }

    func satellitePosition(_ sat: SatelliteTarget, _ date: Date) throws -> Vec3 {
        try sat.earthFixedPosition(at: time(date + satelliteTimeOffset))
    }

    /// The ground point where the ray from `from` through `through` lands, with the body high
    /// enough there; nil if the ray misses the Earth or the body is too low.
    func landing(from m: Vec3, through s: Vec3) -> Vec3? {
        guard let g = Geodesy.intersectEllipsoid(origin: s, direction: (s - m).normalized) else { return nil }
        // The body is straight back along the ray, so its altitude is the ray's elevation there.
        let up = Geodesy.geodetic(ofEarthFixed: g).observer.horizontal(ofEarthFixed: m).altitude
        return up >= minimumBodyAltitude ? g : nil
    }

    /// The band's centre and edges at `date`, or nil if the centreline doesn't reach the ground.
    public func shadow(of sat: SatelliteTarget, on body: SolarSystemBody, at date: Date) throws -> ConjunctionPathPoint? {
        let s = try satellitePosition(sat, date)
        let m = body.earthFixedPosition(at: time(date))
        guard let g = landing(from: m, through: s) else { return nil }
        // Edges: rays from the limb on either side, across the direction the band is moving.
        var left: Geodetic?, right: Geodetic?
        let s2 = try satellitePosition(sat, date + 0.05)
        let m2 = body.earthFixedPosition(at: time(date + 0.05))
        if let g2 = Geodesy.intersectEllipsoid(origin: s2, direction: (s2 - m2).normalized) {
            let across = (s - m).cross(g2 - g)
            if across.length > 0 {
                let p = Self.physicalRadius(body) * across.normalized
                left = landing(from: m + p, through: s).map(Geodesy.geodetic(ofEarthFixed:))
                right = landing(from: m - p, through: s).map(Geodesy.geodetic(ofEarthFixed:))
            }
        }
        return ConjunctionPathPoint(date: date, centre: Geodesy.geodetic(ofEarthFixed: g), left: left, right: right)
    }

    /// Every transit whose centreline comes within `radius` of the centre, soonest first.
    public func find(_ satellites: [SatelliteTarget], from: Date, to: Date) async -> [Conjunction] {
        let finder = self
        return await withTaskGroup(of: [Conjunction].self) { group in
            for sat in satellites {
                for body in bodies {
                    group.addTask { (try? finder.find(sat, body, from: from, to: to)) ?? [] }
                }
            }
            var all: [Conjunction] = []
            for await found in group { all += found }
            return all.sorted { $0.closest < $1.closest }
        }
    }

    func find(_ sat: SatelliteTarget, _ body: SolarSystemBody, from: Date, to: Date) throws -> [Conjunction] {
        let home = centre.observer
        // 1. When the satellite is up around here at all (generously low: it sits higher or
        //    lower from elsewhere in the search area). Coarse tracks: only the windows matter.
        var predictor = PassPredictor(observer: home)
        predictor.minimumAltitude = max(-2, minimumBodyAltitude - 10)
        predictor.sampleInterval = 30
        predictor.deltaT = deltaT
        // (Pass times are in the satellite's shifted time; map them back.)
        let windows = try predictor.passes(of: sat, from: from + satelliteTimeOffset, to: to + satelliteTimeOffset)
            .map { ($0.start.date - 60 - satelliteTimeOffset, $0.end.date + 60 - satelliteTimeOffset) }

        var found: [Conjunction] = []
        for (start, end) in windows {
            // 2. Seconds when, from the centre, the satellite is near enough the body that it
            //    could be on the disc from somewhere within twice the radius.
            var candidates: [Date] = []
            var t = max(start, from)
            while t <= min(end, to) {
                let m = body.earthFixedPosition(at: time(t))
                if home.horizontal(ofEarthFixed: m).altitude > minimumBodyAltitude - 5 {
                    let toSat = try satellitePosition(sat, t) - home.position, toBody = m - home.position
                    let disc = asin(Self.physicalRadius(body) / toBody.length).degrees
                    let reach = atan(2 * radius / toSat.length).degrees
                    if angularSeparation(toSat, toBody) < reach + disc + 0.5 { candidates.append(t) }
                }
                t += 1
            }
            // 3. Trace the band through each run of candidate seconds.
            for run in runs(candidates) {
                if let c = try trace(sat, body, from: run.lowerBound - 1, to: run.upperBound + 1) { found.append(c) }
            }
        }
        return found
    }

    /// Consecutive seconds grouped into runs.
    func runs(_ dates: [Date]) -> [ClosedRange<Date>] {
        var out: [ClosedRange<Date>] = []
        for d in dates {
            if let last = out.last, d.timeIntervalSince(last.upperBound) <= 2 {
                out[out.count - 1] = last.lowerBound...d
            } else {
                out.append(d...d)
            }
        }
        return out
    }

    /// The band between two times, kept within twice the radius; an event if it comes within the radius.
    func trace(_ sat: SatelliteTarget, _ body: SolarSystemBody, from: Date, to: Date) throws -> Conjunction? {
        var path: [ConjunctionPathPoint] = []
        var t = from
        while t <= to {
            if let p = try shadow(of: sat, on: body, at: t), Geodesy.distance(p.centre, centre) <= 2 * radius {
                path.append(p)
            }
            t += 0.05
        }
        guard let coarse = path.min(by: { Geodesy.distance($0.centre, centre) < Geodesy.distance($1.centre, centre) }) else {
            return nil
        }
        // Refine the closest approach between the neighbouring samples.
        var lo = coarse.date - 0.05, hi = coarse.date + 0.05
        func gap(_ d: Date) throws -> Double {
            guard let p = try shadow(of: sat, on: body, at: d) else { return .infinity }
            return Geodesy.distance(p.centre, centre)
        }
        for _ in 0..<30 {
            let a = lo + hi.timeIntervalSince(lo) / 3, b = hi - hi.timeIntervalSince(lo) / 3
            if try gap(a) < gap(b) { hi = b } else { lo = a }
        }
        let when = lo + hi.timeIntervalSince(lo) / 2
        guard let best = try shadow(of: sat, on: body, at: when) else { return nil }
        let distance = Geodesy.distance(best.centre, centre)
        guard distance <= radius else { return nil }

        let width = (best.left != nil && best.right != nil) ? Geodesy.distance(best.left!, best.right!) : 0
        let site = best.centre.observer
        let m = body.earthFixedPosition(at: time(when))
        let look = site.horizontal(ofEarthFixed: m)
        let range = (try satellitePosition(sat, when) - site.position).length
        return Conjunction(satelliteName: sat.name, noradID: sat.noradID, body: body, closest: when,
                           closestPoint: best.centre, distance: distance,
                           bearing: Geodesy.bearing(from: centre, to: best.centre), width: width,
                           duration: try crossingTime(sat, body, at: when, from: site),
                           bodyAltitude: look.altitude, bodyAzimuth: look.azimuth, satelliteRange: range,
                           illumination: body == .moon ? Self.moonIllumination(at: time(when)) : nil,
                           elementEpoch: sat.epoch, centre: centre, radius: radius, path: path)
    }

    /// Seconds for the satellite to cross the disc's diameter, seen from `site`.
    func crossingTime(_ sat: SatelliteTarget, _ body: SolarSystemBody, at date: Date, from site: Observer) throws -> TimeInterval {
        func offset(_ d: Date) throws -> Vec3 {
            (try satellitePosition(sat, d) - site.position).normalized - (body.earthFixedPosition(at: time(d)) - site.position).normalized
        }
        let h = 0.25
        let rate = (try offset(date + h) - offset(date - h)).length / (2 * h)
        let toBody = body.earthFixedPosition(at: time(date)) - site.position
        let diameter = 2 * asin(Self.physicalRadius(body) / toBody.length)
        return rate > 0 ? diameter / rate : 0
    }

    /// Lit fraction of the Moon's disc, from the Sun–Moon elongation.
    public static func moonIllumination(at time: AstroTime) -> Double {
        let elongation = angularSeparation(SolarSystemBody.moon.earthFixedPosition(at: time),
                                           SolarSystemBody.sun.earthFixedPosition(at: time))
        return (1 + cos((180 - elongation).radians)) / 2
    }

    /// The same event recalculated (normally with a newer element set), searching ±30 min.
    public func recalculate(_ event: Conjunction, with sat: SatelliteTarget) async -> Conjunction? {
        var finder = self
        finder.bodies = [event.body]
        return await finder.find([sat], from: event.closest - 1800, to: event.closest + 1800)
            .min { abs($0.closest.timeIntervalSince(event.closest)) < abs($1.closest.timeIntervalSince(event.closest)) }
    }
}
