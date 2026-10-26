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

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if showsCamera && camera.isRunning {
                    SkyCameraPreview(session: camera.session).ignoresSafeArea()
                } else {
                    Theme.space.ignoresSafeArea()
                }
                if let rotation = motion.rotation {
                    let size = proxy.size
                    let sky = PhoneSkyProjection(rotation: rotation,
                                                 focal: PhoneSkyProjection.focal(longSide: max(size.width, size.height),
                                                                                 fieldOfView: camera.fieldOfView),
                                                 width: size.width, height: size.height,
                                                 orientation: Self.orientation)
                    let date = model.viewDate()
                    let pass = model.highlightedPass(at: date)
                    let live = model.liveObjects(at: date)
                    LookUpOverlay(sky: sky, date: date, pass: pass, observer: model.settings.observer, live: live)
                    VStack {
                        topBar
                        Spacer()
                        LookUpStatus(sky: sky, date: date, pass: pass, live: live,
                                     usesTrueNorth: motion.usesTrueNorth)
                    }
                    .padding()
                } else {
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
            .ignoresSafeArea(edges: .bottom)
        }
        .onAppear {
            motion.start()
            if showsCamera { camera.start() }
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            motion.stop()
            camera.stop()
            UIApplication.shared.isIdleTimerDisabled = false
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
            let size = max(2, 5 - star.magnitude)
            context.fill(Path(ellipseIn: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)),
                         with: .color(.white.opacity(0.85)))
            if star.magnitude < 1.5 {
                context.draw(Text(star.name).font(.caption2).foregroundStyle(.white.opacity(0.55)),
                             at: CGPoint(x: p.x, y: p.y + size / 2 + 7))
            }
        }
    }

    private func drawSolarSystem(_ context: inout GraphicsContext) {
        let time = AstroTime(date)
        for body in SolarSystemBody.allCases {
            let h = observer.horizontal(ofEarthFixed: body.earthFixedPosition(at: time))
            guard h.altitude > -2, let p = sky.point(h) else { continue }
            let (size, color): (CGFloat, Color) = switch body {
            case .sun: (18, .yellow)
            case .moon: (16, Color(white: 0.9))
            default: (7, .orange)
            }
            context.fill(Path(ellipseIn: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)),
                         with: .color(color))
            context.draw(Text(body.name).font(.caption).foregroundStyle(color),
                         at: CGPoint(x: p.x, y: p.y + size / 2 + 9))
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
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
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
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
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
            if let pass {
                Text(pass.name).font(.headline)
                if pass.start.date > date {
                    Text("Rises in \(countdown(pass.start.date.timeIntervalSince(date))) in the \(compass(pass.start.position.azimuth)) · peaks \(Int(pass.maxAltitude))°")
                } else if let goal = Self.goal(pass: pass, live: live, date: date), goal.up {
                    Text("Up now · \(Int(goal.position.altitude))° in the \(compass(goal.position.azimuth)) · sets \(pass.end.date, format: .dateTime.hour().minute())")
                }
                if let goal = Self.goal(pass: pass, live: live, date: date), !sky.isOnScreen(goal.position, margin: 30) {
                    Text(turnText(to: goal.position)).foregroundStyle(Theme.target)
                }
            } else {
                Text("No passes coming up. Select satellites in Objects.")
            }
            let c = sky.centre
            Text(String(format: "Pointing az %.0f° alt %.0f°", c.azimuth, c.altitude) + (usesTrueNorth ? "" : " · magnetic north"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
        }
        .font(.subheadline)
        .foregroundStyle(.white)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .padding(.bottom, 8)
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
    @ObservationIgnored private var configured = false

    func start() {
        Task {
            guard await AVCaptureDevice.requestAccess(for: .video) else { return }
            if !configured {
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                      let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
                session.beginConfiguration()
                session.sessionPreset = .high
                session.addInput(input)
                session.commitConfiguration()
                fieldOfView = Double(device.activeFormat.videoFieldOfView)
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

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
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

    func updateUIView(_ view: PreviewView, context: Context) {}
}
#endif
