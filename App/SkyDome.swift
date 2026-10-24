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
    var showStars = true

    var body: some View {
        Canvas { context, size in
            let radius = min(size.width, size.height) / 2 - 18
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let geometry = DomeGeometry(center: center, radius: radius)

            drawBackground(&context, geometry)
            if let az = cableStopAzimuth { drawCableStop(&context, geometry, az) }
            if showStars { drawStars(&context, geometry) }
            drawSolarSystem(&context, geometry)
            if let pass { drawPass(&context, geometry, pass) }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel(accessibilitySummary)
    }

    var accessibilitySummary: String {
        guard let pass else { return "Sky chart" }
        return "Sky chart showing \(pass.name), rising at azimuth \(Int(pass.start.position.azimuth)) degrees, "
            + "peaking at \(Int(pass.maxAltitude)) degrees altitude, setting at azimuth \(Int(pass.end.position.azimuth)) degrees"
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
            let p = g.point(azimuth: az, altitude: -9)
            context.draw(Text(label).font(.caption.bold()).foregroundStyle(.secondary), at: p)
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
                         with: .color(.white.opacity(0.85)))
            if star.magnitude < 1 {
                context.draw(Text(star.name).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5)),
                             at: CGPoint(x: p.x, y: p.y + 8))
            }
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
            context.draw(Text(body.name).font(.caption2).foregroundStyle(color), at: CGPoint(x: p.x, y: p.y + size / 2 + 7))
        }
    }

    private func drawPass(_ context: inout GraphicsContext, _ g: DomeGeometry, _ pass: SatellitePass) {
        let track = pass.track
        guard track.count > 1 else { return }

        // Bright where the satellite is sunlit, dim in the Earth's shadow.
        for (a, b) in zip(track, track.dropFirst()) {
            var segment = Path()
            segment.move(to: g.point(a.position))
            segment.addLine(to: g.point(b.position))
            context.stroke(segment, with: .color(a.sunlit ? .cyan : .cyan.opacity(0.35)),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }

        // Where the mount will lose the target, cutting round the zenith.
        if let plan {
            for (sample, point) in zip(plan.samples, track) where sample.error > tolerance {
                let p = g.point(point.position)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.red))
            }
        }

        // One tick a minute, labelled with the time.
        let minute = track.filter { Int($0.date.timeIntervalSince(track[0].date)) % 60 == 0 }
        for sample in minute.dropFirst() {
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

        // Where it is right now, if the pass is under way.
        if let now = track.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }),
           abs(now.date.timeIntervalSince(date)) < 2 {
            let p = g.point(now.position)
            context.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(.white))
            context.stroke(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)),
                           with: .color(.cyan), lineWidth: 2)
        }
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

/// The live sky with the next pass on it.
struct SkyTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if model.settings.hasLocation {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let current = model.passes.first { $0.end.date > context.date }
                        VStack(spacing: 12) {
                            SkyDome(observer: model.settings.observer, date: context.date, pass: current,
                                    plan: current.flatMap(model.plan(for:)), tolerance: model.settings.pointingTolerance,
                                    cableStopAzimuth: model.settings.cableStopAzimuth)
                                .padding(.horizontal)
                            if let current { NextPassSummary(pass: current, now: context.date) }
                            Spacer(minLength: 0)
                        }
                    }
                } else {
                    LocationNeededView()
                }
            }
            .navigationTitle("Sky")
        }
    }
}

struct NextPassSummary: View {
    let pass: SatellitePass
    let now: Date

    var body: some View {
        VStack(spacing: 4) {
            Text(pass.name).font(.headline)
            if pass.start.date > now {
                Text("Rises \(pass.start.date, style: .relative) · peaks \(Int(pass.maxAltitude))° · \(pass.isVisible ? "visible" : "not visible")")
            } else {
                Text("Up now · sets \(pass.end.date, style: .relative)")
            }
        }
        .font(.subheadline)
        .multilineTextAlignment(.center)
        .padding(.horizontal)
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
