import CoreGraphics
import CoreVideo
import SkyKit
import Vision

/// Finds the outline of the thing under a tap, so a patch picked on the ground holds the object
/// and as little of the water or field around it as possible. A patch that is mostly background
/// matches the background, which doesn't move.
enum ObjectFinder {
    /// The box, in frame pixels, around whatever is at `point`: a person, a cat or dog, or
    /// whatever Vision thinks stands out there. Nil if nothing does.
    static func box(around point: (x: Double, y: Double), in frame: GrayFrame) async -> CGRect? {
        await Task.detached(priority: .userInitiated) { find(point, frame) }.value
    }

    private static func find(_ point: (x: Double, y: Double), _ frame: GrayFrame) -> CGRect? {
        guard let buffer = pixelBuffer(frame) else { return nil }
        let people = VNDetectHumanRectanglesRequest()
        people.upperBodyOnly = false
        let animals = VNRecognizeAnimalsRequest()
        let salient = VNGenerateObjectnessBasedSaliencyImageRequest()
        try? VNImageRequestHandler(cvPixelBuffer: buffer).perform([people, animals, salient])

        var boxes = (people.results ?? []).map(\.boundingBox) + (animals.results ?? []).map(\.boundingBox)
        boxes += (salient.results ?? []).flatMap { $0.salientObjects ?? [] }.map(\.boundingBox)

        let w = Double(frame.width), h = Double(frame.height)
        // Vision's boxes are fractions of the image, measured up from the bottom.
        let candidates = boxes.map { CGRect(x: $0.minX * w, y: (1 - $0.maxY) * h, width: $0.width * w, height: $0.height * h) }
            .filter { box in
                box.insetBy(dx: -0.1 * box.width, dy: -0.1 * box.height).contains(CGPoint(x: point.x, y: point.y))
                    && box.width >= 8 && box.height >= 8 && box.width * box.height < 0.3 * w * h
            }
        return candidates.min { $0.width * $0.height < $1.width * $1.height }
    }

    private static func pixelBuffer(_ frame: GrayFrame) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, frame.width, frame.height, kCVPixelFormatType_OneComponent8, nil, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        frame.pixels.withUnsafeBytes { source in
            for row in 0..<frame.height {
                (base + row * rowBytes).copyMemory(from: source.baseAddress! + row * frame.width, byteCount: frame.width)
            }
        }
        return buffer
    }
}
