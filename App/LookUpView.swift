#if os(iOS)
import AVFoundation
import CoreLocation
import CoreMotion
import SkyKit
import SwiftUI
import UIKit

/// Hold the phone up to the sky: the camera's picture with the horizon, the compass, bright
/// stars, the Sun, Moon and planets, the selected satellites, and the next pass's path drawn over
/// it. When the satellite (or where it will rise) is off the screen, an arrow points the way.
struct LookUpView: View {
    @Environment(AppModel.self) private var model
    @State private var motion = SkyMotion()
    @State private var camera = SkyCamera()
    @AppStorage("lookUp.camera") private var showsCamera = true

    /// The whole screen's size, from the layer that ignores the safe area.
    @State private var screen = CGSize.zero

    var body: some View {
        let date = model.viewDate()
        let pass = model.highlightedPass(at: date)
        let live = model.liveObjects(at: date)
        ZStack {
            // The whole screen, under the notch and the tab bar, so the sky is drawn to the same
            // size and centre as the camera picture.
            GeometryReader { proxy in
                ZStack {
                    if cameraShown {
                        SkyCameraPreview(session: camera.session, shift: shift(proxy.size))
                    } else {
                        Theme.space
                    }
                    if let sky = projection(proxy.size) {
                        LookUpOverlay(sky: sky, date: date, pass: pass, observer: model.settings.observer, live: live)
                    }
                }
            }
            .ignoresSafeArea()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { screen = $0 }

            // The card and buttons in their own layer, which keeps to the safe area: padding the
            // full-screen layer by its insets didn't work, as a view ignoring the safe area reads
            // them as zero, and the card went under the tab bar.
            if let sky = projection(screen) {
                VStack {
                    topBar
                    Spacer()
                    LookUpStatus(sky: sky, date: date, pass: pass, live: live, usesTrueNorth: motion.usesTrueNorth)
                }
                .padding()
            } else if motion.rotation == nil {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(motion.unavailable ? "This device has no motion sensors to tell where it's pointing."
                                            : "Finding which way the phone points…")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                }
                .padding()
            }
        }
        .onAppear {
            motion.start()
            if showsCamera { camera.start() }
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            motion.stop()
            camera.stop()
            // Stays on anyway while the mount is connected.
            UIApplication.shared.isIdleTimerDisabled = model.mount.state == .connected
        }
        .onChange(of: showsCamera) { _, on in on ? camera.start() : camera.stop() }
    }

    private var topBar: some View {
        HStack {
            Spacer()
            Button {
                showsCamera.toggle()
            } label: {
                Image(systemName: showsCamera ? "camera.fill" : "camera")
                    .padding(10)
                    .background(.black.opacity(0.5), in: Circle())
                    .foregroundStyle(.white)
            }
            .accessibilityLabel(showsCamera ? "Hide the camera picture" : "Show the camera picture")
        }
    }

    /// Which way the interface is turned, for which way is up on the screen.
    private var cameraShown: Bool { showsCamera && camera.isRunning }

    private func shift(_ size: CGSize) -> Double { Self.horizonShift(size, cameraAspect: cameraShown ? camera.aspect : nil) }

    /// Where the sky lands on a screen this size, once the phone's attitude is known.
    private func projection(_ size: CGSize) -> PhoneSkyProjection? {
        guard let rotation = motion.rotation, size.width > 0, size.height > 0 else { return nil }
        return PhoneSkyProjection(rotation: rotation,
                                  focal: PhoneSkyProjection.focal(longSide: max(size.width, size.height), fieldOfView: camera.fieldOfView),
                                  width: size.width, height: size.height, orientation: Self.orientation, verticalShift: shift(size))
    }

    /// In landscape, how far down to slide the picture and the sky, so the horizon sits about a
    /// third of the way up with the phone held level rather than halfway: a sixth of the height,
    /// or as much as the camera picture has cropped off below (it fills the screen's width).
    static func horizonShift(_ size: CGSize, cameraAspect: Double?) -> Double {
        guard size.width > size.height else { return 0 }
        let wanted = size.height / 6
        guard let cameraAspect else { return wanted }
        let spare = (size.width / cameraAspect - size.height) / 2
        return max(0, min(wanted, spare))
    }

    private static var orientation: PhoneSkyProjection.Orientation {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return switch scene?.effectiveGeometry.interfaceOrientation {
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: .portrait
        }
    }
}

/// The sky drawn over the camera picture.
private struct LookUpOverlay: View {
    let sky: PhoneSkyProjection
    let date: Date
    let pass: SatellitePass?
    let observer: Observer
    let live: [LiveObject]

    var body: some View {
        Canvas { context, size in
            drawGrid(&context, size)
            drawStars(&context)
            drawSolarSystem(&context)
            if let pass { drawPass(&context, pass) }
            drawLive(&context)
            drawTarget(&context, size)
            drawReticle(&context, size)
        }
        .allowsHitTesting(false)
    }

    private func cg(_ p: (x: Double, y: Double)) -> CGPoint { CGPoint(x: p.x, y: p.y) }

    /// A line through sky positions, broken where it goes behind the camera or far off screen.
    private func polyline(_ positions: [Horizontal]) -> Path {
        var path = Path()
        var drawing = false
        let limit = 4 * max(sky.width, sky.height)
        for h in positions {
            guard let p = sky.point(h), abs(p.x - sky.width / 2) < limit, abs(p.y - sky.height / 2) < limit else {
                drawing = false
                continue
            }
            if drawing { path.addLine(to: cg(p)) } else { path.move(to: cg(p)) }
            drawing = true
        }
        return path
    }

    private func drawGrid(_ context: inout GraphicsContext, _ size: CGSize) {
        let around = Array(stride(from: 0.0, through: 360, by: 2))
        context.stroke(polyline(around.map { Horizontal(azimuth: $0, altitude: 0) }),
                       with: .color(.white.opacity(0.8)), lineWidth: 1.5)
        for altitude in [30.0, 60.0] {
            context.stroke(polyline(around.map { Horizontal(azimuth: $0, altitude: altitude) }),
                           with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 0.75, dash: [4, 5]))
        }
        // Compass points on the horizon, with a tick every 15°.
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        for az in stride(from: 0.0, to: 360, by: 15) {
            guard let p = sky.point(Horizontal(azimuth: az, altitude: 0)) else { continue }
            let major = az.truncatingRemainder(dividingBy: 45) == 0
            var tick = Path()
            tick.move(to: CGPoint(x: p.x, y: p.y - (major ? 10 : 5)))
            tick.addLine(to: CGPoint(x: p.x, y: p.y))
            context.stroke(tick, with: .color(.white.opacity(0.8)), lineWidth: 1)
            let label = major ? names[Int(az / 45)] : "\(Int(az))°"
            context.draw(Text(label).font(major ? .headline : .caption2).foregroundStyle(.white.opacity(major ? 0.95 : 0.6)),
                         at: CGPoint(x: p.x, y: p.y + (major ? 14 : 10)))
        }
    }

    private func drawStars(_ context: inout GraphicsContext) {
        let time = AstroTime(date)
        for star in BrightStars.all {
            let h = observer.horizontal(ofEarthFixed: star.earthFixedPosition(at: time))
            guard h.altitude > -2, let p = sky.point(h) else { continue }
            // Big enough to find against the camera's picture, with a soft halo.
            let size = max(4, 9 - 1.5 * star.magnitude)
            let glow = size * 2.2
            context.fill(Path(ellipseIn: CGRect(x: p.x - glow / 2, y: p.y - glow / 2, width: glow, height: glow)),
                         with: .color(.white.opacity(0.18)))
            context.fill(Path(ellipseIn: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)),
                         with: .color(.white))
            if star.magnitude < 2 {
                context.draw(Text(star.name).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.75)),
                             at: CGPoint(x: p.x, y: p.y + glow / 2 + 8))
            }
        }
    }

    private func drawSolarSystem(_ context: inout GraphicsContext) {
        let time = AstroTime(date)
        for body in SolarSystemBody.allCases {
            let h = observer.horizontal(ofEarthFixed: body.earthFixedPosition(at: time))
            guard h.altitude > -2, let p = sky.point(h) else { continue }
            let (size, color): (CGFloat, Color) = switch body {
            case .sun: (30, .yellow)
            case .moon: (28, Color(white: 0.92))
            default: (14, .orange)
            }
            let glow = size * 1.8
            context.fill(Path(ellipseIn: CGRect(x: p.x - glow / 2, y: p.y - glow / 2, width: glow, height: glow)),
                         with: .color(color.opacity(0.22)))
            context.fill(Path(ellipseIn: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)),
                         with: .color(color))
            context.draw(Text(body.name).font(.subheadline.bold()).foregroundStyle(color),
                         at: CGPoint(x: p.x, y: p.y + glow / 2 + 10))
        }
    }

    /// The pass's path, sunlit solid and in shadow dashed, with the time each minute.
    private func drawPass(_ context: inout GraphicsContext, _ pass: SatellitePass) {
        let track = pass.track
        guard track.count > 1 else { return }
        for (a, b) in zip(track, track.dropFirst()) {
            let segment = polyline([a.position, b.position])
            if a.sunlit {
                context.stroke(segment, with: .color(Theme.sunlit), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            } else {
                context.stroke(segment, with: .color(.white.opacity(0.75)), style: StrokeStyle(lineWidth: 2.5, dash: [6, 4]))
            }
        }
        var lastMinute = -1
        for sample in track {
            let minute = Int(sample.date.timeIntervalSince1970 / 60)
            guard minute != lastMinute else { continue }
            lastMinute = minute
            guard let p = sky.point(sample.position) else { continue }
            context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.white))
            context.draw(Text(sample.date, format: .dateTime.hour().minute()).font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.8)),
                         at: CGPoint(x: p.x + 22, y: p.y))
        }
        // Where it rises, ringed.
        if let p = sky.point(pass.start.position) {
            context.stroke(Path(ellipseIn: CGRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20)),
                           with: .color(Theme.rising), lineWidth: 2)
        }
    }

    private func drawLive(_ context: inout GraphicsContext) {
        for object in live where object.id.hasPrefix("sat:") {
            guard let p = sky.point(object.position) else { continue }
            let color = object.sunlit ? Theme.sunlit : Theme.eclipsed
            context.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(color))
            context.draw(Text(object.name).font(.caption.bold()).foregroundStyle(color),
                         at: CGPoint(x: p.x, y: p.y - 14))
        }
    }

    /// The pass's satellite if it's up, otherwise where it will rise: ringed on screen, or an
    /// arrow at the edge pointing the way when it's off screen.
    private func drawTarget(_ context: inout GraphicsContext, _ size: CGSize) {
        guard let goal = LookUpStatus.goal(pass: pass, live: live, date: date) else { return }
        if sky.isOnScreen(goal.position, margin: 30), let p = sky.point(goal.position) {
            context.stroke(Path(ellipseIn: CGRect(x: p.x - 18, y: p.y - 18, width: 36, height: 36)),
                           with: .color(Theme.target), lineWidth: 2.5)
            return
        }
        let angle = sky.turn(towards: goal.position)
        let centre = CGPoint(x: sky.opticalCentre.x, y: sky.opticalCentre.y)
        // As far towards the edge as fits, along the direction to turn.
        let reach = min(size.width, size.height) / 2 - 50
        let tip = CGPoint(x: centre.x + cos(angle) * reach, y: centre.y - sin(angle) * reach)
        var arrow = Path()
        let back = 26.0, wing = 0.5
        arrow.move(to: tip)
        arrow.addLine(to: CGPoint(x: tip.x - cos(angle - wing) * back, y: tip.y + sin(angle - wing) * back))
        arrow.addLine(to: CGPoint(x: tip.x - cos(angle + wing) * back, y: tip.y + sin(angle + wing) * back))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(Theme.target))
    }

    private func drawReticle(_ context: inout GraphicsContext, _ size: CGSize) {
        let c = CGPoint(x: sky.opticalCentre.x, y: sky.opticalCentre.y)
        var cross = Path()
        for (dx, dy) in [(1.0, 0.0), (-1, 0), (0, 1), (0, -1)] {
            cross.move(to: CGPoint(x: c.x + dx * 6, y: c.y + dy * 6))
            cross.addLine(to: CGPoint(x: c.x + dx * 16, y: c.y + dy * 16))
        }
        context.stroke(cross, with: .color(.white.opacity(0.7)), lineWidth: 1.5)
    }
}

/// What's coming, where the phone points, and which way to turn.
private struct LookUpStatus: View {
    let sky: PhoneSkyProjection
    let date: Date
    let pass: SatellitePass?
    let live: [LiveObject]
    let usesTrueNorth: Bool
    @AppStorage("lookUp.statusCollapsed") private var collapsed = false

    /// The satellite now if it's up, otherwise where it will rise.
    static func goal(pass: SatellitePass?, live: [LiveObject], date: Date) -> (position: Horizontal, up: Bool)? {
        guard let pass else { return nil }
        if pass.start.date <= date, let now = live.first(where: { $0.id == "sat:\(pass.noradID)" }) {
            return (now.position, true)
        }
        return pass.start.date > date ? (pass.start.position, false) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Folded, one line: the satellite and where it is, by the chevron, as in Conjunctions.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(pass?.name ?? "No passes coming up").font(.headline).lineLimit(1)
                if collapsed, let summary { Text(summary).lineLimit(1).foregroundStyle(.white.opacity(0.8)) }
                Spacer(minLength: 4)
                Button {
                    withAnimation(.snappy) { collapsed.toggle() }
                } label: {
                    Image(systemName: collapsed ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                        .font(.title3).symbolRenderingMode(.hierarchical)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(collapsed ? "Show details" : "Hide details")
            }
            if !collapsed { details }
        }
        .font(.subheadline)
        .foregroundStyle(.white)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .padding(.bottom, 8)
    }

    /// Up now, or when it rises: for the folded card.
    private var summary: String? {
        guard let pass else { return nil }
        if pass.start.date > date { return "rises in \(countdown(pass.start.date.timeIntervalSince(date)))" }
        if let goal = Self.goal(pass: pass, live: live, date: date), goal.up {
            return "up \(Int(goal.position.altitude))° \(compass(goal.position.azimuth))"
        }
        return nil
    }

    @ViewBuilder
    private var details: some View {
        if let pass {
            if pass.start.date > date {
                Text("Rises in \(countdown(pass.start.date.timeIntervalSince(date))) in the \(compass(pass.start.position.azimuth)) · peaks \(Int(pass.maxAltitude))°")
            } else if let goal = Self.goal(pass: pass, live: live, date: date), goal.up {
                Text("Up now · \(Int(goal.position.altitude))° in the \(compass(goal.position.azimuth)) · sets \(pass.end.date, format: .dateTime.hour().minute())")
            }
            if let goal = Self.goal(pass: pass, live: live, date: date), !sky.isOnScreen(goal.position, margin: 30) {
                Text(turnText(to: goal.position)).foregroundStyle(Theme.target)
            }
        } else {
            Text("Select satellites in Objects.")
        }
        let c = sky.centre
        Text(String(format: "Pointing az %.0f° alt %.0f°", c.azimuth, c.altitude) + (usesTrueNorth ? "" : " · magnetic north"))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
    }

    /// "Turn right 40°, up 15°", from where the camera points.
    private func turnText(to h: Horizontal) -> String {
        let c = sky.centre
        var dAz = normalizedDegrees(h.azimuth - c.azimuth)
        if dAz > 180 { dAz -= 360 }
        let dAlt = h.altitude - c.altitude
        var parts: [String] = []
        if abs(dAz) >= 3 { parts.append("\(dAz > 0 ? "right" : "left") \(Int(abs(dAz).rounded()))°") }
        if abs(dAlt) >= 3 { parts.append("\(dAlt > 0 ? "up" : "down") \(Int(abs(dAlt).rounded()))°") }
        return parts.isEmpty ? "Nearly there" : "Turn " + parts.joined(separator: ", ")
    }

    private func compass(_ azimuth: Double) -> String {
        let names = ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"]
        return names[Int((normalizedDegrees(azimuth) + 22.5) / 45) % 8]
    }

    private func countdown(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? "\(s / 3600) h \(s % 3600 / 60) min" : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The phone's attitude against true north (magnetic if location isn't allowed).
@MainActor @Observable
final class SkyMotion {
    private(set) var rotation: [[Double]]?
    private(set) var usesTrueNorth = true
    private(set) var unavailable = false
    @ObservationIgnored private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable else {
            unavailable = true
            return
        }
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        let status = CLLocationManager().authorizationStatus
        let trueNorth = frames.contains(.xTrueNorthZVertical) && (status == .authorizedWhenInUse || status == .authorizedAlways)
        usesTrueNorth = trueNorth
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(using: trueNorth ? .xTrueNorthZVertical : .xMagneticNorthZVertical, to: .main) { [weak self] data, _ in
            guard let m = data?.attitude.rotationMatrix else { return }
            self?.rotation = [[m.m11, m.m12, m.m13], [m.m21, m.m22, m.m23], [m.m31, m.m32, m.m33]]
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}

/// The back camera, for the picture behind the sky.
@MainActor @Observable
final class SkyCamera {
    @ObservationIgnored let session = AVCaptureSession()
    private(set) var isRunning = false
    /// Across the picture's long side, degrees. A typical wide camera until the real one is known.
    private(set) var fieldOfView = 65.0
    /// The picture's long side over its short side.
    private(set) var aspect = 4.0 / 3
    @ObservationIgnored private var configured = false

    func start() {
        Task {
            guard await AVCaptureDevice.requestAccess(for: .video) else { return }
            if !configured {
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                      let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
                session.beginConfiguration()
                // The whole 4:3 sensor: more sky above and below than 16:9, and room to slide the
                // picture down in landscape.
                session.sessionPreset = session.canSetSessionPreset(.photo) ? .photo : .high
                session.addInput(input)
                session.commitConfiguration()
                fieldOfView = Double(device.activeFormat.videoFieldOfView)
                let d = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                if d.width > 0, d.height > 0 { aspect = Double(max(d.width, d.height)) / Double(min(d.width, d.height)) }
                configured = true
            }
            // AVCaptureSession isn't Sendable, but starting and stopping it off the main thread is
            // what Apple asks for: it blocks.
            nonisolated(unsafe) let session = session
            await Task.detached { session.startRunning() }.value
            isRunning = session.isRunning
        }
    }

    func stop() {
        nonisolated(unsafe) let session = session
        Task.detached { session.stopRunning() }
        isRunning = false
    }
}

/// The camera picture, filling the screen.
private struct SkyCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// How far down the picture's centre sits, in points.
    var shift = 0.0

    final class PreviewView: UIView {
        let preview = AVCaptureVideoPreviewLayer()
        var shift = 0.0 { didSet { if shift != oldValue { setNeedsLayout() } } }

        override init(frame: CGRect) {
            super.init(frame: frame)
            layer.addSublayer(preview)
            clipsToBounds = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Taller than the view by twice the shift and starting at its top, so its middle sits
            // `shift` below the view's. The picture fills the width either way, so it keeps its scale.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            preview.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height + 2 * shift)
            CATransaction.commit()
            // Keep the picture upright as the interface turns.
            guard let connection = preview.connection, let scene = window?.windowScene else { return }
            let angle: CGFloat = switch scene.effectiveGeometry.interfaceOrientation {
            case .landscapeLeft: 180
            case .landscapeRight: 0
            case .portraitUpsideDown: 270
            default: 90
            }
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) { view.shift = shift }
}
#endif
