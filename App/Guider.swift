import Foundation
import Observation
import SkyKit

/// Keeps the target centred in the camera by adjusting the tracker's fine-tune offsets.
/// Works with Smooth tracking (USB, Special mode); Step mode jumps too much to correct.
@MainActor @Observable
final class Guider {
    weak var app: AppModel?
    let camera = CameraFeed()

    var isGuiding = false { didSet { if !isGuiding { lostFrames = 0 } } }
    private(set) var isCalibrating = false
    private(set) var status = ""
    /// Latest measured distance from the centre, arc-minutes.
    private(set) var errorArcmin: Double?

    private var guide = OpticalGuide()
    private var lostFrames = 0

    init() {
        camera.onFrame = { [weak self] spot, timestamp in self?.handle(spot, timestamp) }
    }

    private var mount: MountSession? { app?.mount }

    var canGuide: Bool {
        app?.settings.cameraCalibration != nil && mount?.trackingMode == .smooth
    }

    // MARK: Guiding

    private func handle(_ spot: Spot?, _ timestamp: Date) {
        guard let app, let mount, let calibration = app.settings.cameraCalibration else { return }
        let centre = camera.centre
        if let spot {
            let offset = (x: spot.x - centre.x, y: spot.y - centre.y)
            errorArcmin = (offset.x * offset.x + offset.y * offset.y).squareRoot() * calibration.arcsecondsPerPixel / 60
        } else {
            errorArcmin = nil
        }
        guard isGuiding, mount.trackingMode == .smooth, let object = mount.trackingObject else { return }
        guard let spot else {
            lostFrames += 1
            status = lostFrames > 10 ? "Lost the target; holding the last corrections" : "Searching…"
            return
        }
        lostFrames = 0

        do {
            // Where the target was when this frame was taken, by the tracker's own clock.
            let track = try app.settings.observer.track(object.target, at: timestamp + mount.timeOffset)
            guard let correction = calibration.axisCorrection(offset: (spot.x - camera.centre.x, spot.y - camera.centre.y),
                                                              altitude: track.position.altitude) else { return }
            // Calibration is in axis degrees; the tracker's offsets are sky azimuth and altitude.
            // They differ in sign when an axis counts the other way (iOptron's altitude axis
            // counts from the zenith, so it runs opposite to altitude).
            let sense = app.settings.alignment?.azimuthSense ?? 1
            let altitudeSense = app.settings.alignment?.altitudeSense ?? 1
            let current = OpticalGuide.Update(timeOffset: mount.timeOffset,
                                              azimuthOffset: sense * mount.azimuthOffset,
                                              altitudeOffset: altitudeSense * mount.altitudeOffset)
            let next = guide.update(current, correction: correction,
                                    azimuthRate: sense * track.azimuthRate, altitudeRate: altitudeSense * track.altitudeRate,
                                    altitude: track.position.altitude)
            mount.timeOffset = next.timeOffset
            mount.azimuthOffset = sense * next.azimuthOffset
            mount.altitudeOffset = altitudeSense * next.altitudeOffset
            status = String(format: "Guiding · off by %.1f′ · time %+.2f s", errorArcmin ?? 0, next.timeOffset)
        } catch {
            status = "Guiding paused: \(error.localizedDescription)"
        }
    }

    // MARK: Calibration

    /// With a bright star centred and the mount still, nudge each axis and watch how the image
    /// moves. That gives the camera's rotation, mirroring and scale relative to the mount.
    func calibrate() async {
        guard let app, let mount, !isCalibrating else { return }
        guard mount.kind == .usb, !mount.isTracking else {
            status = "Calibrate over USB, with tracking stopped and a bright star centred."
            return
        }
        isCalibrating = true
        isGuiding = false
        defer { isCalibrating = false }
        do {
            let altitude = mount.skyPosition?.altitude ?? 45
            let primary = try await measure(primaryRate: 0.1, secondaryRate: 0)
            let secondary = try await measure(primaryRate: 0, secondaryRate: 0.1)
            let calibration = CameraCalibration(primaryShift: primary.shift, primaryDegrees: primary.degrees,
                                                secondaryShift: secondary.shift, secondaryDegrees: secondary.degrees,
                                                altitude: altitude)
            guard !calibration.isDegenerate else { throw GuiderError.degenerate }
            app.settings.cameraCalibration = calibration
            status = String(format: "Calibrated · %.1f″ per pixel · rotated %.0f°", calibration.arcsecondsPerPixel, calibration.rotation)
        } catch {
            try? await mount.stopMotion()
            status = (error as? GuiderError)?.message ?? "Calibration failed: \(error.localizedDescription)"
        }
    }

    /// Moves one axis until the spot has shifted a clear distance (or 10 s pass), then moves back.
    private func measure(primaryRate: Double, secondaryRate: Double) async throws -> (shift: (x: Double, y: Double), degrees: Double) {
        guard let mount else { throw GuiderError.noMount }
        let start = try await averageSpot()
        guard let axesBefore = try await mount.currentAxes() else { throw GuiderError.noMount }

        status = "Calibrating: moving \(primaryRate != 0 ? "azimuth" : "altitude")…"
        try await mount.moveAxes(primary: primaryRate, secondary: secondaryRate)
        let began = Date.now
        while Date.now.timeIntervalSince(began) < 10 {
            try await Task.sleep(for: .milliseconds(150))
            if let spot = camera.spot, hypot(spot.x - start.x, spot.y - start.y) > 40 { break }
            if camera.spot == nil && Date.now.timeIntervalSince(began) > 2 { break }
        }
        let elapsed = Date.now.timeIntervalSince(began)
        try await mount.stopMotion()
        try await Task.sleep(for: .milliseconds(800))
        let end = try await averageSpot()
        guard let axesAfter = try await mount.currentAxes() else { throw GuiderError.noMount }

        // Back to where we started, so the second axis is measured from the centre too.
        try await mount.moveAxes(primary: -primaryRate, secondary: -secondaryRate)
        try await Task.sleep(for: .seconds(elapsed))
        try await mount.stopMotion()
        try await Task.sleep(for: .milliseconds(800))

        let degrees = primaryRate != 0 ? axesAfter.primary - axesBefore.primary : axesAfter.secondary - axesBefore.secondary
        let shift = (x: end.x - start.x, y: end.y - start.y)
        guard abs(degrees) > 0.01, hypot(shift.x, shift.y) > 5 else { throw GuiderError.tooLittleMotion }
        return (shift, degrees)
    }

    /// The spot position averaged over a few frames, to beat down seeing and noise.
    private func averageSpot() async throws -> (x: Double, y: Double) {
        var xs: [Double] = [], ys: [Double] = []
        for _ in 0..<12 {
            if let spot = camera.spot {
                xs.append(spot.x)
                ys.append(spot.y)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard xs.count >= 4 else { throw GuiderError.noSpot }
        return (xs.reduce(0, +) / Double(xs.count), ys.reduce(0, +) / Double(ys.count))
    }
}

enum GuiderError: Error {
    case noSpot, noMount, tooLittleMotion, degenerate

    var message: String {
        switch self {
        case .noSpot: "Can't see a bright spot near the centre. Centre a bright star and check focus and exposure."
        case .noMount: "Connect the mount by USB first."
        case .tooLittleMotion: "The star barely moved. Check the camera is fixed to the tube and the mount is moving."
        case .degenerate: "Both axes moved the image the same way; check the camera is fixed to the tube and try again."
        }
    }
}
