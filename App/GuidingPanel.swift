import SkyKit
import SwiftUI

/// Camera preview, calibration and the guide switch.
struct GuidingPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        @Bindable var guider = model.guider
        let camera = guider.camera
        VStack(alignment: .leading, spacing: 8) {
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
                if camera.isRunning {
                    Button("Stop camera") { camera.stop() }
                } else {
                    Button("Start camera") { Task { await camera.start(deviceID: model.settings.cameraDeviceID) } }
                }
            }
            if let error = camera.error { Text(error).font(.caption).foregroundStyle(.red) }

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

/// The camera image with the centre crosshair and the detected spot.
struct CameraPreview: View {
    let camera: CameraFeed

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let image = camera.preview {
                    Image(decorative: image, scale: 1).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                }
                Canvas { context, size in
                    let (w, h) = (Double(camera.frameSize.width), Double(camera.frameSize.height))
                    guard w > 0, h > 0 else { return }
                    let scale = min(size.width / w, size.height / h)
                    let origin = CGPoint(x: (size.width - w * scale) / 2, y: (size.height - h * scale) / 2)
                    func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: origin.x + x * scale, y: origin.y + y * scale) }

                    let c = point(camera.centre.x, camera.centre.y)
                    var cross = Path()
                    cross.move(to: CGPoint(x: c.x - 14, y: c.y)); cross.addLine(to: CGPoint(x: c.x + 14, y: c.y))
                    cross.move(to: CGPoint(x: c.x, y: c.y - 14)); cross.addLine(to: CGPoint(x: c.x, y: c.y + 14))
                    context.stroke(cross, with: .color(.red), lineWidth: 1)
                    // The area the detector searches.
                    let r = SpotDetector().searchFraction * min(w, h) * scale
                    context.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                                   with: .color(.red.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    if let spot = camera.spot {
                        let p = point(spot.x, spot.y)
                        context.stroke(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)),
                                       with: .color(.green), lineWidth: 2)
                    }
                }
            }
        }
        .aspectRatio(camera.frameSize.width > 0 ? CGFloat(camera.frameSize.width) / CGFloat(camera.frameSize.height) : 16 / 9,
                     contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(camera.spot == nil ? "Camera view, no spot found" : "Camera view, spot found")
    }
}
