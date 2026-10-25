import Foundation

/// A compact patch that stands out from the sky around it: a satellite or star (bright), or an
/// aircraft against a daytime sky (dark).
public struct Blob: Sendable, Equatable {
    /// Centroid, pixels.
    public let x: Double
    public let y: Double
    /// Strongest pixel's difference from the background, in units of the background noise.
    public let peak: Double
    /// Pixels above the threshold.
    public let area: Int
    /// +1 brighter than the background, −1 darker.
    public let polarity: Double
}

/// Finds blobs in a window of a frame, against that window's own background, so a sky that
/// brightens toward the horizon or the Sun doesn't matter.
public struct BlobFinder: Sendable {
    /// How far from the background a pixel must be, in noise units.
    public var threshold = 5.0
    /// And in grey levels, so compression noise in a flat sky (a noise level near zero)
    /// doesn't produce blobs.
    public var minimumDifference = 12.0
    /// Larger than this is a cloud edge, a tree or the ground, not something to track.
    public var maximumArea = 4000

    public init() {}

    /// Blobs whose centroid lies within `radius` of `centre`. `polarity` nil looks for both.
    public func blobs(in frame: GrayFrame, around centre: (x: Double, y: Double), radius: Double,
                      polarity: Double? = nil) -> [Blob] {
        // The window is a little larger than the search circle, so a blob near its edge is whole.
        let r = radius + 8
        let x0 = max(0, Int(centre.x - r)), x1 = min(frame.width - 1, Int(centre.x + r))
        let y0 = max(0, Int(centre.y - r)), y1 = min(frame.height - 1, Int(centre.y + r))
        guard x0 < x1, y0 < y1 else { return [] }
        let w = x1 - x0 + 1, h = y1 - y0 + 1

        let (background, noise) = Self.background(frame, x0, y0, w, h)
        let level = max(threshold * noise, minimumDifference)
        var found: [Blob] = []
        for sign in polarity.map({ [$0] }) ?? [1.0, -1.0] {
            var visited = [Bool](repeating: false, count: w * h)
            var stack: [Int] = []
            for wy in 0..<h {
                for wx in 0..<w {
                    let start = wy * w + wx
                    guard !visited[start], sign * (Double(frame[x0 + wx, y0 + wy]) - background) > level else { continue }
                    // Flood fill this blob (8-connected), weighting the centroid by brightness.
                    visited[start] = true
                    stack.append(start)
                    var sum = 0.0, sx = 0.0, sy = 0.0, peak = 0.0, area = 0
                    while let i = stack.popLast() {
                        let px = i % w, py = i / w
                        let d = sign * (Double(frame[x0 + px, y0 + py]) - background)
                        sum += d
                        sx += d * Double(x0 + px)
                        sy += d * Double(y0 + py)
                        peak = max(peak, d)
                        area += 1
                        for ny in max(0, py - 1)...min(h - 1, py + 1) {
                            for nx in max(0, px - 1)...min(w - 1, px + 1) {
                                let j = ny * w + nx
                                if !visited[j], sign * (Double(frame[x0 + nx, y0 + ny]) - background) > level {
                                    visited[j] = true
                                    stack.append(j)
                                }
                            }
                        }
                    }
                    guard area <= maximumArea, sum > 0 else { continue }
                    let blob = Blob(x: sx / sum, y: sy / sum, peak: peak / max(noise, 1), area: area, polarity: sign)
                    if hypot(blob.x - centre.x, blob.y - centre.y) <= radius { found.append(blob) }
                }
            }
        }
        return found
    }

    /// Median and a robust noise level (from the median absolute deviation) of a window.
    static func background(_ frame: GrayFrame, _ x0: Int, _ y0: Int, _ w: Int, _ h: Int) -> (Double, Double) {
        let step = max(1, Int((Double(w * h) / 4096).squareRoot()))
        var sample: [UInt8] = []
        sample.reserveCapacity((w / step + 1) * (h / step + 1))
        for y in stride(from: y0, to: y0 + h, by: step) {
            for x in stride(from: x0, to: x0 + w, by: step) { sample.append(frame[x, y]) }
        }
        sample.sort()
        let median = Double(sample[sample.count / 2])
        var deviations = sample.map { abs(Double($0) - median) }
        deviations.sort()
        return (median, 1.4826 * deviations[deviations.count / 2])
    }
}

/// Follows one object picked in the image from frame to frame.
///
/// Its velocity is the object's own motion in pixels per second, as it would look with the mount
/// still. The caller passes how far the mount's motion shifted the image since the last frame,
/// so the search follows the object even while the mount accelerates under it.
public struct MovingObjectTracker: Sendable {
    public enum State: Sendable, Equatable {
        /// Seen in the last frame.
        case locked
        /// Not seen lately; carrying on along the last known motion.
        case coasting
        /// Not seen for longer than `coastLimit`.
        case lost
    }

    public private(set) var x: Double
    public private(set) var y: Double
    public private(set) var vx = 0.0
    public private(set) var vy = 0.0
    public private(set) var state = State.locked
    /// Frames it has been found in.
    public private(set) var hits = 1
    public private(set) var lastSeen: Date
    public private(set) var blob: Blob
    /// How far from the predicted position the last search looked.
    public private(set) var searchRadius: Double
    public var finder: BlobFinder
    /// Seconds without a sighting before giving up.
    public var coastLimit: TimeInterval = 2

    private var time: Date
    /// Where it was last seen, and how far the mount has shifted the image since.
    private var seen: (x: Double, y: Double)
    private var shiftSinceSeen = (x: 0.0, y: 0.0)

    /// Picks the object nearest `point` within `radius`, or nil if nothing stands out there.
    public init?(frame: GrayFrame, at point: (x: Double, y: Double), radius: Double = 30, finder: BlobFinder = BlobFinder()) {
        let candidates = finder.blobs(in: frame, around: point, radius: radius)
        // Nearest wins, but a clearly stronger one a little further away beats a faint speck.
        guard let best = candidates.max(by: {
            Self.score($0, point, radius) < Self.score($1, point, radius)
        }) else { return nil }
        x = best.x
        y = best.y
        seen = (best.x, best.y)
        blob = best
        self.finder = finder
        time = frame.timestamp
        lastSeen = frame.timestamp
        searchRadius = radius
    }

    private static func score(_ blob: Blob, _ point: (x: Double, y: Double), _ radius: Double) -> Double {
        let d = hypot(blob.x - point.x, blob.y - point.y) / radius
        return min(blob.peak, 50) / (1 + 4 * d * d)
    }

    /// Whether the velocity has been measured over a few frames yet.
    public var hasVelocity: Bool { hits >= 3 }

    /// Searches the next frame. Returns the sighting, or nil if the object wasn't found.
    @discardableResult
    public mutating func update(_ frame: GrayFrame, mountShift: (x: Double, y: Double) = (0, 0)) -> Blob? {
        let dt = frame.timestamp.timeIntervalSince(time)
        guard dt > 0 else { return nil }
        let predicted = (x: x + vx * dt + mountShift.x, y: y + vy * dt + mountShift.y)
        let unseen = frame.timestamp.timeIntervalSince(lastSeen)
        // Wide enough for the blob itself, for the speed being a little off, and wider the longer
        // it's been out of sight.
        let size = Double(blob.area).squareRoot()
        searchRadius = max(16, 2 * size) + 0.3 * hypot(vx, vy) * dt + 40 * min(unseen, coastLimit)
        if !hasVelocity { searchRadius = max(searchRadius, 40) }

        let candidates = finder.blobs(in: frame, around: predicted, radius: searchRadius, polarity: blob.polarity)
        time = frame.timestamp
        shiftSinceSeen.x += mountShift.x
        shiftSinceSeen.y += mountShift.y
        guard let found = candidates.min(by: {
            hypot($0.x - predicted.x, $0.y - predicted.y) < hypot($1.x - predicted.x, $1.y - predicted.y)
        }) else {
            x = predicted.x
            y = predicted.y
            state = unseen > coastLimit ? .lost : .coasting
            return nil
        }

        let span = frame.timestamp.timeIntervalSince(lastSeen)
        if hasVelocity {
            // Alpha-beta filter: the centroid is precise, so trust it heavily; the velocity
            // follows the residual more gently.
            let rx = found.x - predicted.x, ry = found.y - predicted.y
            x = predicted.x + 0.85 * rx
            y = predicted.y + 0.85 * ry
            vx += 0.4 * rx / span
            vy += 0.4 * ry / span
        } else {
            // The first few frames: the velocity is simply how far it went, less what the mount did.
            vx = (found.x - seen.x - shiftSinceSeen.x) / span
            vy = (found.y - seen.y - shiftSinceSeen.y) / span
            x = found.x
            y = found.y
        }
        blob = found
        seen = (x, y)
        shiftSinceSeen = (0, 0)
        hits += 1
        lastSeen = frame.timestamp
        state = .locked
        return found
    }
}

/// The target's path in the mount's own axis coordinates, from recent sightings: a straight
/// line fitted over the last second, which smooths out pixel noise and frame timing.
public struct MotionEstimator: Sendable {
    public struct Estimate: Sendable, Equatable {
        public var position: AxisPosition
        /// Degrees per second.
        public var primaryRate: Double
        public var secondaryRate: Double
        /// When the target was last seen.
        public var latest: Date
    }

    /// Seconds of sightings to fit.
    public var span: TimeInterval = 1
    private var samples: [(t: Date, p: Double, s: Double)] = []

    public init() {}

    public var latest: Date? { samples.last?.t }
    public var count: Int { samples.count }

    public mutating func add(_ position: AxisPosition, at date: Date) {
        if let last = samples.last, date <= last.t { return }
        samples.append((date, position.primary, position.secondary))
        samples.removeFirst(samples.prefix { date.timeIntervalSince($0.t) > span }.count)
    }

    public mutating func reset() { samples = [] }

    /// Where the target is at `date`, extrapolating from the fit. Nil until there are enough
    /// sightings over enough time to give a speed.
    public func estimate(at date: Date) -> Estimate? {
        guard samples.count >= 3, let first = samples.first, let last = samples.last,
              last.t.timeIntervalSince(first.t) >= 0.15 else { return nil }
        let ts = samples.map { $0.t.timeIntervalSince(last.t) }
        let n = Double(ts.count)
        let mt = ts.reduce(0, +) / n
        let stt = ts.reduce(0) { $0 + ($1 - mt) * ($1 - mt) }
        guard stt > 0 else { return nil }
        func fit(_ values: [Double]) -> (at: Double, rate: Double) {
            let mv = values.reduce(0, +) / n
            let rate = zip(ts, values).reduce(0) { $0 + ($1.0 - mt) * ($1.1 - mv) } / stt
            return (mv + rate * (date.timeIntervalSince(last.t) - mt), rate)
        }
        let p = fit(samples.map(\.p)), s = fit(samples.map(\.s))
        return Estimate(position: AxisPosition(primary: p.at, secondary: s.at),
                        primaryRate: p.rate, secondaryRate: s.rate, latest: last.t)
    }
}
