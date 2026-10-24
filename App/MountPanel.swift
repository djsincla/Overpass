import IOptronKit
import SkyKit
import SwiftUI

/// Connection, manual moves, tracking and fine tuning.
struct MountPanel: View {
    @Environment(AppModel.self) private var model
    @State private var mode = TrackingMode.step
    @State private var confirmingSun = false
    @State private var showingAlignment = false

    var body: some View {
        @Bindable var mount = model.mount
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            connection

            if mount.state == .connected {
                position
                JogPad()
                trackingSection
                if mount.kind != .wifi || mode != .passive { fineTuning }
                alignmentSection
            }
            if !mount.status.isEmpty {
                Text(mount.status).font(.callout).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showingAlignment) { AlignmentSheet() }
        .alert("Point at the Sun?", isPresented: $confirmingSun) {
            Button("I have a solar filter fitted", role: .destructive) { Task { await startTracking() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Never point a telescope, finder or camera at the Sun without a proper full-aperture solar filter. It can blind you instantly and destroy equipment.")
        }
        .onChange(of: mount.kind) { _, _ in mode = mount.availableModes.first ?? .step }
    }

    // MARK: Sections

    private var connection: some View {
        let mount = model.mount
        return HStack {
            VStack(alignment: .leading) {
                Text(model.settings.connection.rawValue).font(.headline)
                switch mount.state {
                case .disconnected: Text("Not connected").foregroundStyle(.secondary)
                case .connecting: Text("Connecting…").foregroundStyle(.secondary)
                case .connected: Text(mount.identity.map(describe) ?? "Connected").foregroundStyle(.green)
                case .failed(let why): Text(why).foregroundStyle(.red)
                }
            }
            .font(.callout)
            Spacer()
            if mount.state == .connected {
                Button("Disconnect") { Task { await mount.disconnect() } }
            } else {
                Button("Connect") { Task { await mount.connect() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(mount.state == .connecting)
            }
        }
    }

    private var position: some View {
        HStack {
            if let h = model.mount.skyPosition {
                Label("Az \(h.azimuth, format: .number.precision(.fractionLength(2)))°  Alt \(h.altitude, format: .number.precision(.fractionLength(2)))°",
                      systemImage: "scope")
                    .font(.callout.monospacedDigit())
            }
            Spacer()
            Button(role: .destructive) { Task { await model.mount.stopAll() } } label: {
                Label("STOP", systemImage: "stop.fill").font(.headline).frame(minWidth: 90)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .keyboardShortcut(.space, modifiers: [])
        }
    }

    private var trackingSection: some View {
        @Bindable var model = model
        let mount = model.mount
        let highlighted = model.highlightedObject
        return VStack(alignment: .leading, spacing: 8) {
            Text("Track").font(.headline)
            if mount.availableModes.count > 1 {
                Picker("Mode", selection: $mode) {
                    ForEach(mount.availableModes) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Text(modeExplanation).font(.caption).foregroundStyle(.secondary)
            if mode == .step && mount.kind == .wifi {
                Stepper(value: $model.settings.stepInterval, in: 0.5...10, step: 0.5) {
                    Text("Step every \(model.settings.stepInterval, format: .number.precision(.fractionLength(1))) s")
                }
            }
            // The target is locked separately from the highlight, so browsing never redirects the mount.
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Target").font(.caption).foregroundStyle(.secondary)
                    Text(model.targetObject?.name ?? "None set").lineLimit(1)
                    if let pass = model.targetPass {
                        Text("Pass at \(pass.start.date, style: .time), peaks \(Int(pass.maxAltitude))°")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(highlighted.map { "Set to \($0.name)" } ?? "Set target") { model.setTargetFromHighlight() }
                    .disabled(mount.isTracking || highlighted == nil || highlighted?.id == model.targetObjectID)
                    .help("Use the highlighted object as the tracking target")
            }
            if mount.isTracking {
                Text("Stop tracking to change the target.").font(.caption).foregroundStyle(.secondary)
            }
            if let pass = model.targetPass, !mount.isTracking {
                if let point = mount.startPoint(of: pass) {
                    Button {
                        Task { await mount.moveToStart(of: pass) }
                    } label: {
                        Label("Move to start · az \(Int(point.position.azimuth))° \(compass(point.position.azimuth)), alt \(Int(point.position.altitude))°",
                              systemImage: "arrow.uturn.forward")
                    }
                    .disabled(mount.isPreparing || (mount.kind == .usb && model.settings.alignment == nil))
                    .help("Point where the pass first reaches the start elevation, and wait there")
                } else {
                    Text("This pass is already past its start point.").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                if mount.isTracking {
                    Button("Stop tracking") { Task { await mount.stopAll() } }
                } else {
                    Button("Start tracking") {
                        if model.targetObject?.isSun == true { confirmingSun = true } else { Task { await startTracking() } }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canTrack(model.targetObject))
                }
            }
            if let name = mount.trackingName, let m = mount.trackingMode {
                Label("\(m.rawValue): \(name)", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.green)
            }
        }
    }

    private var fineTuning: some View {
        @Bindable var mount = model.mount
        return VStack(alignment: .leading, spacing: 8) {
            Text("Fine tune").font(.headline)
            OffsetRow(title: "Time", value: $mount.timeOffset, steps: [0.1, 1], unit: "s", format: "%+.1f")
            OffsetRow(title: "Azimuth", value: arcmin($mount.azimuthOffset), steps: [1, 5], unit: "′", format: "%+.0f")
            OffsetRow(title: "Altitude", value: arcmin($mount.altitudeOffset), steps: [1, 5], unit: "′", format: "%+.0f")
            Text("Time moves the aim along the track, which corrects most TLE error. Offsets apply live while tracking.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var alignmentSection: some View {
        let mount = model.mount
        return HStack {
            if mount.kind == .usb {
                VStack(alignment: .leading) {
                    Text("Alignment").font(.headline)
                    Text(alignmentSummary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Align…") { showingAlignment = true }
            } else if let target = model.targetObject, !target.isSatellite, !mount.isTracking {
                Text("Centre \(target.name), then sync so the mount's own pointing improves.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Sync") { Task { await mount.sync(on: target) } }
            }
        }
    }

    // MARK: Helpers

    private var alignmentSummary: String {
        guard model.settings.alignment != nil else { return "Not aligned. Smooth tracking needs two or more stars." }
        let rms = model.settings.alignmentRMS.map { String(format: " · error %.1f′", $0 * 60) } ?? ""
        return "\(model.settings.alignmentStars) stars\(rms)"
    }

    private var modeExplanation: String {
        switch (model.mount.kind, mode) {
        case (.wifi, .passive): "One goto, then the mount tracks by itself. Stars, planets, Moon, Sun and geostationary satellites."
        case (.wifi, _): "Repeats a goto to where the target will be. Fine for antennas; jumpy in a telescope."
        default: "Varies both axis speeds continuously. Best for imaging satellites."
        }
    }

    private func canTrack(_ object: SkyObject?) -> Bool {
        guard let object else { return false }
        switch (model.mount.kind, mode) {
        case (.wifi, .passive): return object.passiveTracking != nil
        case (.usb, _): return model.settings.alignment != nil
        default: return true
        }
    }

    /// Tracks the locked target only, never whatever happens to be highlighted.
    private func startTracking() async {
        guard let target = model.targetObject else { return }
        let effective = model.mount.kind == .usb ? .smooth : mode
        await model.mount.track(target, mode: effective, pass: model.targetPass)
    }

    private func describe(_ identity: MountIdentity) -> String {
        let name = switch identity.model {
        case .haz31: "HAZ31"
        case .haz46: "HAZ46"
        case .hae29: "HAE29"
        case .hae43: "HAE43"
        case .azMountPro: "AZ Mount Pro"
        case .unknown(let code): "Mount \(code)"
        }
        return "\(name) · \(identity.isSpecialMode ? "Special mode" : "Normal mode")"
    }

    private func arcmin(_ degrees: Binding<Double>) -> Binding<Double> {
        Binding(get: { degrees.wrappedValue * 60 }, set: { degrees.wrappedValue = $0 / 60 })
    }
}

struct OffsetRow: View {
    let title: String
    @Binding var value: Double
    let steps: [Double]
    let unit: String
    let format: String

    var body: some View {
        HStack {
            Text(title).frame(width: 70, alignment: .leading)
            ForEach(steps.reversed(), id: \.self) { step in
                Button("−\(label(step))") { value -= step }.buttonStyle(.bordered)
            }
            Text(String(format: format, value) + unit)
                .font(.callout.monospacedDigit()).frame(minWidth: 56)
                .onTapGesture(count: 2) { value = 0 }
                .accessibilityHint("Double-tap to reset")
            ForEach(steps, id: \.self) { step in
                Button("+\(label(step))") { value += step }.buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
    }

    private func label(_ step: Double) -> String {
        step < 1 ? String(format: "%.1f", step) : String(format: "%.0f", step)
    }
}

/// Press and hold to move; release to stop.
struct JogPad: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var mount = model.mount
        HStack(alignment: .center, spacing: 24) {
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    JogButton(direction: .up, symbol: "arrow.up", label: model.mount.kind == .wifi ? "N" : "Up")
                    Color.clear.frame(width: 1, height: 1)
                }
                GridRow {
                    JogButton(direction: .left, symbol: "arrow.left", label: model.mount.kind == .wifi ? "W" : "Az−")
                    Image(systemName: "scope").foregroundStyle(.secondary)
                    JogButton(direction: .right, symbol: "arrow.right", label: model.mount.kind == .wifi ? "E" : "Az+")
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    JogButton(direction: .down, symbol: "arrow.down", label: model.mount.kind == .wifi ? "S" : "Down")
                    Color.clear.frame(width: 1, height: 1)
                }
            }
            VStack(alignment: .leading) {
                Text("Speed").font(.caption).foregroundStyle(.secondary)
                if model.mount.kind == .wifi {
                    Picker("Speed", selection: $mount.moveRate) {
                        ForEach(NormalCommand.MoveRate.allCases, id: \.self) { rate in
                            Text(rate.siderealMultiple.map { "\(Int($0))×" } ?? "Max").tag(rate)
                        }
                    }
                    .labelsHidden()
                } else {
                    Picker("Speed", selection: $mount.jogSpeed) {
                        ForEach([0.01, 0.05, 0.2, 1, 3, 6], id: \.self) { Text("\($0, format: .number)°/s").tag($0) }
                    }
                    .labelsHidden()
                }
            }
        }
    }
}

struct JogButton: View {
    @Environment(AppModel.self) private var model
    let direction: JogDirection
    let symbol: String
    let label: String
    @State private var pressed = false

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: symbol).font(.title2)
            Text(label).font(.caption2)
        }
        .frame(width: 56, height: 56)
        .background(pressed ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !pressed else { return }
                pressed = true
                Task { await model.mount.jog(direction, pressed: true) }
            }
            .onEnded { _ in
                pressed = false
                Task { await model.mount.jog(direction, pressed: false) }
            })
        .accessibilityLabel("Move \(label)")
        .accessibilityAddTraits(.isButton)
    }
}
