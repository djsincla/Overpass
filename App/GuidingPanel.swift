import SkyKit
import SwiftUI

/// Camera preview, calibration and the guide switch.
struct GuidingPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var guider = model.guider
        let camera = guider.camera
        VStack(alignment: .leading, spacing: 8) {
            CameraControls()
            if camera.isRunning {
                CameraPreview(camera: camera)
                    .frame(maxHeight: 240)

                HStack {
                    if let spot = camera.spot {
                        Text(String(format: "Spot S/N %.0f", spot.signalToNoise) + (guider.errorArcmin.map { String(format: " · %.1f′ off centre", $0) } ?? ""))
                    } else {
                        Text("No spot near the centre")
                    }
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)

                HStack {
                    Button(guider.isCalibrating ? "Calibrating…" : "Calibrate") { Task { await guider.calibrate() } }
                        .disabled(guider.isCalibrating || model.mount.kind != .usb || model.mount.isTracking)
                        .help("Centre a bright star with tracking stopped; the mount nudges each axis and watches the image.")
                    Spacer()
                    Toggle("Guide", isOn: $guider.isGuiding)
                        .disabled(!guider.canGuide)
                }
            }
            Text(guider.status.isEmpty ? help : guider.status).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var help: String {
        if model.settings.cameraCalibration == nil {
            return "Fix the iPhone to the tube (3× or 5× lens), start the camera, centre a bright star, and calibrate. Then start Smooth tracking and turn on Guide."
        }
        return "Calibrated. Start Smooth tracking, then turn on Guide to keep the target centred."
    }
}

/// Which camera, and starting and stopping it.
struct CameraControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let camera = model.guider.camera
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Camera", selection: $model.settings.cameraDeviceID) {
                    Text("Choose…").tag(String?.none)
                    ForEach(camera.devices, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                }
                .onAppear { camera.refreshDevices() }
                Button { camera.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Look for cameras again (an iPhone appears when it's nearby, locked and on the same Apple ID)")
                    .accessibilityLabel("Refresh camera list")
            }
            if camera.isRunning {
                Button("Stop camera") { camera.stop() }
            } else {
                Button("Start camera") { Task { await camera.start(deviceID: model.settings.cameraDeviceID) } }
            }
            if let error = camera.error { Text(error).font(.caption).foregroundStyle(.red) }
            if let hardware = camera.hardware { CameraHardwareControls(hardware: hardware) }
        }
    }
}

/// Exposure and gain for a camera that offers them. The exposure slider runs on a log scale, so
/// a fraction of a millisecond and half a second are both easy to reach.
struct CameraHardwareControls: View {
    @Bindable var hardware: CameraHardware

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let range = hardware.exposureRange {
                Toggle("Auto exposure", isOn: $hardware.autoExposure)
                    .help("Off: set the exposure yourself. Long exposures and high gain bring up faint satellites; short ones keep the ISS or the Moon from burning out.")
                if !hardware.autoExposure {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Exposure")
                            Spacer()
                            Text(Self.milliseconds(hardware.exposure)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(get: { log10(hardware.exposure) },
                                              set: { hardware.exposure = Self.rounded(pow(10, $0)) }),
                               in: log10(range.lowerBound)...log10(range.upperBound))
                    }
                }
            }
            if let range = hardware.gainRange {
                LabeledSlider("Gain", value: $hardware.gain, in: range, step: hardware.gainStep, unit: "")
                    .help("The camera's analogue gain. Higher is brighter and noisier.")
            }
        }
    }

    static func milliseconds(_ ms: Double) -> String {
        ms < 1 ? String(format: "%.1f ms", ms) : ms < 10 ? String(format: "%.1f ms", ms) : String(format: "%.0f ms", ms)
    }

    /// To the camera's 0.1 ms steps, and to whole milliseconds above 10.
    static func rounded(_ ms: Double) -> Double {
        ms < 10 ? (ms * 10).rounded() / 10 : ms.rounded()
    }
}

/// The camera image with the centre crosshair and the detected spot, zoom and image adjustments.
struct CameraPreview: View {
    let camera: CameraFeed

    var body: some View {
        GeometryReader { proxy in
            let layout = FrameLayout(frame: camera.frameSize, shown: camera.previewRect, view: proxy.size)
            ZStack {
                Color.black
                if let image = camera.preview {
                    Image(decorative: image, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                }
                Canvas { context, _ in
                    guard layout.scale > 0 else { return }
                    let c = layout.view(camera.centre)
                    var cross = Path()
                    cross.move(to: CGPoint(x: c.x - 14, y: c.y)); cross.addLine(to: CGPoint(x: c.x + 14, y: c.y))
                    cross.move(to: CGPoint(x: c.x, y: c.y - 14)); cross.addLine(to: CGPoint(x: c.x, y: c.y + 14))
                    context.stroke(cross, with: .color(.red), lineWidth: 1)
                    // The area the detector searches.
                    let r = SpotDetector().searchFraction * Double(min(camera.frameSize.width, camera.frameSize.height)) * layout.scale
                    context.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                                   with: .color(.red.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    if let spot = camera.spot {
                        let p = layout.view((spot.x, spot.y))
                        context.stroke(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)),
                                       with: .color(.green), lineWidth: 2)
                    }
                }
                VStack {
                    HStack(alignment: .top) {
                        CameraImageControls(camera: camera, compact: true).padding(6)
                        Spacer()
                        CameraZoomPicker(camera: camera, compact: true).padding(6)
                    }
                    Spacer()
                }
            }
        }
        .aspectRatio(camera.frameSize.width > 0 ? CGFloat(camera.frameSize.width) / CGFloat(camera.frameSize.height) : 16 / 9,
                     contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // Guiding holds the spot on the frame's centre, so zoom in there.
        .onAppear { camera.zoomCentre = (0.5, 0.5) }
        .accessibilityLabel(camera.spot == nil ? "Camera view, no spot found" : "Camera view, spot found")
    }
}

/// Digital zoom, shared by the camera screen and the guiding preview. It crops the camera's
/// full-resolution picture for the preview only; detection still sees the whole frame.
struct CameraZoomPicker: View {
    let camera: CameraFeed
    var compact = false
    @AppStorage("camera.zoom") private var zoom = 1.0
    static let zooms = [1.0, 2, 4, 8]

    var body: some View {
        Picker("Zoom", selection: Binding(
            get: { Self.zooms.min { abs($0 - camera.zoom) < abs($1 - camera.zoom) } ?? 1 },
            set: { camera.zoom = $0 })) {
            ForEach(Self.zooms, id: \.self) { Text("\(Int($0))×").tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(compact ? .mini : .regular)
        .fixedSize()
        .padding(compact ? 2 : 4)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .environment(\.colorScheme, .dark)
        .help("Digital zoom: crops the camera's full-resolution picture (pinch to zoom too on the Camera screen)")
        .onAppear { if camera.zoom != zoom { camera.zoom = zoom } }
        .onChange(of: camera.zoom) { _, new in zoom = new }
    }
}

/// Exposure and the preview's tone, over the top-left of the picture. Compact, the adjustments
/// open in a popover, since the small guiding preview has no room for them on the picture.
struct CameraImageControls: View {
    let camera: CameraFeed
    var compact = false
    @State private var showing = false
    @AppStorage("camera.autoStretch") private var autoStretch = false
    @AppStorage("camera.brightness") private var brightness = 0.0
    @AppStorage("camera.contrast") private var contrast = 1.0
    @AppStorage("camera.holdExposure") private var holdExposure = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showing.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3").padding(compact ? 2 : 4)
            }
            .buttonStyle(.borderless)
            .help("Exposure, brightness and contrast")
            .accessibilityLabel("Image adjustments")
            .popover(isPresented: Binding(get: { compact && showing }, set: { showing = $0 })) {
                adjustments.padding()
            }

            if showing && !compact {
                adjustments
            }
        }
        .padding(compact ? 3 : 6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .onAppear { apply() }
        .onChange(of: autoStretch) { apply() }
        .onChange(of: brightness) { apply() }
        .onChange(of: contrast) { apply() }
        .onChange(of: holdExposure) { apply() }
    }

    private func apply() {
        let tone = PreviewTone(autoStretch: autoStretch, brightness: brightness, contrast: contrast)
        if camera.tone != tone { camera.tone = tone }
        if camera.holdsExposure != holdExposure { camera.holdsExposure = holdExposure }
    }

    private var adjustments: some View {
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
