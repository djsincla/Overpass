import AVFoundation
import CoreGraphics
import Observation
import SkyKit

/// One processed frame, handed from the capture queue to the main actor.
struct FrameResult: @unchecked Sendable {
    let spot: Spot?
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
    /// Called for every processed frame.
    var onFrame: ((Spot?, Date) -> Void)?

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
        spot = result.spot
        frameSize = (result.width, result.height)
        if let image = result.preview { preview = image }
        onFrame?(result.spot, result.timestamp)
    }

    var centre: (x: Double, y: Double) { (Double(frameSize.width - 1) / 2, Double(frameSize.height - 1) / 2) }
}

/// Runs on its own queue: the capture session, downsampling and spot finding.
private final class CaptureController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "overpass.camera")
    var handler: (@Sendable (FrameResult) -> Void)?
    private let session = AVCaptureSession()
    private let detector = SpotDetector()
    private var count = 0
    private var lastProcessed = Date.distantPast

    static func availableDevices() -> [(id: String, name: String)] {
        #if os(macOS)
        let types: [AVCaptureDevice.DeviceType] = [.continuityCamera, .external, .builtInWideAngleCamera]
        #else
        let types: [AVCaptureDevice.DeviceType] = [.builtInTelephotoCamera, .builtInWideAngleCamera]
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
        // About 10 corrections a second is plenty, and leaves headroom on slower Macs.
        let now = Date()
        guard now.timeIntervalSince(lastProcessed) >= 0.09,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastProcessed = now

        // When the light arrived, not when the frame reached us: Continuity Camera adds ~0.1–0.2 s.
        let captured = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let age = CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), captured))
        let timestamp = (0...2).contains(age) ? now - age : now

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)

        // Keep it under ~960 pixels wide; a bright spot survives taking every n-th pixel.
        let step = max(1, (width + 959) / 960)
        let w = width / step, h = height / step
        var pixels = [UInt8](repeating: 0, count: w * h)
        let source = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            let row = source + y * step * rowBytes
            for x in 0..<w { pixels[y * w + x] = row[x * step] }
        }
        let spot = detector.find(in: GrayFrame(width: w, height: h, pixels: pixels, timestamp: timestamp))

        count += 1
        let preview = count % 3 == 0 ? Self.image(pixels, w, h) : nil
        handler?(FrameResult(spot: spot, width: w, height: h, timestamp: timestamp, preview: preview))
    }

    static func image(_ pixels: [UInt8], _ width: Int, _ height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
