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
            try await capture.start(deviceID: id)
            isRunning = true
        } catch {
            self.error = "Couldn't open the camera: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard isRunning else { return }
        capture.stop()
        isRunning = false
        spot = nil
        preview = nil
    }

    private func receive(_ result: FrameResult) {
        if frameSize != (result.width, result.height) { frameSize = (result.width, result.height) }
        if let image = result.preview { preview = image }
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

    func start(deviceID: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.configure(deviceID: deviceID)
                    self.session.startRunning()
                    continuation.resume()
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
        if now.timeIntervalSince(lastPreview) >= 1.0 / 15 {
            lastPreview = now
            preview = Self.image(pixels, w, h)
        }
        handler?(FrameResult(spotChecked: checksSpot, spot: spot, frame: deliversFrames ? frame : nil,
                             width: w, height: h, timestamp: timestamp, preview: preview))
    }

    static func image(_ pixels: [UInt8], _ width: Int, _ height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
