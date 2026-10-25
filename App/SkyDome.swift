import SkyKit
import SwiftUI

/// The whole sky as seen looking up: zenith in the centre, horizon at the edge, north at the top
/// and east on the left (as on a star chart held overhead). It can be spun (drag, or rotate on a
/// trackpad) and flipped east–west, to match how you're facing or a camera's view.
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
    /// Right-click (long press on touch) menu for an object on the dome, by id.
    var menu: ((String) -> AnyView)?
    /// The object under the pointer, so a right-click acts on it.
    @State private var hoveredID: String?
    /// The azimuth at the top, degrees; shared by every dome and kept between launches.
    @AppStorage("dome.rotation") private var rotation = 0.0
    /// East on the right instead of the left.
    @AppStorage("dome.flipped") private var flipped = false
    /// Rotation and pointer angle when a drag began.
    @State private var dragStart: (rotation: Double, angle: Double)?
    @State private var twistStart: Double?

    var body: some View {
        GeometryReader { proxy in
            let geometry = DomeGeometry(size: proxy.size, rotation: rotation, flipped: flipped)
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
                if let hoveredID, let hovered = pickable(geometry).first(where: { $0.id == hoveredID }) {
                    let p = hovered.point
                    context.stroke(Path(ellipseIn: CGRect(x: p.x - 13, y: p.y - 13, width: 26, height: 26)),
                                   with: .color(.white.opacity(0.55)), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { tap in
                if let id = nearest(to: tap.location, geometry) { onTapObject?(id) }
            })
            .simultaneousGesture(spin(geometry))
            .simultaneousGesture(twist)
            .overlay(alignment: .topTrailing) { controls }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let id = nearest(to: location, geometry)
                    if id != hoveredID { hoveredID = id }
                case .ended:
                    hoveredID = nil
                }
            }
            .contextMenu {
                if let menu, let id = hoveredID ?? highlightedObjectID { menu(id) }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(accessibilitySummary)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    // MARK: Spinning and flipping

    /// Dragging turns the sky about the zenith, keeping the point under the pointer under it.
    private func spin(_ g: DomeGeometry) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { drag in
                let angle = atan2(drag.location.y - g.center.y, drag.location.x - g.center.x) * 180 / .pi
                if dragStart == nil {
                    let start = atan2(drag.startLocation.y - g.center.y, drag.startLocation.x - g.center.x) * 180 / .pi
                    dragStart = (rotation, Double(start))
                }
                guard let dragStart else { return }
                // On screen, azimuth runs anticlockwise (east left) or clockwise when flipped.
                let turn = Double(angle) - dragStart.angle
                rotation = normalized(dragStart.rotation + (flipped ? -turn : turn))
            }
            .onEnded { _ in
                dragStart = nil
                rotation = snapped(rotation)
            }
    }

    /// Two-finger rotation on a trackpad.
    private var twist: some Gesture {
        RotateGesture()
            .onChanged { value in
                if twistStart == nil { twistStart = rotation }
                let turn = value.rotation.degrees
                rotation = normalized((twistStart ?? rotation) + (flipped ? -turn : turn))
            }
            .onEnded { _ in
                twistStart = nil
                rotation = snapped(rotation)
            }
    }

    private func normalized(_ degrees: Double) -> Double {
        let d = degrees.truncatingRemainder(dividingBy: 360)
        return d < 0 ? d + 360 : d
    }

    /// Within 3° of N, E, S or W, settle on it.
    private func snapped(_ degrees: Double) -> Double {
        let nearest = (degrees / 90).rounded() * 90
        return abs(degrees - nearest) < 3 ? normalized(nearest) : degrees
    }

    private var controls: some View {
        HStack(spacing: 6) {
            if rotation != 0 {
                Button { withAnimation(.easeInOut(duration: 0.3)) { rotation = 0 } } label: {
                    Label("\(compassName(rotation)) up", systemImage: "location.north.line")
                        .labelStyle(.titleAndIcon)
                }
                .help("Put north back at the top")
                .accessibilityLabel("Reset rotation, \(Int(rotation.rounded())) degrees at the top")
            }
            Button { flipped.toggle() } label: {
                Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }
            .help(flipped ? "East on the left again (looking up)" : "Flip east and west (as seen from above, or through a mirror diagonal)")
            .accessibilityLabel(flipped ? "Unflip east and west" : "Flip east and west")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(8)
    }

    private func compassName(_ azimuth: Double) -> String {
        let names = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        return names[Int((azimuth / 22.5).rounded()) % 16] + " \(Int(azimuth.rounded()))°"
    }

    /// Everything drawn that can be clicked: selected objects, and the stars, Sun, Moon and
    /// planets above the horizon. Selected ones come first, so they win a tie.
    private func pickable(_ g: DomeGeometry) -> [(id: String, point: CGPoint)] {
        let time = AstroTime(date)
        var items = liveObjects.map { ($0.id, g.point($0.position)) }
        for body in SolarSystemBody.allCases {
            let h = observer.horizontal(ofEarthFixed: body.earthFixedPosition(at: time))
            if h.altitude > 0 { items.append(("body:\(body.rawValue)", g.point(h))) }
        }
        for star in BrightStars.all {
            let h = observer.horizontal(ofEarthFixed: star.earthFixedPosition(at: time))
            if h.altitude > 0 { items.append(("star:\(star.name)", g.point(h))) }
        }
        var seen = Set<String>()
        return items.filter { seen.insert($0.0).inserted }.map { (id: $0.0, point: $0.1) }
    }

    /// The object within 30 points of `location`, nearest first.
    private func nearest(to location: CGPoint, _ g: DomeGeometry) -> String? {
        pickable(g).filter { distance($0.point, location) < 30 }
            .min { distance($0.point, location) < distance($1.point, location) }?.id
    }

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
            // Above the marker when it's close to the start, whose time sits above the start ring.
            let nearStart = distance(p, g.point(pass.start.position)) < 40
            context.draw(Text("\(label) \(b.date.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2).foregroundStyle(.white.opacity(0.85)),
                         at: CGPoint(x: p.x + (nearStart ? -34 : 0), y: p.y + (nearStart ? -14 : 14)))
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

    /// Objects drawn as one: within a few pixels of each other, like the modules of a space
    /// station. The highlighted or target object, if any, leads the group.
    private func clusters(_ g: DomeGeometry) -> [(lead: LiveObject, others: [LiveObject])] {
        var groups: [[LiveObject]] = []
        for object in liveObjects {
            let p = g.point(object.position)
            if let i = groups.firstIndex(where: { distance(g.point($0[0].position), p) < 6 }) {
                groups[i].append(object)
            } else {
                groups.append([object])
            }
        }
        return groups.map { group in
            let lead = group.first { $0.id == highlightedObjectID } ?? group.first { $0.id == targetObjectID } ?? group[0]
            return (lead, group.filter { $0.id != lead.id })
        }
    }

    private func drawLiveObjects(_ context: inout GraphicsContext, _ g: DomeGeometry) {
        for (object, others) in clusters(g) {
            let p = g.point(object.position)
            let ids = [object.id] + others.map(\.id)
            let highlighted = highlightedObjectID.map(ids.contains) ?? false
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
            if targetObjectID.map(ids.contains) ?? false {
                context.stroke(Path(ellipseIn: CGRect(x: p.x - 16, y: p.y - 16, width: 32, height: 32)),
                               with: .color(.green), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
            let label = others.isEmpty ? object.name : "\(object.name) +\(others.count)"
            context.draw(Text(label).font(highlighted ? .caption.bold() : .caption2).foregroundStyle(color),
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

/// Maps azimuth/altitude to the dome: linear in zenith distance, with `rotation` (the azimuth
/// at the top) and an optional east–west flip.
struct DomeGeometry {
    let center: CGPoint
    let radius: CGFloat
    var rotation: Double = 0
    var flipped = false

    init(size: CGSize, rotation: Double = 0, flipped: Bool = false) {
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        // Room outside the horizon for the N/E/S/W labels.
        radius = min(size.width, size.height) / 2 - 30
        self.rotation = rotation
        self.flipped = flipped
    }

    func point(azimuth: Double, altitude: Double) -> CGPoint {
        let r = radius * (90 - altitude) / 90
        let az = (azimuth - rotation) * .pi / 180
        // `rotation` at the top; east to its left, or to its right when flipped.
        let x = r * sin(az)
        return CGPoint(x: flipped ? center.x + x : center.x - x, y: center.y - r * cos(az))
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
