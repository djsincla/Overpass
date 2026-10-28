import Accelerate
import Foundation

/// Something followed in the camera image from frame to frame, whichever way it's found.
public protocol ImageTracker: Sendable {
    /// Where it is, frame pixels.
    var x: Double { get }
    var y: Double { get }
    /// Its own motion, pixels per second, as it would look with the mount still.
    var vx: Double { get }
    var vy: Double { get }
    var state: MovingObjectTracker.State { get }
    /// Frames it has been found in.
    var hits: Int { get }
    var hasVelocity: Bool { get }
    /// How far from the predicted position the last search looked.
    var searchRadius: Double { get }
    var coastLimit: TimeInterval { get }
    /// The size of the box drawn around it, frame pixels.
    var size: (width: Double, height: Double) { get }
    /// Searches the next frame; `mountShift` is how far the mount's own motion moved the image.
    /// Returns whether it was found.
    mutating func follow(_ frame: GrayFrame, mountShift: (x: Double, y: Double)) -> Bool
}

extension MovingObjectTracker: ImageTracker {
    public var size: (width: Double, height: Double) {
        let side = 2 * Double(blob.area).squareRoot()
        return (side, side)
    }

    public mutating func follow(_ frame: GrayFrame, mountShift: (x: Double, y: Double)) -> Bool {
        update(frame, mountShift: mountShift) != nil
    }
}

/// Follows a patch of the picture by its look: a boat on the water, a bird against trees, a car
/// or a person. `MovingObjectTracker` finds a compact spot that stands out from plain sky, which
/// none of those are; this matches the patch itself, by normalised cross-correlation, so it
/// works against any background.
///
/// The match is searched coarsely first, over a reduced copy of the search area, then refined
/// at full resolution to a fraction of a pixel. The patch kept for matching drifts slowly toward
/// what it sees, so a bird flapping or a boat turning stays matched.
public struct PatchTracker: ImageTracker {
    public private(set) var x: Double
    public private(set) var y: Double
    public private(set) var vx = 0.0
    public private(set) var vy = 0.0
    public private(set) var state = MovingObjectTracker.State.locked
    public private(set) var hits = 1
    public private(set) var lastSeen: Date
    public private(set) var searchRadius: Double
    /// The last match's correlation, 1 for a perfect match.
    public private(set) var score = 1.0
    public var coastLimit: TimeInterval = 2
    /// Below this the best match isn't taken to be the object.
    public var minimumScore = 0.6

    /// The patch, in pixels.
    public let width: Int
    public let height: Int
    private var template: [Float]
    private var time: Date
    private var seen: (x: Double, y: Double)
    private var shiftSinceSeen = (x: 0.0, y: 0.0)

    public var size: (width: Double, height: Double) { (Double(width), Double(height)) }
    public var hasVelocity: Bool { hits >= 3 }

    /// Takes the patch of `frame` centred on `centre`, `width` by `height` pixels, kept inside
    /// the frame. Nil if it's too small or too flat to match (a patch of clear sky).
    public init?(frame: GrayFrame, centre: (x: Double, y: Double), width: Int, height: Int) {
        let w = min(width, frame.width), h = min(height, frame.height)
        guard w >= 8, h >= 8 else { return nil }
        let left = min(max(Int((centre.x - Double(w - 1) / 2).rounded()), 0), frame.width - w)
        let top = min(max(Int((centre.y - Double(h - 1) / 2).rounded()), 0), frame.height - h)
        let patch = Self.patch(frame, left, top, w, h)
        var mean: Float = 0, deviation: Float = 0
        vDSP_normalize(patch, 1, nil, 1, &mean, &deviation, vDSP_Length(patch.count))
        guard deviation >= 3 else { return nil }
        self.width = w
        self.height = h
        template = patch
        x = Double(left) + Double(w - 1) / 2
        y = Double(top) + Double(h - 1) / 2
        seen = (x, y)
        time = frame.timestamp
        lastSeen = frame.timestamp
        searchRadius = 0
    }

    @discardableResult
    public mutating func follow(_ frame: GrayFrame, mountShift: (x: Double, y: Double) = (0, 0)) -> Bool {
        let dt = frame.timestamp.timeIntervalSince(time)
        guard dt > 0 else { return false }
        let predicted = (x: x + vx * dt + mountShift.x, y: y + vy * dt + mountShift.y)
        let unseen = frame.timestamp.timeIntervalSince(lastSeen)
        searchRadius = max(12, 0.4 * Double(max(width, height))) + 0.3 * hypot(vx, vy) * dt + 40 * min(unseen, coastLimit)
        if !hasVelocity { searchRadius = max(searchRadius, 40) }
        time = frame.timestamp
        shiftSinceSeen.x += mountShift.x
        shiftSinceSeen.y += mountShift.y

        let found = Self.match(template, width, height, in: frame, around: predicted, radius: searchRadius)
        score = found?.score ?? 0
        guard let found, found.score >= minimumScore else {
            x = predicted.x
            y = predicted.y
            state = unseen > coastLimit ? .lost : .coasting
            return false
        }

        let span = frame.timestamp.timeIntervalSince(lastSeen)
        if hasVelocity {
            let rx = found.x - predicted.x, ry = found.y - predicted.y
            x = predicted.x + 0.85 * rx
            y = predicted.y + 0.85 * ry
            vx += 0.4 * rx / span
            vy += 0.4 * ry / span
        } else {
            vx = (found.x - seen.x - shiftSinceSeen.x) / span
            vy = (found.y - seen.y - shiftSinceSeen.y) / span
            x = found.x
            y = found.y
        }
        // A good match teaches the patch a little of how the object looks now.
        if found.score > 0.8 {
            let left = Int((found.x - Double(width - 1) / 2).rounded()), top = Int((found.y - Double(height - 1) / 2).rounded())
            if left >= 0, top >= 0, left + width <= frame.width, top + height <= frame.height {
                let now = Self.patch(frame, left, top, width, height)
                let old = template
                vDSP_vintb(old, 1, now, 1, [Float(0.1)], &template, 1, vDSP_Length(old.count))
            }
        }
        seen = (x, y)
        shiftSinceSeen = (0, 0)
        hits += 1
        lastSeen = frame.timestamp
        state = .locked
        return true
    }

    // MARK: Matching

    /// The best match for `template` (`tw` × `th`) whose centre lies within `radius` of `around`:
    /// its centre, to a fraction of a pixel, and its correlation.
    static func match(_ template: [Float], _ tw: Int, _ th: Int, in frame: GrayFrame,
                      around: (x: Double, y: Double), radius: Double) -> (x: Double, y: Double, score: Double)? {
        // The search area: every top-left corner whose patch centre is within the radius.
        let x0 = max(0, Int((around.x - Double(tw - 1) / 2 - radius).rounded(.down)))
        let y0 = max(0, Int((around.y - Double(th - 1) / 2 - radius).rounded(.down)))
        let x1 = min(frame.width - tw, Int((around.x - Double(tw - 1) / 2 + radius).rounded(.up)))
        let y1 = min(frame.height - th, Int((around.y - Double(th - 1) / 2 + radius).rounded(.up)))
        guard x0 <= x1, y0 <= y1 else { return nil }

        // Coarse: both reduced so the patch's shorter side is about ten pixels.
        let f = max(1, min(tw, th) / 10)
        var best = (x: x0, y: y0)
        if f > 1 {
            let ctw = tw / f, cth = th / f
            let small = Self.reduce(template, tw, th, f)
            let areaW = (x1 - x0 + tw) / f, areaH = (y1 - y0 + th) / f
            let area = Self.reduce(Self.patch(frame, x0, y0, areaW * f, areaH * f), areaW * f, areaH * f, f)
            guard let coarse = Self.correlate(small, ctw, cth, area, areaW, areaH, positions: 0...(areaW - ctw), 0...(areaH - cth)) else { return nil }
            best = (x0 + coarse.u * f, y0 + coarse.v * f)
        }

        // Fine: full resolution, around the coarse answer (or over the whole area when there was none).
        let us = f > 1 ? max(x0, best.x - f)...min(x1, best.x + f) : x0...x1
        let vs = f > 1 ? max(y0, best.y - f)...min(y1, best.y + f) : y0...y1
        let areaW = us.count + tw - 1, areaH = vs.count + th - 1
        let area = Self.patch(frame, us.lowerBound, vs.lowerBound, areaW, areaH)
        guard let fine = Self.correlate(template, tw, th, area, areaW, areaH, positions: 0...(us.count - 1), 0...(vs.count - 1)) else { return nil }

        // A parabola through the peak and its neighbours puts it between pixels.
        func offset(_ minus: Float?, _ peak: Float, _ plus: Float?) -> Double {
            guard let minus, let plus else { return 0 }
            let d = minus - 2 * peak + plus
            return d < 0 ? Double(max(-0.5, min(0.5, 0.5 * (minus - plus) / d))) : 0
        }
        let dx = offset(fine.at(fine.u - 1, fine.v), fine.score, fine.at(fine.u + 1, fine.v))
        let dy = offset(fine.at(fine.u, fine.v - 1), fine.score, fine.at(fine.u, fine.v + 1))
        return (Double(us.lowerBound + fine.u) + dx + Double(tw - 1) / 2,
                Double(vs.lowerBound + fine.v) + dy + Double(th - 1) / 2, Double(fine.score))
    }

    struct Scores {
        let u: Int, v: Int, score: Float
        let values: [Float], columns: Int, rows: Int
        func at(_ u: Int, _ v: Int) -> Float? {
            guard u >= 0, v >= 0, u < columns, v < rows else { return nil }
            return values[v * columns + u]
        }
    }

    /// Normalised cross-correlation of the template at each top-left position in `area`.
    static func correlate(_ template: [Float], _ tw: Int, _ th: Int, _ area: [Float], _ aw: Int, _ ah: Int,
                          positions us: ClosedRange<Int>, _ vs: ClosedRange<Int>) -> Scores? {
        let n = Float(tw * th)
        var mean: Float = 0
        vDSP_meanv(template, 1, &mean, vDSP_Length(template.count))
        var t = [Float](repeating: 0, count: template.count)
        vDSP_vsadd(template, 1, [-mean], &t, 1, vDSP_Length(t.count))
        var tt: Float = 0
        vDSP_svesq(t, 1, &tt, vDSP_Length(t.count))
        guard tt > 0, us.upperBound + tw <= aw, vs.upperBound + th <= ah else { return nil }

        // Sums and sums of squares over any window, from integral images.
        let iw = aw + 1
        var sum = [Double](repeating: 0, count: iw * (ah + 1)), squares = sum
        for row in 0..<ah {
            var s = 0.0, q = 0.0
            for column in 0..<aw {
                let v = Double(area[row * aw + column])
                s += v
                q += v * v
                sum[(row + 1) * iw + column + 1] = sum[row * iw + column + 1] + s
                squares[(row + 1) * iw + column + 1] = squares[row * iw + column + 1] + q
            }
        }
        func window(_ table: [Double], _ u: Int, _ v: Int) -> Double {
            table[(v + th) * iw + u + tw] - table[v * iw + u + tw] - table[(v + th) * iw + u] + table[v * iw + u]
        }

        var values = [Float](repeating: -1, count: us.count * vs.count)
        var best = (u: 0, v: 0, score: -Float.infinity)
        area.withUnsafeBufferPointer { a in
            t.withUnsafeBufferPointer { tp in
                for v in vs {
                    for u in us {
                        var cross: Float = 0
                        for row in 0..<th {
                            var d: Float = 0
                            vDSP_dotpr(tp.baseAddress! + row * tw, 1, a.baseAddress! + (v + row) * aw + u, 1, &d, vDSP_Length(tw))
                            cross += d
                        }
                        let s = window(sum, u, v)
                        let variance = window(squares, u, v) - s * s / Double(n)
                        // A flat window can't match a patch with detail in it.
                        let score = variance > 1e-3 ? cross / Float((variance * Double(tt)).squareRoot()) : 0
                        values[(v - vs.lowerBound) * us.count + u - us.lowerBound] = score
                        if score > best.score { best = (u - us.lowerBound, v - vs.lowerBound, score) }
                    }
                }
            }
        }
        return Scores(u: best.u, v: best.v, score: best.score, values: values, columns: us.count, rows: vs.count)
    }

    /// The pixels of a rectangle of the frame, as floats.
    static func patch(_ frame: GrayFrame, _ left: Int, _ top: Int, _ w: Int, _ h: Int) -> [Float] {
        var out = [Float](repeating: 0, count: w * h)
        frame.pixels.withUnsafeBufferPointer { p in
            out.withUnsafeMutableBufferPointer { o in
                for row in 0..<h {
                    vDSP_vfltu8(p.baseAddress! + (top + row) * frame.width + left, 1, o.baseAddress! + row * w, 1, vDSP_Length(w))
                }
            }
        }
        return out
    }

    /// Averages `f` × `f` blocks.
    static func reduce(_ image: [Float], _ w: Int, _ h: Int, _ f: Int) -> [Float] {
        let rw = w / f, rh = h / f
        var out = [Float](repeating: 0, count: rw * rh)
        for row in 0..<(rh * f) {
            for column in 0..<(rw * f) { out[(row / f) * rw + column / f] += image[row * w + column] }
        }
        let scale = 1 / Float(f * f)
        return out.map { $0 * scale }
    }
}
