import CoreGraphics
import Foundation
import Observation
import SkyKit

/// What camera tracking looks for where you click.
enum CameraTarget: String, CaseIterable, Identifiable {
    /// A spot brighter or darker than plain sky: a satellite, an aircraft.
    case sky
    /// A patch matched by its look, against any background: a boat, a bird, a car, a person.
    case ground

    var id: Self { self }
    var title: String { self == .sky ? "Sky" : "Ground" }
}

/// Camera tracking: click something in the camera image and the mount follows it, keeping it on
/// the aim point. For objects with no prediction to go on (a satellite that isn't in the
/// catalogue, an aircraft, a boat or a bird), or to point an antenna by sight.
@MainActor @Observable
final class CameraTracker {
    weak var app: AppModel?
    let camera: CameraFeed

    /// What's being followed in the image; nil when nothing is picked.
    private(set) var tracker: (any ImageTracker)?
    /// Sky objects or things on the ground.
    var target = CameraTarget(rawValue: UserDefaults.standard.string(forKey: "camera.target") ?? "") ?? .sky {
        didSet { UserDefaults.standard.set(target.rawValue, forKey: "camera.target") }
    }
    /// Move the mount to follow it, or only follow it in the image.
    var drivesMount = true {
        didSet {
            guard drivesMount != oldValue, !isCalibrating else { return }
            Task { drivesMount ? await followIfReady() : await stopFollowing() }
        }
    }
    private var isCalibrating = false
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
    func click(at point: (x: Double, y: Double), radius: Double = 30) async {
        if settingAim {
            let size = camera.frameSize
            guard size.width > 1, size.height > 1 else { return }
            app?.settings.cameraAimX = min(max(point.x / Double(size.width - 1), 0), 1)
            app?.settings.cameraAimY = min(max(point.y / Double(size.height - 1), 0), 1)
            settingAim = false
            message = "Aim point set."
            return
        }
        await pick(at: point, radius: radius)
    }

    private var latestFrame: GrayFrame?

    /// The largest patch matched on the ground, pixels a side; bigger is slow and gains nothing.
    private static let largestPatch = 160.0

    func pick(at point: (x: Double, y: Double), radius: Double = 30) async {
        guard let frame = latestFrame else {
            message = "Start the camera first."
            return
        }
        switch target {
        case .sky:
            guard let picked = MovingObjectTracker(frame: frame, at: point, radius: radius) else {
                message = "Nothing stands out from the sky there. Click right on it."
                return
            }
            await start(picked, frame, picked.blob.polarity > 0 ? "Locked on a bright object." : "Locked on a dark object.")
        case .ground:
            // The outline of what's there if Vision finds one, else a square about the size of the click.
            if let box = await ObjectFinder.box(around: point, in: frame) {
                await pick(box: box, in: frame, note: "Locked on it. If it slips, drag a box around it instead.")
            } else {
                let side = 4 * radius
                await pick(box: CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side), in: frame,
                           note: "Locked on the area clicked. Drag a box around the object for a closer fit.")
            }
        }
    }

    /// A box dragged around something, in frame pixels.
    func pick(box: CGRect) async {
        guard let frame = latestFrame else {
            message = "Start the camera first."
            return
        }
        await pick(box: box, in: frame, note: "Locked on it.")
    }

    private func pick(box: CGRect, in frame: GrayFrame, note: String) async {
        let width = Int(min(box.width, Self.largestPatch)), height = Int(min(box.height, Self.largestPatch))
        guard let picked = PatchTracker(frame: frame, centre: (box.midX, box.midY), width: width, height: height) else {
            message = "There's too little detail there to hold on to. Drag a box around the object."
            return
        }
        await start(picked, frame, note)
    }

    private func start(_ picked: any ImageTracker, _ frame: GrayFrame, _ note: String) async {
        tracker = picked
        estimator.reset()
        lastFrame = frame.timestamp
        lastMountAxes = mount?.axes(at: frame.timestamp)
        message = note
        await followIfReady()
    }

    /// Starts the mount following the picked object, if it can.
    func followIfReady() async {
        guard drivesMount, driveBlocker == nil, let mount, !mount.tracksCamera, tracker != nil, !isLost else { return }
        if mount.isTracking { await mount.stopAll() }
        await mount.trackCamera(self)
    }

    private func stopFollowing() async {
        if let mount, mount.tracksCamera { await mount.stopAll() }
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
        defer { centreZoom(frame) }
        guard var tracker else { return }
        let guiding = isCalibrating || app?.guider.isCalibrating == true
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
        let found = tracker.follow(frame, mountShift: shift)
        self.tracker = tracker

        // Where the target is in axis coordinates: where the mount pointed plus the move that
        // would bring the target to the aim point.
        if found, tracker.hits >= 2, !guiding, let calibration, let axes {
            let aim = aimPoint
            if let move = calibration.axisCorrection(offset: (tracker.x - aim.x, tracker.y - aim.y), altitude: altitude) {
                estimator.add(AxisPosition(primary: axes.primary + move.primary, secondary: axes.secondary + move.secondary),
                              at: frame.timestamp)
            }
        }
        if tracker.state == .lost, !wasLost { message = "Lost it. Click it again to pick it up." }
    }

    /// Zoomed in, the view stays on the aim point. Following the object made the whole picture
    /// jump whenever the box hopped, with the mount still; once the mount follows, the object
    /// sits on the aim point anyway.
    private func centreZoom(_ frame: GrayFrame) {
        guard camera.zoom > 1, frame.width > 1, frame.height > 1 else { return }
        let p = aimPoint
        let centre = (x: p.x / Double(frame.width - 1), y: p.y / Double(frame.height - 1))
        if hypot(centre.x - camera.zoomCentre.x, centre.y - camera.zoomCentre.y) > 0.002 { camera.zoomCentre = centre }
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

    /// Calibrates on whatever is picked, which must be fixed: a star, or a distant light, mast or building.
    func calibrate() async {
        guard let app, tracker != nil else {
            message = "Click something that isn't moving first (a star, a distant light, mast or building), then calibrate."
            return
        }
        isCalibrating = true
        defer { isCalibrating = false }
        if let mount, mount.tracksCamera { await mount.stopAll() }
        await app.guider.calibrate { [weak self] in
            guard let t = self?.tracker, t.state == .locked else { return nil }
            return (t.x, t.y)
        }
        message = app.guider.status
        // Calibrated on something fixed: nothing to follow until a moving object is picked.
    }
}
