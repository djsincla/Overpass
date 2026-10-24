import SkyKit
import SwiftUI

/// The whole sky as seen looking up: zenith in the centre, horizon at the edge, north at the top
/// and east on the left (as on a star chart held overhead).
struct SkyDome: View {
    let observer: Observer
    let date: Date
    var pass: SatellitePass?
    var plan: MountPlan?
    var tolerance: Double = 0.1
    var cableStopAzimuth: Double?
    /// Selected objects that are up; drawn prominently and tappable.
    var liveObjects: [LiveObject] = []
    var highlightedObjectID: String?
    /// The locked tracking target, ringed in green.
    var targetObjectID: String?
    /// Where the scope is pointing.
    var scopePosition: Horizontal?
    var onTapObject: ((String) -> Void)?

    var body: some View {
        GeometryReader { proxy in
            let geometry = DomeGeometry(size: proxy.size)
            Canvas { context, _ in
                drawBackground(&context, geometry)
                if let az = cableStopAzimuth { drawCableStop(&context, geometry, az) }
                drawStars(&context, geometry)
                drawSolarSystem(&context, geometry)
                if let pass {
                    drawPass(&context, geometry, pass)
                    drawLegend(&context, proxy.size)
                }
                drawLiveObjects(&context, geometry)
                if let scopePosition { drawScope(&context, geometry, scopePosition) }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { tap in
                guard let onTapObject else { return }
                let nearest = liveObjects.min {
                    distance(geometry.point($0.position), tap.location) < distance(geometry.point($1.position), tap.location)
                }
                if let nearest, distance(geometry.point(nearest.position), tap.location) < 30 { onTapObject(nearest.id) }
            })
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(accessibilitySummary)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    var accessibilitySummary: String {
        var parts = ["Sky chart"]
        if let pass {
            parts.append("\(pass.name) rising at azimuth \(Int(pass.start.position.azimuth)) degrees, peaking at \(Int(pass.maxAltitude)) degrees")
        }
        if !liveObjects.isEmpty { parts.append("Up now: " + liveObjects.map(\.name).joined(separator: ", ")) }
        return parts.joined(separator: ". ")
    }

    // MARK: Layers

    private func drawBackground(_ context: inout GraphicsContext, _ g: DomeGeometry) {
        let horizon = Path(ellipseIn: g.rect(altitude: 0))
        context.fill(horizon, with: .radialGradient(Gradient(colors: [Color(red: 0.05, green: 0.07, blue: 0.16),
                                                                     Color(red: 0.10, green: 0.13, blue: 0.26)]),
                                                     center: g.center, startRadius: 0, endRadius: g.radius))
        context.stroke(horizon, with: .color(.white.opacity(0.6)), lineWidth: 1.5)
        for altitude in [30.0, 60.0] {
            context.stroke(Path(ellipseIn: g.rect(altitude: altitude)), with: .color(.white.opacity(0.18)),
                           style: StrokeStyle(lineWidth: 0.75, dash: [3, 4]))
        }
        for (label, az) in [("N", 0.0), ("E", 90.0), ("S", 180.0), ("W", 270.0)] {
            context.draw(Text(label).font(.caption.bold()).foregroundStyle(.secondary), at: g.point(azimuth: az, altitude: -5))
        }
    }

    private func drawCableStop(_ context: inout GraphicsContext, _ g: DomeGeometry, _ azimuth: Double) {
        var path = Path()
        path.move(to: g.point(azimuth: azimuth, altitude: 90))
        path.addLine(to: g.point(azimuth: azimuth, altitude: 0))
        context.stroke(path, with: .color(.red.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
    }

    private func drawStars(_ context: inout GraphicsContext, _ g: DomeGeometry) {
        let time = AstroTime(date)
        for star in BrightStars.all {
            let h = observer.horizontal(ofEarthFixed: star.earthFixedPosition(at: time))
            guard h.altitude > 0 else { continue }
            let size = max(1.5, 4 - star.magnitude)
            let p = g.point(h)
            context.fill(Path(ellipseIn: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)),
                         with: .color(.white.opacity(0.7)))
        }
    }

    private func drawSolarSystem(_ context: inout GraphicsContext, _ g: DomeGeometry) {
        let time = AstroTime(date)
        for body in SolarSystemBody.allCases {
            let h = observer.horizontal(ofEarthFixed: body.earthFixedPosition(at: time))
            guard h.altitude > 0 else { continue }
            let p = g.point(h)
            let (size, color): (CGFloat, Color) = switch body {
            case .sun: (14, .yellow)
            case .moon: (12, Color(white: 0.85))
            default: (6, .orange)
            }
            context.fill(Path(ellipseIn: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)),
                         with: .color(color))
            context.draw(Text(body.name).font(.caption2).foregroundStyle(color.opacity(0.8)),
                         at: CGPoint(x: p.x, y: p.y + size / 2 + 7))
        }
    }

    private func drawPass(_ context: inout GraphicsContext, _ g: DomeGeometry, _ pass: SatellitePass) {
        let track = pass.track
        guard track.count > 1 else { return }

        // Solid where the satellite is sunlit; dashed grey in the Earth's shadow.
        for (a, b) in zip(track, track.dropFirst()) {
            var segment = Path()
            segment.move(to: g.point(a.position))
            segment.addLine(to: g.point(b.position))
            if a.sunlit {
                context.stroke(segment, with: .color(.cyan), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            } else {
                // Still clearly visible against the night sky: the pass doesn't stop, it's just unlit.
                context.stroke(segment, with: .color(.white.opacity(0.75)), style: StrokeStyle(lineWidth: 2.5, dash: [6, 4]))
            }
        }

        // Where it enters or leaves the shadow, with the time.
        for (a, b) in zip(track, track.dropFirst()) where a.sunlit != b.sunlit {
            let p = g.point(b.position)
            let marker = Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12))
            context.fill(marker, with: .color(.black))
            var half = Path()
            half.addArc(center: p, radius: 6, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
            context.fill(half, with: .color(.cyan))
            context.stroke(marker, with: .color(.white), lineWidth: 1.5)
            let label = b.sunlit ? "lit" : "shadow"
            context.draw(Text("\(label) \(b.date.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2).foregroundStyle(.white.opacity(0.85)),
                         at: CGPoint(x: p.x, y: p.y + 14))
        }

        // Where the mount will lose the target, cutting round the zenith.
        if let plan {
            for (sample, point) in zip(plan.samples, track) where sample.error > tolerance {
                let p = g.point(point.position)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.red))
            }
        }

        // Ticks every minute on short passes, spaced out on long ones (high orbits take hours).
        let tick = pass.duration < 1200 ? 60 : pass.duration < 7200 ? 300 : 900
        for sample in track.dropFirst() where Int(sample.date.timeIntervalSince(track[0].date)) % tick == 0 {
            let p = g.point(sample.position)
            context.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)), with: .color(.white))
        }

        let start = g.point(pass.start.position)
        context.stroke(Path(ellipseIn: CGRect(x: start.x - 5, y: start.y - 5, width: 10, height: 10)),
                       with: .color(.green), lineWidth: 2)
        context.draw(Text(pass.start.date, style: .time).font(.caption2).foregroundStyle(.green),
                     at: CGPoint(x: start.x, y: start.y - 12))

        drawArrowhead(&context, g, from: track[track.count - 2].position, to: pass.end.position)
        let peak = g.point(pass.culmination.position)
        context.draw(Text("\(Int(pass.maxAltitude.rounded()))°").font(.caption2.bold()).foregroundStyle(.white),
                     at: CGPoint(x: peak.x + 14, y: peak.y))
    }

    private func drawLiveObjects(_ context: inout GraphicsContext, _ g: DomeGeometry) {
        for object in liveObjects {
            let p = g.point(object.position)
            let highlighted = object.id == highlightedObjectID
            let color: Color = object.sunlit ? .yellow : .gray
            var diamond = Path()
            diamond.move(to: CGPoint(x: p.x, y: p.y - 5))
            diamond.addLine(to: CGPoint(x: p.x + 5, y: p.y))
            diamond.addLine(to: CGPoint(x: p.x, y: p.y + 5))
            diamond.addLine(to: CGPoint(x: p.x - 5, y: p.y))
            diamond.closeSubpath()
            context.fill(diamond, with: .color(color))
            if highlighted {
                context.stroke(Path(ellipseIn: CGRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22)),
                               with: .color(.yellow), lineWidth: 2)
            }
            if object.id == targetObjectID {
                context.stroke(Path(ellipseIn: CGRect(x: p.x - 16, y: p.y - 16, width: 32, height: 32)),
                               with: .color(.green), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
            context.draw(Text(object.name).font(highlighted ? .caption.bold() : .caption2).foregroundStyle(color),
                         at: CGPoint(x: p.x, y: p.y + 14))
        }
    }

    private func drawScope(_ context: inout GraphicsContext, _ g: DomeGeometry, _ h: Horizontal) {
        let p = g.point(h)
        var cross = Path()
        cross.move(to: CGPoint(x: p.x - 12, y: p.y))
        cross.addLine(to: CGPoint(x: p.x - 4, y: p.y))
        cross.move(to: CGPoint(x: p.x + 4, y: p.y))
        cross.addLine(to: CGPoint(x: p.x + 12, y: p.y))
        cross.move(to: CGPoint(x: p.x, y: p.y - 12))
        cross.addLine(to: CGPoint(x: p.x, y: p.y - 4))
        cross.move(to: CGPoint(x: p.x, y: p.y + 4))
        cross.addLine(to: CGPoint(x: p.x, y: p.y + 12))
        context.stroke(cross, with: .color(.red), lineWidth: 2)
        context.stroke(Path(ellipseIn: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)),
                       with: .color(.red), lineWidth: 1.5)
    }

    private func drawLegend(_ context: inout GraphicsContext, _ size: CGSize) {
        let x: CGFloat = 8, y = size.height - 30
        var lit = Path()
        lit.move(to: CGPoint(x: x, y: y))
        lit.addLine(to: CGPoint(x: x + 22, y: y))
        context.stroke(lit, with: .color(.cyan), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        context.draw(Text("Sunlit").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: x + 30, y: y), anchor: .leading)
        var dark = Path()
        dark.move(to: CGPoint(x: x, y: y + 16))
        dark.addLine(to: CGPoint(x: x + 22, y: y + 16))
        context.stroke(dark, with: .color(.white.opacity(0.75)), style: StrokeStyle(lineWidth: 2.5, dash: [6, 4]))
        context.draw(Text("Eclipsed").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: x + 30, y: y + 16), anchor: .leading)
    }

    private func drawArrowhead(_ context: inout GraphicsContext, _ g: DomeGeometry, from: Horizontal, to: Horizontal) {
        let a = g.point(from), b = g.point(to)
        let angle = atan2(b.y - a.y, b.x - a.x)
        var head = Path()
        head.move(to: b)
        head.addLine(to: CGPoint(x: b.x - 10 * cos(angle - 0.45), y: b.y - 10 * sin(angle - 0.45)))
        head.move(to: b)
        head.addLine(to: CGPoint(x: b.x - 10 * cos(angle + 0.45), y: b.y - 10 * sin(angle + 0.45)))
        context.stroke(head, with: .color(.cyan), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
    }
}

/// Maps azimuth/altitude to the dome: linear in zenith distance.
struct DomeGeometry {
    let center: CGPoint
    let radius: CGFloat

    init(size: CGSize) {
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        // Room outside the horizon for the N/E/S/W labels.
        radius = min(size.width, size.height) / 2 - 30
    }

    func point(azimuth: Double, altitude: Double) -> CGPoint {
        let r = radius * (90 - altitude) / 90
        let az = azimuth * .pi / 180
        // North up, east left.
        return CGPoint(x: center.x - r * sin(az), y: center.y - r * cos(az))
    }

    func point(_ h: Horizontal) -> CGPoint { point(azimuth: h.azimuth, altitude: max(h.altitude, 0)) }

    func rect(altitude: Double) -> CGRect {
        let r = radius * (90 - altitude) / 90
        return CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
    }
}

struct LocationNeededView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Where are you?", systemImage: "location")
        } description: {
            Text("Overpass needs your location to work out what's in your sky.")
        } actions: {
            Button("Use my current location") { Task { await model.useCurrentLocation() } }
                .buttonStyle(.borderedProminent)
            Text("Or enter it in Settings.").font(.footnote).foregroundStyle(.secondary)
        }
    }
}
