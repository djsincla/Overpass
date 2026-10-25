import Foundation
import Observation
import SkyKit

/// Camera tracking: click something in the camera image and the mount follows it, keeping it on
/// the aim point. For objects with no prediction to go on (a satellite that isn't in the
/// catalogue, an aircraft), or to point an antenna by sight.
@MainActor @Observable
final class CameraTracker {
    weak var app: AppModel?
    let camera: CameraFeed

    /// What's being followed in the image; nil when nothing is picked.
    private(set) var tracker: MovingObjectTracker?
    /// Move the mount to follow it, or only follow it in the image.
    var drivesMount = true
    /// The next click sets the aim point instead of picking an object.
    var settingAim = false
    private(set) var message = ""

    private var estimator = MotionEstimator()
    private var lastFrame: Date?
    private var lastMountAxes: AxisPosition?

    init(camera: CameraFeed) {
        self.camera = camera
        camera.onImage = { [weak self] frame in self?.handle(frame) }
    }

    private var mount: MountSession? { app?.mount }
    private var calibration: CameraCalibration? { app?.settings.cameraCalibration }

    /// Seconds out of sight before giving up.
    var coastLimit: TimeInterval { tracker?.coastLimit ?? 2 }
    var isLost: Bool { tracker == nil || tracker?.state == .lost }

    /// Where the telescope points in the image, in frame pixels. The centre unless set, since a
    /// finder or a camera off the main tube's axis sees the target somewhere else.
    var aimPoint: (x: Double, y: Double) {
        let size = camera.frameSize
        let s = app?.settings
        return ((s?.cameraAimX ?? 0.5) * Double(max(size.width - 1, 0)), (s?.cameraAimY ?? 0.5) * Double(max(size.height - 1, 0)))
    }

    /// Why the mount can't follow yet, or nil if it can.
    var driveBlocker: String? {
        guard let mount, mount.state == .connected, mount.kind == .usb else {
            return "Connect the mount by USB in Special mode to move it."
        }
        if calibration == nil { return "Calibrate first, so Overpass knows how the image moves with the mount." }
        return nil
    }

    // MARK: Picking

    /// A click in the image, in frame pixels.
    func click(at point: (x: Double, y: Double)) async {
        if settingAim {
            let size = camera.frameSize
            guard size.width > 1, size.height > 1 else { return }
            app?.settings.cameraAimX = min(max(point.x / Double(size.width - 1), 0), 1)
            app?.settings.cameraAimY = min(max(point.y / Double(size.height - 1), 0), 1)
            settingAim = false
            message = "Aim point set."
            return
        }
        await pick(at: point)
    }

    private var latestFrame: GrayFrame?

    func pick(at point: (x: Double, y: Double)) async {
        guard let frame = latestFrame else {
            message = "Start the camera first."
            return
        }
        guard let picked = MovingObjectTracker(frame: frame, at: point, radius: 30) else {
            message = "Nothing stands out from the sky there. Click right on it."
            return
        }
        tracker = picked
        estimator.reset()
        lastFrame = frame.timestamp
        lastMountAxes = mount?.axes(at: frame.timestamp)
        message = picked.blob.polarity > 0 ? "Locked on a bright object." : "Locked on a dark object."
        if drivesMount, driveBlocker == nil, let mount, !mount.tracksCamera {
            if mount.isTracking { await mount.stopAll() }
            await mount.trackCamera(self)
        }
    }

    /// Lets go of the object and stops the mount if it was following it.
    func release() async {
        tracker = nil
        estimator.reset()
        message = ""
        if let mount, mount.tracksCamera { await mount.stopAll() }
    }

    func resetAim() {
        app?.settings.cameraAimX = 0.5
        app?.settings.cameraAimY = 0.5
    }

    // MARK: Frames

    private func handle(_ frame: GrayFrame) {
        latestFrame = frame
        guard var tracker else { return }
        let guiding = app?.guider.isCalibrating == true
        let axes = mount?.axes(at: frame.timestamp)
        let altitude = mount?.skyPosition?.altitude ?? 45

        // How the mount's own motion moved the image since the last frame. Not while calibrating,
        // when the calibration being measured is the thing that isn't known.
        var shift = (x: 0.0, y: 0.0)
        if !guiding, let calibration, let axes, let before = lastMountAxes {
            shift = calibration.imageShift(primary: axes.primary - before.primary,
                                           secondary: axes.secondary - before.secondary, altitude: altitude)
        }
        lastFrame = frame.timestamp
        lastMountAxes = axes

        let wasLost = tracker.state == .lost
        let seen = tracker.update(frame, mountShift: shift)
        self.tracker = tracker

        // Where the target is in axis coordinates: where the mount pointed plus the move that
        // would bring the target to the aim point.
        if let seen, tracker.hits >= 2, !guiding, let calibration, let axes {
            let aim = aimPoint
            if let move = calibration.axisCorrection(offset: (seen.x - aim.x, seen.y - aim.y), altitude: altitude) {
                estimator.add(AxisPosition(primary: axes.primary + move.primary, secondary: axes.secondary + move.secondary),
                              at: frame.timestamp)
            }
        }
        if tracker.state == .lost, !wasLost { message = "Lost it. Click it again to pick it up." }
    }

    /// For the mount loop: where the target is at `date`, in axis coordinates.
    func estimate(at date: Date) -> MotionEstimator.Estimate? {
        guard tracker != nil, !isLost else { return nil }
        return estimator.estimate(at: date)
    }

    /// The target's offset from the aim point, arc-minutes, when calibrated.
    var offsetArcminutes: Double? {
        guard let tracker, tracker.state == .locked, let calibration else { return nil }
        let aim = aimPoint
        return hypot(tracker.x - aim.x, tracker.y - aim.y) * calibration.arcsecondsPerPixel / 60
    }

    // MARK: Calibration

    /// Calibrates on whatever is picked, which must be fixed: a star, or a distant light or mast.
    func calibrate() async {
        guard let app, tracker != nil else {
            message = "Click something that isn't moving first (a star, a distant light or mast), then calibrate."
            return
        }
        let drove = drivesMount
        drivesMount = false
        if let mount, mount.tracksCamera { await mount.stopAll() }
        await app.guider.calibrate { [weak self] in
            guard let t = self?.tracker, t.state == .locked else { return nil }
            return (t.x, t.y)
        }
        message = app.guider.status
        drivesMount = drove
    }
}
