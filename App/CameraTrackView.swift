import SkyKit
import SwiftUI

/// Camera tracking: the camera image full size, click on something and the mount follows it.
struct CameraTrackView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("camera.imageFraction") private var imageFraction = 0.68
    @AppStorage("camera.zoom") private var zoom = 1.0

    var body: some View {
        let camera = model.cameraTracker.camera
        GeometryReader { proxy in
            if proxy.size.width > 760 {
                // Mac and iPad: image | controls, the divider draggable.
                ResizableSplit(axis: .horizontal, fraction: $imageFraction, range: 0.4...0.75) {
                    CameraTrackScreen()
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } second: {
                    ScrollView { panel.padding(12) }
                }
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        CameraTrackScreen()
                        panel
                    }
                    .padding(12)
                }
            }
        }
        // Every frame is needed while this screen is up; guiding alone needs about ten a second.
        // The zoom is this screen's; guiding's small preview shows the whole frame.
        .onAppear {
            camera.deliversFrames = true
            camera.zoom = zoom
        }
        .onDisappear {
            camera.deliversFrames = false
            camera.zoom = 1
        }
        .onChange(of: camera.zoom) { _, new in zoom = new }
    }

    private var panel: some View {
        VStack(spacing: 10) {
            CameraTrackControls()
            MountPanel(showsGuiding: false)
        }
    }
}

/// The camera image, the aim point and whatever is being followed. A click picks an object.
struct CameraTrackScreen: View {
    @Environment(AppModel.self) private var model
    @State private var pinchStart: Double?
    @State private var showingImageControls = false
    @AppStorage("camera.autoStretch") private var autoStretch = false
    @AppStorage("camera.brightness") private var brightness = 0.0
    @AppStorage("camera.contrast") private var contrast = 1.0
    @AppStorage("camera.holdExposure") private var holdExposure = false
    static let zooms = [1.0, 2, 4, 8]

    var body: some View {
        let tracker = model.cameraTracker
        let camera = tracker.camera
        GeometryReader { proxy in
            let layout = FrameLayout(frame: camera.frameSize, shown: camera.previewRect, view: proxy.size)
            ZStack {
                Color.black
                if let image = camera.preview {
                    Image(decorative: image, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                }
                Canvas { context, _ in draw(&context, layout) }
                VStack {
                    HStack(alignment: .top) {
                        imageControls.padding(10)
                        Spacer()
                        zoomPicker.padding(10)
                    }
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
                // About 30 points on screen, however far it's zoomed.
                Task { await tracker.click(at: point, radius: max(6, 30 / layout.scale)) }
            }
            .gesture(MagnifyGesture()
                .onChanged { value in
                    let start = pinchStart ?? camera.zoom
                    pinchStart = start
                    camera.zoom = min(max(start * value.magnification, 1), 8)
                }
                .onEnded { _ in pinchStart = nil })
        }
        // The image's own shape, so there's no black frame around it.
        .aspectRatio(camera.frameSize.width > 0 ? Double(camera.frameSize.width) / Double(camera.frameSize.height) : 16 / 9,
                     contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear { applyImageSettings() }
        .onChange(of: autoStretch) { applyImageSettings() }
        .onChange(of: brightness) { applyImageSettings() }
        .onChange(of: contrast) { applyImageSettings() }
        .onChange(of: holdExposure) { applyImageSettings() }
        .accessibilityLabel(tracker.tracker == nil ? "Camera view. Click an object to track it." : "Camera view, following an object")
    }

    private func applyImageSettings() {
        let camera = model.cameraTracker.camera
        let tone = PreviewTone(autoStretch: autoStretch, brightness: brightness, contrast: contrast)
        if camera.tone != tone { camera.tone = tone }
        if camera.holdsExposure != holdExposure { camera.holdsExposure = holdExposure }
    }

    /// Exposure and the preview's tone, over the top-left of the picture.
    private var imageControls: some View {
        let camera = model.cameraTracker.camera
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                showingImageControls.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3").padding(4)
            }
            .buttonStyle(.borderless)
            .help("Exposure and image adjustments")
            .accessibilityLabel("Image adjustments")

            if showingImageControls {
                VStack(alignment: .leading, spacing: 8) {
                    if camera.canHoldExposure {
                        Picker("Exposure", selection: $holdExposure) {
                            Text("Auto").tag(false)
                            Text("Hold").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .help("Hold freezes the camera's exposure where it is, so a bright object coming into view doesn't darken everything else")
                    } else if camera.isRunning {
                        Text("This camera sets its own exposure").font(.caption)
                    }
                    Toggle("Auto stretch", isOn: $autoStretch)
                        .help("Spread the picture's darkest to brightest across the full range; lifts a faint night sky")
                    LabeledContent("Brightness") {
                        Slider(value: $brightness, in: -0.5...0.5).frame(width: 130)
                    }
                    LabeledContent("Contrast") {
                        Slider(value: $contrast, in: 0.5...4).frame(width: 130)
                    }
                    HStack {
                        Text("Changes the picture only, not what's tracked").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset") {
                            autoStretch = false
                            brightness = 0
                            contrast = 1
                        }
                        .disabled(!autoStretch && brightness == 0 && contrast == 1)
                    }
                }
                .font(.callout)
                .frame(width: 280)
            }
        }
        .padding(6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
    }

    private var zoomPicker: some View {
        let camera = model.cameraTracker.camera
        return Picker("Zoom", selection: Binding(
            get: { Self.zooms.min { abs($0 - camera.zoom) < abs($1 - camera.zoom) } ?? 1 },
            set: { camera.zoom = $0 })) {
            ForEach(Self.zooms, id: \.self) { Text("\(Int($0))×").tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .padding(4)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .environment(\.colorScheme, .dark)
        .help("Digital zoom: crops the camera's full-resolution picture around the aim point (pinch to zoom too)")
    }

    private var hint: String {
        let tracker = model.cameraTracker
        if !tracker.camera.isRunning { return "Start the camera, then click on something to track it" }
        if tracker.settingAim { return "Click where the telescope points" }
        if let t = tracker.tracker {
            switch t.state {
            case .locked:
                if model.mount.tracksCamera { return model.mount.status }
                if let blocker = tracker.driveBlocker { return "Following in the image only. " + blocker }
                return tracker.drivesMount ? "Following in the image" : "Following in the image only (Move the mount is off)"
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

/// Maps between frame pixels and the view, for the shown part of the frame fitted inside it.
struct FrameLayout {
    let scale: Double
    let origin: CGPoint
    let shown: CGRect

    init(frame: (width: Int, height: Int), shown: CGRect, view: CGSize) {
        let all = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        self.shown = shown.isEmpty ? all : shown
        guard self.shown.width > 0, self.shown.height > 0 else {
            scale = 0
            origin = .zero
            return
        }
        scale = min(view.width / self.shown.width, view.height / self.shown.height)
        origin = CGPoint(x: (view.width - self.shown.width * scale) / 2 - self.shown.minX * scale,
                         y: (view.height - self.shown.height * scale) / 2 - self.shown.minY * scale)
    }

    func view(_ p: (x: Double, y: Double)) -> CGPoint {
        CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale)
    }

    /// The frame pixel under a point in the view, or nil outside the image.
    func frame(_ point: CGPoint) -> (x: Double, y: Double)? {
        guard scale > 0 else { return nil }
        let x = (point.x - origin.x) / scale, y = (point.y - origin.y) / scale
        guard shown.contains(CGPoint(x: x, y: y)) else { return nil }
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
                Toggle("Move the mount", isOn: $tracker.drivesMount)
                    .disabled(tracker.driveBlocker != nil)
                Spacer()
                Button(role: .destructive) {
                    Task { await tracker.release() }
                } label: {
                    Label("Let go", systemImage: "xmark.circle")
                }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(tracker.tracker == nil && !mount.tracksCamera)
                .help("Stop following and stop the mount (Esc)")
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

            HStack(alignment: .firstTextBaseline) {
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
