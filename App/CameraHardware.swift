import Foundation
import Observation
import UVCControl

/// Manual exposure and gain on a USB video camera that offers them, such as iOptron's iPolar
/// (1280×960, 0.1–500 ms, gain 64–480). AVFoundation on a Mac only offers auto exposure or
/// holding it, so these go to the camera as standard UVC requests. Settings are kept per camera.
/// Measured on an iPolar, 26 Oct 2026: 1 ms read a mean of 33 and 200 ms saturated at 236 where
/// auto exposure sat at 231, so the camera does what it's told (a cheap webcam ignored it).
@MainActor @Observable
final class CameraHardware {
    /// Shortest and longest manual exposure, milliseconds.
    let exposureRange: ClosedRange<Double>?
    let gainRange: ClosedRange<Double>?
    let gainStep: Double

    /// The camera chooses the exposure. Off, `exposure` and `gain` apply.
    var autoExposure: Bool { didSet { apply(); save() } }
    /// Milliseconds.
    var exposure: Double { didSet { apply(); save() } }
    var gain: Double { didSet { apply(); save() } }

    private let camera: Handle
    private let key: String
    private let manualMode: UInt32
    private let autoMode: UInt32
    /// Requests go out here, in order, off the main thread.
    private let queue = DispatchQueue(label: "overpass.uvc")

    /// The UVC handle, closed when the last reference goes.
    private final class Handle: @unchecked Sendable {
        let pointer: OpaquePointer
        init(_ pointer: OpaquePointer) { self.pointer = pointer }
        deinit { uvc_close(pointer) }
    }

    // UVC selectors: camera terminal, then processing unit.
    private static let autoExposureMode: Int32 = 0x02
    private static let exposureTime: Int32 = 0x04
    private static let gainControl: Int32 = 0x04

    /// The controls for the camera AVFoundation calls `uniqueID` and `modelID`, if it has any.
    /// On a Mac those carry the USB location, vendor and product ("0x14000012331455",
    /// "UVC Camera VendorID_4659 ProductID_5205").
    init?(uniqueID: String, modelID: String) {
        guard let ids = Self.usbIDs(uniqueID: uniqueID, modelID: modelID),
              let pointer = uvc_open(ids.location, ids.vendor, ids.product) else { return nil }
        camera = Handle(pointer)
        key = "camera.\(modelID)"

        func read(_ request: UVCGet, _ unit: UVCUnit, _ selector: Int32, _ length: Int32) -> UInt32? {
            var value: UInt32 = 0
            return uvc_get(pointer, request, unit, selector, length, &value) == 0 ? value : nil
        }
        // Bit 3 of the terminal's controls is exposure time; bit 9 of the processing unit's is gain.
        let terminal = uvc_controls(pointer, UVCUnitTerminal), processing = uvc_controls(pointer, UVCUnitProcessing)
        if terminal & (1 << 3) != 0,
           let low = read(UVCGetMinimum, UVCUnitTerminal, Self.exposureTime, 4),
           let high = read(UVCGetMaximum, UVCUnitTerminal, Self.exposureTime, 4), high > low {
            exposureRange = Double(low) / 10...Double(high) / 10
        } else {
            exposureRange = nil
        }
        if processing & (1 << 9) != 0,
           let low = read(UVCGetMinimum, UVCUnitProcessing, Self.gainControl, 2),
           let high = read(UVCGetMaximum, UVCUnitProcessing, Self.gainControl, 2), high > low {
            gainRange = Double(low)...Double(high)
            gainStep = Double(max(1, read(UVCGetResolution, UVCUnitProcessing, Self.gainControl, 2) ?? 1))
        } else {
            gainRange = nil
            gainStep = 1
        }
        guard exposureRange != nil || gainRange != nil else { return nil }

        // The modes the camera offers, as a bitmap: 1 manual, 2 auto, 4 shutter priority, 8 aperture priority.
        let modes = read(UVCGetResolution, UVCUnitTerminal, Self.autoExposureMode, 1) ?? 0x09
        manualMode = modes & 1 != 0 ? 1 : 4
        autoMode = modes & 8 != 0 ? 8 : modes & 2 != 0 ? 2 : 8

        let current = Double(read(UVCGetCurrent, UVCUnitTerminal, Self.exposureTime, 4) ?? 100) / 10
        let currentGain = Double(read(UVCGetCurrent, UVCUnitProcessing, Self.gainControl, 2) ?? 0)
        let defaults = UserDefaults.standard
        autoExposure = defaults.object(forKey: key + ".auto") as? Bool ?? true
        exposure = defaults.object(forKey: key + ".exposure") as? Double ?? current
        gain = defaults.object(forKey: key + ".gain") as? Double ?? currentGain
    }

    /// Location, vendor and product from AVFoundation's ids. The unique id packs all three
    /// (location in the high 32 bits); the model id is the fallback for vendor and product.
    static func usbIDs(uniqueID: String, modelID: String) -> (location: UInt32, vendor: UInt16, product: UInt16)? {
        if uniqueID.hasPrefix("0x"), let packed = UInt64(uniqueID.dropFirst(2), radix: 16), packed > 0xFFFF_FFFF {
            return (UInt32(packed >> 32), UInt16((packed >> 16) & 0xFFFF), UInt16(packed & 0xFFFF))
        }
        func number(after label: String) -> UInt16? {
            guard let range = modelID.range(of: label) else { return nil }
            return UInt16(modelID[range.upperBound...].prefix { $0.isNumber })
        }
        guard let vendor = number(after: "VendorID_"), let product = number(after: "ProductID_") else { return nil }
        return (0, vendor, product)
    }

    /// Sends the current settings to the camera. Also called after the capture session starts,
    /// since starting it can put the camera back on auto exposure.
    func apply() {
        let camera = camera, auto = autoExposure
        let mode = auto ? autoMode : manualMode
        let time = UInt32(max(1, (exposure * 10).rounded()))
        let gainValue = UInt32(max(0, gain.rounded()))
        let hasExposure = exposureRange != nil, hasGain = gainRange != nil
        queue.async {
            uvc_set(camera.pointer, UVCUnitTerminal, Self.autoExposureMode, 1, mode)
            if !auto, hasExposure { uvc_set(camera.pointer, UVCUnitTerminal, Self.exposureTime, 4, time) }
            if hasGain { uvc_set(camera.pointer, UVCUnitProcessing, Self.gainControl, 2, gainValue) }
        }
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(autoExposure, forKey: key + ".auto")
        defaults.set(exposure, forKey: key + ".exposure")
        defaults.set(gain, forKey: key + ".gain")
    }
}
