import SkyKit
import SwiftUI

/// Camera tracking: the camera image full size, click on something and the mount follows it.
struct CameraTrackView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let camera = model.cameraTracker.camera
        GeometryReader { proxy in
            if proxy.size.width > 760 {
                HStack(spacing: 0) {
                    CameraTrackScreen()
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    ScrollView {
                        VStack(spacing: 10) {
                            CameraTrackControls()
                            MountPanel(showsGuiding: false)
                        }
                        .padding(12)
                    }
                    .frame(width: 340)
                }
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        CameraTrackScreen().frame(height: proxy.size.width * 9 / 16)
                        CameraTrackControls()
                        MountPanel(showsGuiding: false)
                    }
                    .padding(12)
                }
            }
        }
        // Every frame is needed while this screen is up; guiding alone needs about ten a second.
        .onAppear { camera.deliversFrames = true }
        .onDisappear { camera.deliversFrames = false }
    }
}

/// The camera image, the aim point and whatever is being followed. A click picks an object.
struct CameraTrackScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let tracker = model.cameraTracker
        let camera = tracker.camera
        GeometryReader { proxy in
            let layout = FrameLayout(frame: camera.frameSize, view: proxy.size)
            ZStack {
                Color.black
                if let image = camera.preview {
                    Image(decorative: image, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                }
                Canvas { context, _ in draw(&context, layout) }
                VStack {
                    Spacer()
                    Text(hint)
                        .font(.callout)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(10)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                guard camera.isRunning, let point = layout.frame(location) else { return }
                Task { await tracker.click(at: point) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel(tracker.tracker == nil ? "Camera view. Click an object to track it." : "Camera view, following an object")
    }

    private var hint: String {
        let tracker = model.cameraTracker
        if !tracker.camera.isRunning { return "Start the camera, then click on something to track it" }
        if tracker.settingAim { return "Click where the telescope points" }
        if let t = tracker.tracker {
            switch t.state {
            case .locked: return model.mount.tracksCamera ? model.mount.status : "Following in the image"
            case .coasting: return "Out of sight, carrying on along its path…"
            case .lost: return "Lost it. Click it again to pick it up."
            }
        }
        return "Click on a moving object to track it"
    }

    private func draw(_ context: inout GraphicsContext, _ layout: FrameLayout) {
        let tracker = model.cameraTracker
        guard layout.scale > 0 else { return }

        // The aim point: where the target is held.
        let aim = layout.view(tracker.aimPoint)
        var cross = Path()
        for (dx, dy) in [(1.0, 0.0), (-1, 0), (0, 1), (0, -1)] {
            cross.move(to: CGPoint(x: aim.x + dx * 6, y: aim.y + dy * 6))
            cross.addLine(to: CGPoint(x: aim.x + dx * 18, y: aim.y + dy * 18))
        }
        context.stroke(cross, with: .color(Theme.scope), lineWidth: 1.5)

        guard let t = tracker.tracker else { return }
        let p = layout.view((t.x, t.y))
        let color: Color = switch t.state {
        case .locked: Theme.target
        case .coasting: Theme.focus
        case .lost: Theme.scope
        }
        // The search area, then a box around the object and its motion over the next half second.
        let r = t.searchRadius * layout.scale
        context.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(color.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        let half = max(10, Double(t.blob.area).squareRoot() * layout.scale + 6)
        context.stroke(Path(CGRect(x: p.x - half, y: p.y - half, width: 2 * half, height: 2 * half)),
                       with: .color(color), lineWidth: 2)
        if t.hasVelocity {
            var arrow = Path()
            arrow.move(to: p)
            arrow.addLine(to: CGPoint(x: p.x + t.vx * 0.5 * layout.scale, y: p.y + t.vy * 0.5 * layout.scale))
            context.stroke(arrow, with: .color(color.opacity(0.8)), lineWidth: 1.5)
        }
    }
}

/// Maps between frame pixels and the view, for an image fitted inside it.
struct FrameLayout {
    let scale: Double
    let origin: CGPoint
    let frameSize: (width: Int, height: Int)

    init(frame: (width: Int, height: Int), view: CGSize) {
        frameSize = frame
        guard frame.width > 0, frame.height > 0 else {
            scale = 0
            origin = .zero
            return
        }
        scale = min(view.width / Double(frame.width), view.height / Double(frame.height))
        origin = CGPoint(x: (view.width - Double(frame.width) * scale) / 2, y: (view.height - Double(frame.height) * scale) / 2)
    }

    func view(_ p: (x: Double, y: Double)) -> CGPoint {
        CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale)
    }

    /// The frame pixel under a point in the view, or nil outside the image.
    func frame(_ point: CGPoint) -> (x: Double, y: Double)? {
        guard scale > 0 else { return nil }
        let x = (point.x - origin.x) / scale, y = (point.y - origin.y) / scale
        guard x >= 0, y >= 0, x < Double(frameSize.width), y < Double(frameSize.height) else { return nil }
        return (x, y)
    }
}

/// Camera choice, following, aim point and calibration.
struct CameraTrackControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var tracker = model.cameraTracker
        let mount = model.mount
        Card(title: "Camera tracking", systemImage: "camera.viewfinder") {
            CameraControls()

            HStack {
                Button(role: .destructive) {
                    Task { await tracker.release() }
                } label: {
                    Label("Let go", systemImage: "xmark.circle")
                }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(tracker.tracker == nil && !mount.tracksCamera)
                .help("Stop following and stop the mount (Esc)")
                Spacer()
                Toggle("Move the mount", isOn: $tracker.drivesMount)
                    .disabled(tracker.driveBlocker != nil)
            }
            if let blocker = tracker.driveBlocker {
                Text(blocker).font(.caption).foregroundStyle(.secondary)
            }
            if let off = tracker.offsetArcminutes {
                Text(String(format: "%.1f′ from the aim point", off))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 2)

            HStack {
                Button(tracker.settingAim ? "Click the image…" : "Set aim point") { tracker.settingAim.toggle() }
                    .help("Click where the telescope points in the image, if it isn't the centre (a finder, or a camera beside the tube)")
                Button("Centre") { tracker.resetAim() }
                    .disabled(model.settings.cameraAimX == 0.5 && model.settings.cameraAimY == 0.5)
            }

            HStack {
                Button(model.guider.isCalibrating ? "Calibrating…" : "Calibrate") { Task { await tracker.calibrate() } }
                    .disabled(model.guider.isCalibrating || mount.kind != .usb || mount.isTracking || tracker.tracker == nil)
                    .help("Click something that isn't moving (a star, a distant light or mast), then calibrate: the mount nudges each axis and watches it move.")
                if let c = model.settings.cameraCalibration {
                    Text(String(format: "%.1f″ per pixel · rotated %.0f°", c.arcsecondsPerPixel, c.rotation))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    Text("Not calibrated").font(.caption).foregroundStyle(.secondary)
                }
            }

            let note = model.guider.isCalibrating ? model.guider.status : tracker.message
            if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
