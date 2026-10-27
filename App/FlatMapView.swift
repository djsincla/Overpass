import SkyKit
import SwiftUI

/// The Earth as a flat world map centred on your longitude, drawn from the same bundled NASA
/// images as the globe, so it works with no network. Day and night follow the Sun, with city
/// lights on the night side. Pinch or drag to zoom and pan; the location button resets it.
struct FlatMapView: View {
    let home: Geodetic
    let tracks: [GlobeTrack]
    /// Towards the Sun, Earth-fixed.
    let sun: Vec3
    var recentreRequest = 0
    var onTapTrack: ((String) -> Void)?

    @State private var scale = 1.0
    @State private var pan = CGSize.zero
    @State private var gestureStart: (scale: Double, pan: CGSize)?

    static let day: Image? = image("earth-day")
    static let night: Image? = image("earth-night")

    private static func image(_ name: String) -> Image? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "jpg") else { return nil }
        #if os(iOS)
        return UIImage(contentsOfFile: url.path).map { Image(uiImage: $0) }
        #else
        return NSImage(contentsOf: url).map { Image(nsImage: $0) }
        #endif
    }

    var body: some View {
        GeometryReader { proxy in
            let map = MapProjection(view: proxy.size, scale: scale, pan: pan, centre: home.longitude)
            let subsolar = Self.subsolar(sun)
            ZStack(alignment: .topLeading) {
                Color.black
                ForEach(-1...1, id: \.self) { copy in
                    let frame = map.imageFrame(copy: copy)
                    Self.day?.resizable().interpolation(.high)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }
                // Night: darkened, then the city lights.
                NightShape(map: map, subsolar: subsolar).fill(.black.opacity(0.62))
                ZStack(alignment: .topLeading) {
                    ForEach(-1...1, id: \.self) { copy in
                        let frame = map.imageFrame(copy: copy)
                        Self.night?.resizable().interpolation(.high)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                    }
                }
                .mask(NightShape(map: map, subsolar: subsolar))
                .blendMode(.screen)
                Canvas { context, _ in draw(&context, map) }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { tap in
                if let id = nearestTrack(to: tap.location, map) { onTapTrack?(id) }
            })
            .gesture(MagnifyGesture()
                .onChanged { value in
                    let start = gestureStart ?? (scale, pan)
                    gestureStart = start
                    scale = min(max(start.scale * value.magnification, 1), 12)
                    pan = map.clampedPan(start.pan, scale: scale)
                }
                .onEnded { _ in gestureStart = nil })
            .simultaneousGesture(DragGesture(minimumDistance: 4)
                .onChanged { value in
                    let start = gestureStart ?? (scale, pan)
                    gestureStart = start
                    pan = map.clampedPan(CGSize(width: start.pan.width + value.translation.width,
                                                height: start.pan.height + value.translation.height), scale: scale)
                }
                .onEnded { _ in gestureStart = nil })
            .onChange(of: recentreRequest) { _, _ in
                withAnimation(.easeInOut(duration: 0.3)) { scale = 1; pan = .zero }
            }
        }
    }

    /// The point on the Earth with the Sun overhead.
    static func subsolar(_ sun: Vec3) -> Geodetic {
        let r = (sun.x * sun.x + sun.y * sun.y + sun.z * sun.z).squareRoot()
        return Geodetic(latitude: asin(sun.z / r).degrees, longitude: atan2(sun.y, sun.x).degrees)
    }

    private func draw(_ context: inout GraphicsContext, _ map: MapProjection) {
        for track in tracks where !track.focused { drawTrack(&context, map, track) }
        for track in tracks where track.focused { drawTrack(&context, map, track) }

        // You.
        for p in map.points(home) {
            context.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(Theme.target))
            context.stroke(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(.white), lineWidth: 1.5)
        }
    }

    private func drawTrack(_ context: inout GraphicsContext, _ map: MapProjection, _ track: GlobeTrack) {
        let thin = StrokeStyle(lineWidth: track.focused ? 1.6 : 1.2, lineCap: .round, lineJoin: .round)
        let thick = StrokeStyle(lineWidth: track.focused ? 4 : 3, lineCap: .round, lineJoin: .round)
        for path in map.paths(track.path) {
            context.stroke(path, with: .color(track.color.opacity(track.focused ? 0.75 : 0.5)), style: thin)
        }
        for path in map.paths(track.visiblePath) {
            context.stroke(path, with: .color(track.color), style: thick)
        }
        if track.focused, let footprint = track.footprint {
            for path in map.footprintPaths(footprint) {
                context.fill(path, with: .color(track.color.opacity(0.14)))
                context.stroke(path, with: .color(track.color.opacity(0.6)), lineWidth: 1)
            }
        }
        if let now = track.now {
            for p in map.points(now) {
                let r: CGFloat = track.focused ? 7 : 5
                context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(track.color))
                context.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(.white), lineWidth: 1.5)
                context.draw(Text(track.name).font(.caption2.bold()).foregroundStyle(.white), at: CGPoint(x: p.x, y: p.y - r - 8))
            }
        }
    }

    private func nearestTrack(to location: CGPoint, _ map: MapProjection) -> String? {
        let hits = tracks.compactMap { track -> (String, CGFloat)? in
            guard let now = track.now else { return nil }
            let d = map.points(now).map { hypot($0.x - location.x, $0.y - location.y) }.min() ?? .infinity
            return d < 24 ? (track.id, d) : nil
        }
        return hits.min { $0.1 < $1.1 }?.0
    }
}

/// Equirectangular, centred on a longitude, scaled and panned to fit a view. The map repeats
/// east and west, so anything near the edges is drawn in each copy that shows.
struct MapProjection {
    let view: CGSize
    let width: CGFloat
    let height: CGFloat
    let origin: CGPoint
    let centre: Double

    init(view: CGSize, scale: Double, pan: CGSize, centre: Double) {
        self.view = view
        self.centre = centre
        // The whole world fits at scale 1.
        let fit = min(view.width, view.height * 2)
        width = fit * scale
        height = width / 2
        let panned = MapProjection.clamp(pan, width: width, height: height, view: view)
        origin = CGPoint(x: (view.width - width) / 2 + panned.width, y: (view.height - height) / 2 + panned.height)
    }

    /// Up and down, the map stays on screen; east and west it wraps, so only keep the pan within a turn.
    static func clamp(_ pan: CGSize, width: CGFloat, height: CGFloat, view: CGSize) -> CGSize {
        let slack = max(0, (height - view.height) / 2)
        let x = pan.width.truncatingRemainder(dividingBy: width)
        return CGSize(width: x, height: min(max(pan.height, -slack), slack))
    }

    func clampedPan(_ pan: CGSize, scale: Double) -> CGSize {
        let w = min(view.width, view.height * 2) * scale
        return MapProjection.clamp(pan, width: w, height: w / 2, view: view)
    }

    /// x for a longitude in the central copy, which runs from `centre` − 180° to `centre` + 180°.
    func x(_ longitude: Double) -> CGFloat {
        origin.x + CGFloat((wrap180(longitude - centre) + 180) / 360) * width
    }

    func y(_ latitude: Double) -> CGFloat {
        origin.y + CGFloat((90 - latitude) / 180) * height
    }

    /// Where the world image goes for one copy: its left edge is longitude −180°.
    func imageFrame(copy: Int) -> CGRect {
        CGRect(x: x(-180) + CGFloat(copy) * width, y: origin.y, width: width, height: height)
    }

    /// A place, in every copy that might show.
    func points(_ place: Geodetic) -> [CGPoint] {
        let p = CGPoint(x: x(place.longitude), y: y(place.latitude))
        return [-1, 0, 1].map { CGPoint(x: p.x + CGFloat($0) * width, y: p.y) }
    }

    /// A line through places, unwrapped so it never jumps across the map, in each copy.
    func paths(_ places: [Geodetic]) -> [Path] {
        guard let first = places.first else { return [] }
        var unwrapped = [wrap180(first.longitude - centre)]
        for place in places.dropFirst() {
            let previous = unwrapped[unwrapped.count - 1]
            unwrapped.append(previous + wrap180(wrap180(place.longitude - centre) - previous))
        }
        return [-1, 0, 1].map { copy in
            var path = Path()
            for (i, place) in places.enumerated() {
                let point = CGPoint(x: origin.x + CGFloat((unwrapped[i] + 180) / 360 + Double(copy)) * width, y: y(place.latitude))
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            return path
        }
    }

    /// A footprint ring as closed shapes. A cap over a pole is redone here in the map's own
    /// longitudes (centred on `centre`), so it runs edge to edge across this map.
    func footprintPaths(_ ring: [Geodetic]) -> [Path] {
        let polar = abs(ring.first?.latitude ?? 0) == 90
        if polar {
            let pole = ring[0].latitude
            let edge = ring.dropFirst().dropLast().sorted { wrap180($0.longitude - centre) < wrap180($1.longitude - centre) }
            var path = Path()
            path.move(to: CGPoint(x: origin.x, y: y(pole)))
            for p in edge { path.addLine(to: CGPoint(x: x(p.longitude), y: y(p.latitude))) }
            path.addLine(to: CGPoint(x: origin.x + width, y: y(edge.last?.latitude ?? pole)))
            path.addLine(to: CGPoint(x: origin.x + width, y: y(pole)))
            path.closeSubpath()
            return [-1, 0, 1].map { path.offsetBy(dx: CGFloat($0) * width, dy: 0) }
        }
        return paths(ring + ring.prefix(1)).map { var p = $0; p.closeSubpath(); return p }
    }
}

/// The night side of the Earth on the map, from the point the Sun is over, in each copy.
struct NightShape: Shape {
    let map: MapProjection
    let subsolar: Geodetic

    func path(in rect: CGRect) -> Path {
        // A point is in daylight when it's within 90° of the subsolar point. For each longitude,
        // the boundary latitude is where that angle is exactly 90°.
        let declination = subsolar.latitude.radians
        let tanD = abs(tan(declination)) < 1e-4 ? (declination < 0 ? -1e-4 : 1e-4) : tan(declination)
        var boundary: [CGPoint] = []
        let steps = 180
        for i in 0...steps {
            let offset = -180 + 360 * Double(i) / Double(steps)
            let longitude = map.centre + offset
            let h = (longitude - subsolar.longitude).radians
            let latitude = atan(-cos(h) / tanD).degrees
            boundary.append(CGPoint(x: map.origin.x + CGFloat((offset + 180) / 360) * map.width, y: map.y(latitude)))
        }
        // North of the line is in daylight when the Sun is north of the equator, so night is
        // to the south; the other way round in the southern summer.
        let nightEdge = map.y(declination > 0 ? -90 : 90)
        var path = Path()
        for copy in -1...1 {
            let dx = CGFloat(copy) * map.width
            path.move(to: CGPoint(x: boundary[0].x + dx, y: nightEdge))
            for p in boundary { path.addLine(to: CGPoint(x: p.x + dx, y: p.y)) }
            path.addLine(to: CGPoint(x: boundary[boundary.count - 1].x + dx, y: nightEdge))
            path.closeSubpath()
        }
        return path
    }
}
