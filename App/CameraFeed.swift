import Accelerate
import AVFoundation
import CoreGraphics
import Observation
import SkyKit

/// One processed frame, handed from the capture queue to the main actor.
struct FrameResult: @unchecked Sendable {
    /// Only on frames the spot finder ran on (about ten a second); nil otherwise.
    let spotChecked: Bool
    let spot: Spot?
    /// The whole frame, when something wants every frame (camera tracking).
    let frame: GrayFrame?
    let width: Int
    let height: Int
    let timestamp: Date
    /// Only on some frames; previews needn't keep up with guiding.
    let preview: CGImage?
    /// The part of the frame the preview shows, in frame pixels (all of it unless zoomed).
    let previewRect: CGRect
}

/// How the preview is shown. Display only: detection measures objects against their local
/// background noise, which a tone curve can't improve.
struct PreviewTone: Equatable, Sendable {
    /// Spread the frame's own darkest to brightest across the full range (lifts a faint night sky).
    var autoStretch = false
    /// −0.5 to 0.5, added after contrast.
    var brightness = 0.0
    /// 1 leaves it as it is.
    var contrast = 1.0
}

/// Live frames from a camera, reduced to grayscale and searched for the guide spot.
/// On a Mac this includes an iPhone through Continuity Camera.
@MainActor @Observable
final class CameraFeed {
    private(set) var devices: [(id: String, name: String)] = []
    private(set) var isRunning = false
    private(set) var preview: CGImage?
    private(set) var spot: Spot?
    /// Size of the frames the spot is measured in (after downsampling).
    private(set) var frameSize = (width: 0, height: 0)
    /// The part of the frame `preview` shows, in frame pixels.
    private(set) var previewRect = CGRect.zero
    /// Digital zoom for the preview (1 is the whole frame). It crops the camera's full-resolution
    /// picture, so 2× is still sharp on a 1080p camera; tracking always sees the whole frame.
    var zoom = 1.0 {
        didSet { capture.setZoom(zoom, centre: zoomCentre) }
    }
    /// The preview's tone curve.
    var tone = PreviewTone() {
        didSet { capture.setTone(tone) }
    }
    /// Whether this camera can freeze its exposure (most webcams offer only that and auto).
    private(set) var canHoldExposure = false
    /// Manual exposure and gain, for a USB camera that offers them (Mac only).
    private(set) var hardware: CameraHardware?
    /// Freeze the exposure where it is, so a bright object entering the view doesn't darken the rest.
    var holdsExposure = false {
        didSet { capture.setHoldsExposure(holdsExposure) }
    }
    /// Where the zoom centres, as fractions of the frame's width and height.
    var zoomCentre = (x: 0.5, y: 0.5) {
        didSet { capture.setZoom(zoom, centre: zoomCentre) }
    }
    private(set) var error: String?
    /// Called each time the spot finder runs, about ten times a second.
    var onFrame: ((Spot?, Date) -> Void)?
    /// Called with every frame while `deliversFrames` is on.
    var onImage: ((GrayFrame) -> Void)?
    /// Hand over every frame, at the camera's full rate, for camera tracking.
    var deliversFrames = false {
        didSet { capture.setDeliversFrames(deliversFrames) }
    }

    /// Owns the capture session; everything AVFoundation happens on its queue.
    private let capture = CaptureController()

    func refreshDevices() {
        devices = CaptureController.availableDevices()
    }

    func start(deviceID: String?) async {
        stop()
        error = nil
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            error = "Camera access is off. Turn it on in System Settings → Privacy & Security → Camera."
            return
        }
        refreshDevices()
        guard let id = devices.first(where: { $0.id == deviceID })?.id ?? devices.first?.id else {
            error = "No camera found. For an iPhone: keep it near the Mac, unlocked, signed in to the same Apple ID."
            return
        }
        capture.handler = { [weak self] result in
            Task { @MainActor in self?.receive(result) }
        }
        do {
            canHoldExposure = try await capture.start(deviceID: id)
            hardware = AVCaptureDevice(uniqueID: id).flatMap { CameraHardware(uniqueID: $0.uniqueID, modelID: $0.modelID) }
            if let hardware {
                // Real exposure control replaces holding the auto exposure.
                canHoldExposure = false
                hardware.apply()
                // Starting the session can put the camera back on auto a moment later.
                Task { try? await Task.sleep(for: .seconds(1)); hardware.apply() }
            } else {
                capture.setHoldsExposure(holdsExposure && canHoldExposure)
            }
            isRunning = true
        } catch {
            self.error = "Couldn't open the camera: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard isRunning else { return }
        capture.stop()
        isRunning = false
        hardware = nil
        spot = nil
        preview = nil
    }

    private func receive(_ result: FrameResult) {
        if frameSize != (result.width, result.height) { frameSize = (result.width, result.height) }
        if let image = result.preview {
            preview = image
            if previewRect != result.previewRect { previewRect = result.previewRect }
        }
        if let frame = result.frame { onImage?(frame) }
        if result.spotChecked {
            spot = result.spot
            onFrame?(result.spot, result.timestamp)
        }
    }

    var centre: (x: Double, y: Double) { (Double(frameSize.width - 1) / 2, Double(frameSize.height - 1) / 2) }
}

/// Runs on its own queue: the capture session, downsampling and spot finding.
private final class CaptureController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "overpass.camera")
    var handler: (@Sendable (FrameResult) -> Void)?
    private let session = AVCaptureSession()
    private let detector = SpotDetector()
    private var lastSpotCheck = Date.distantPast
    private var lastPreview = Date.distantPast
    private var deliversFrames = false

    func setDeliversFrames(_ on: Bool) {
        queue.async { self.deliversFrames = on }
    }

    private var zoom = 1.0
    private var zoomCentre = (x: 0.5, y: 0.5)
    private var tone = PreviewTone()
    private var device: AVCaptureDevice?

    func setTone(_ tone: PreviewTone) {
        queue.async { self.tone = tone }
    }

    func setHoldsExposure(_ hold: Bool) {
        queue.async {
            guard let device = self.device else { return }
            let mode: AVCaptureDevice.ExposureMode = hold ? .locked : .continuousAutoExposure
            guard device.isExposureModeSupported(mode), (try? device.lockForConfiguration()) != nil else { return }
            device.exposureMode = mode
            device.unlockForConfiguration()
        }
    }

    func setZoom(_ zoom: Double, centre: (x: Double, y: Double)) {
        queue.async {
            self.zoom = max(1, zoom)
            self.zoomCentre = centre
        }
    }

    static func availableDevices() -> [(id: String, name: String)] {
        #if os(macOS)
        let types: [AVCaptureDevice.DeviceType] = [.continuityCamera, .external, .builtInWideAngleCamera]
        #else
        // External covers a USB webcam plugged into an iPad.
        let types: [AVCaptureDevice.DeviceType] = [.external, .builtInTelephotoCamera, .builtInWideAngleCamera]
        #endif
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
            .devices.map { ($0.uniqueID, $0.localizedName) }
    }

    /// Returns whether the camera can hold its exposure.
    func start(deviceID: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            queue.async {
                do {
                    try self.configure(deviceID: deviceID)
                    self.session.startRunning()
                    let device = self.device
                    continuation.resume(returning: device.map {
                        $0.isExposureModeSupported(.locked) && $0.isExposureModeSupported(.continuousAutoExposure)
                    } ?? false)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }

    private func configure(deviceID: String) throws {
        guard let device = AVCaptureDevice(uniqueID: deviceID) else { throw CocoaError(.featureUnsupported) }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.addInput(try AVCaptureDeviceInput(device: device))
        self.device = device
        let output = AVCaptureVideoDataOutput()
        // The luma plane of 4:2:0 video is already a grayscale image.
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // About 10 spot checks a second is plenty for guiding; camera tracking takes every frame.
        let now = Date()
        let checksSpot = now.timeIntervalSince(lastSpotCheck) >= 0.09
        guard checksSpot || deliversFrames, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // When the light arrived, not when the frame reached us: Continuity Camera adds ~0.1–0.2 s.
        let captured = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let age = CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), captured))
        let timestamp = (0...2).contains(age) ? now - age : now

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)

        // Keep it under ~960 pixels wide. Scaling averages neighbouring pixels, so a faint point
        // keeps its light; taking every n-th pixel could skip it entirely.
        let step = max(1, (width + 959) / 960)
        let w = width / step, h = height / step
        var pixels = [UInt8](repeating: 0, count: w * h)
        pixels.withUnsafeMutableBytes { raw in
            guard let out = raw.baseAddress else { return }
            if step == 1 {
                for y in 0..<h { memcpy(out + y * w, base + y * rowBytes, w) }
            } else {
                var source = vImage_Buffer(data: base, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
                var destination = vImage_Buffer(data: out, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                vImageScale_Planar8(&source, &destination, nil, vImage_Flags(kvImageNoFlags))
            }
        }
        let frame = GrayFrame(width: w, height: h, pixels: pixels, timestamp: timestamp)
        var spot: Spot?
        if checksSpot {
            lastSpotCheck = now
            spot = detector.find(in: frame)
        }
        // About 15 previews a second: smooth enough to click on something moving.
        var preview: CGImage?
        var previewRect = CGRect(x: 0, y: 0, width: w, height: h)
        if now.timeIntervalSince(lastPreview) >= 1.0 / 15 {
            lastPreview = now
            if zoom > 1 {
                // Crop the full-resolution picture, keeping its shape and staying inside it.
                let cw = Int(Double(width) / zoom), ch = Int(Double(height) / zoom)
                let cx = min(max(Int(zoomCentre.x * Double(width)) - cw / 2, 0), width - cw)
                let cy = min(max(Int(zoomCentre.y * Double(height)) - ch / 2, 0), height - ch)
                preview = Self.crop(base.assumingMemoryBound(to: UInt8.self), rowBytes: rowBytes, x: cx, y: cy, width: cw, height: ch, tone: tone)
                let k = Double(w) / Double(width)
                previewRect = CGRect(x: Double(cx) * k, y: Double(cy) * k, width: Double(cw) * k, height: Double(ch) * k)
            } else {
                preview = Self.image(pixels, w, h, tone: tone)
            }
        }
        handler?(FrameResult(spotChecked: checksSpot, spot: spot, frame: deliversFrames ? frame : nil,
                             width: w, height: h, timestamp: timestamp, preview: preview, previewRect: previewRect))
    }

    /// A region of the full-resolution luma plane, scaled down if it's wider than 960 pixels.
    static func crop(_ base: UnsafePointer<UInt8>, rowBytes: Int, x: Int, y: Int, width: Int, height: Int, tone: PreviewTone) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let step = max(1, (width + 959) / 960)
        let w = width / step, h = height / step
        var pixels = [UInt8](repeating: 0, count: w * h)
        pixels.withUnsafeMutableBytes { raw in
            guard let out = raw.baseAddress else { return }
            let start = UnsafeMutableRawPointer(mutating: base + y * rowBytes + x)
            if step == 1 {
                for row in 0..<h { memcpy(out + row * w, start + row * rowBytes, w) }
            } else {
                var source = vImage_Buffer(data: start, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
                var destination = vImage_Buffer(data: out, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                vImageScale_Planar8(&source, &destination, nil, vImage_Flags(kvImageNoFlags))
            }
        }
        return image(pixels, w, h, tone: tone)
    }

    /// The grey levels the preview shows for each level the camera gave, or nil to leave them.
    static func toneTable(_ tone: PreviewTone, _ pixels: [UInt8]) -> [UInt8]? {
        guard tone != PreviewTone() else { return nil }
        var low = 0.0, high = 255.0
        if tone.autoStretch {
            var sample = Swift.stride(from: 0, to: pixels.count, by: max(1, pixels.count / 20_000)).map { pixels[$0] }
            sample.sort()
            low = Double(sample[sample.count / 100])
            high = max(Double(sample[min(sample.count - 1, sample.count * 997 / 1000)]), low + 8)
        }
        return (0..<256).map { v in
            let n = ((Double(v) - low) / (high - low) - 0.5) * tone.contrast + 0.5 + tone.brightness
            return UInt8(min(max(n * 255, 0), 255).rounded())
        }
    }

    static func image(_ pixels: [UInt8], _ width: Int, _ height: Int, tone: PreviewTone = PreviewTone()) -> CGImage? {
        var pixels = pixels
        if let table = toneTable(tone, pixels) {
            pixels.withUnsafeMutableBytes { raw in
                var buffer = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                vImageTableLookUp_Planar8(&buffer, &buffer, table, vImage_Flags(kvImageNoFlags))
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
