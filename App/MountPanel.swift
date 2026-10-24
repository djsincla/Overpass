import IOptronKit
import SkyKit
import SwiftUI

/// Connection, manual moves, tracking and fine tuning, kept compact so it fits without scrolling.
struct MountPanel: View {
    @Environment(AppModel.self) private var model
    @State private var mode = TrackingMode.step
    @State private var confirmingSun = false
    @State private var showingAlignment = false

    var body: some View {
        let mount = model.mount
        VStack(alignment: .leading, spacing: 10) {
            header
            ControlPad()
                .disabled(mount.state != .connected)
                .opacity(mount.state == .connected ? 1 : 0.5)
            if mount.state == .connected {
                Divider()
                tracking
                alignment
                if mount.kind == .usb { GuidingPanel() }
            }
            if !mount.status.isEmpty {
                Text(mount.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
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

    // MARK: Header: connection, position, STOP

    private var header: some View {
        let mount = model.mount
        return HStack(spacing: 10) {
            Circle().fill(stateColor).frame(width: 9, height: 9).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(stateText).font(.callout).lineLimit(1)
                if let h = mount.skyPosition {
                    Text("Az \(h.azimuth, format: .number.precision(.fractionLength(2)))°  Alt \(h.altitude, format: .number.precision(.fractionLength(2)))°")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if mount.state == .connected {
                Button(role: .destructive) { Task { await mount.stopAll() } } label: {
                    Label("STOP", systemImage: "stop.fill").font(.callout.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(.space, modifiers: [])
                Button("Disconnect") { Task { await mount.disconnect() } }.controlSize(.small)
            } else {
                Button("Connect") { Task { await mount.connect() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(mount.state == .connecting)
            }
        }
    }

    private var stateText: String {
        switch model.mount.state {
        case .disconnected: "\(model.settings.connection.rawValue) · not connected"
        case .connecting: "Connecting…"
        case .connected: model.mount.identity.map(describe) ?? "Connected"
        case .failed(let why): why
        }
    }

    private var stateColor: Color {
        switch model.mount.state {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        case .disconnected: .gray
        }
    }

    // MARK: Tracking

    private var tracking: some View {
        @Bindable var model = model
        let mount = model.mount
        let highlighted = model.highlightedObject
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                if mount.availableModes.count > 1 {
                    Picker("Mode", selection: $mode) {
                        ForEach(mount.availableModes) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help(modeExplanation)
                    .disabled(mount.isTracking)
                } else {
                    Text("Smooth").font(.callout.bold()).help(modeExplanation)
                }
                if mode == .step && mount.kind == .wifi {
                    Stepper(value: $model.settings.stepInterval, in: 0.5...10, step: 0.5) {
                        Text("every \(model.settings.stepInterval, format: .number.precision(.fractionLength(1))) s")
                            .font(.callout.monospacedDigit())
                    }
                    .fixedSize()
                }
                Spacer()
            }

            // The target is locked separately from the highlight, so browsing never redirects the mount.
            HStack(spacing: 6) {
                Image(systemName: "scope").foregroundStyle(model.targetObject == nil ? Color.secondary : .green)
                    .accessibilityHidden(true)
                Text(targetText).font(.callout).lineLimit(1)
                Spacer(minLength: 4)
                Button(highlighted.map { "Set to \($0.name)" } ?? "Set target") { model.setTargetFromHighlight() }
                    .controlSize(.small)
                    .lineLimit(1)
                    .disabled(mount.isTracking || highlighted == nil || highlighted?.id == model.targetObjectID)
                    .help(mount.isTracking ? "Stop tracking to change the target" : "Use the highlighted object as the tracking target")
            }

            HStack {
                if let pass = model.targetPass, !mount.isTracking {
                    if let point = mount.startPoint(of: pass) {
                        Button {
                            Task { await mount.moveToStart(of: pass) }
                        } label: {
                            Label("To start \(Int(point.position.azimuth))° \(compass(point.position.azimuth)) · \(Int(point.position.altitude))°",
                                  systemImage: "arrow.uturn.forward")
                        }
                        .disabled(mount.isPreparing || (mount.kind == .usb && model.settings.alignment == nil))
                        .help("Slew at full speed to where the pass first reaches the start elevation, and wait there")
                    } else {
                        Text("Past its start point").font(.caption).foregroundStyle(.secondary)
                    }
                }
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
        }
    }

    private var targetText: String {
        guard let target = model.targetObject else { return "No target set" }
        if let mode = model.mount.trackingMode { return "\(mode.rawValue): \(target.name)" }
        if let pass = model.targetPass {
            return "\(target.name) · \(pass.start.date.formatted(date: .omitted, time: .shortened)), peaks \(Int(pass.maxAltitude))°"
        }
        return target.name
    }

    @ViewBuilder
    private var alignment: some View {
        let mount = model.mount
        if mount.kind == .usb {
            HStack {
                Text("Alignment: \(alignmentSummary)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Align…") { showingAlignment = true }.controlSize(.small)
            }
        } else if let target = model.targetObject, !target.isSatellite, !mount.isTracking {
            HStack {
                Text("Centre \(target.name), then sync to improve the mount's pointing.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Sync") { Task { await mount.sync(on: target) } }.controlSize(.small)
            }
        }
    }

    // MARK: Helpers

    private var alignmentSummary: String {
        guard model.settings.alignment != nil else { return "none (Smooth needs 2+ stars)" }
        let rms = model.settings.alignmentRMS.map { String(format: ", error %.1f′", $0 * 60) } ?? ""
        return "\(model.settings.alignmentStars) stars\(rms)"
    }

    private var modeExplanation: String {
        switch (model.mount.kind, mode) {
        case (.wifi, .passive): "Passive: one goto, then the mount tracks by itself. Stars, planets, Moon, Sun and geostationary satellites."
        case (.wifi, _): "Step: repeats a goto to where the target will be. Fine for antennas; jumpy in a telescope."
        default: "Smooth: varies both axis speeds continuously. Best for imaging satellites."
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
}

/// Coarse arrows (hold to move) in the middle, fine arrows (tap) wrapped around them,
/// and speed, fine step and the time offset beside.
struct ControlPad: View {
    @Environment(AppModel.self) private var model
    @State private var fineStep: Double = 1

    var body: some View {
        @Bindable var mount = model.mount
        let wifi = mount.kind == .wifi
        HStack(alignment: .center, spacing: 14) {
            Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                GridRow {
                    gap; gap
                    FineButton(direction: .up, step: fineStep)
                    gap; gap
                }
                GridRow {
                    gap; gap
                    JogButton(direction: .up, symbol: "arrow.up", label: wifi ? "N" : "Up")
                    gap; gap
                }
                GridRow {
                    FineButton(direction: .left, step: fineStep)
                    JogButton(direction: .left, symbol: "arrow.left", label: wifi ? "W" : "Az−")
                    Image(systemName: "scope").font(.caption).foregroundStyle(.secondary).frame(width: 30, height: 30)
                    JogButton(direction: .right, symbol: "arrow.right", label: wifi ? "E" : "Az+")
                    FineButton(direction: .right, step: fineStep)
                }
                GridRow {
                    gap; gap
                    JogButton(direction: .down, symbol: "arrow.down", label: wifi ? "S" : "Down")
                    gap; gap
                }
                GridRow {
                    gap; gap
                    FineButton(direction: .down, step: fineStep)
                    gap; gap
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Speed") {
                    if wifi {
                        Picker("Speed", selection: $mount.moveRate) {
                            ForEach(NormalCommand.MoveRate.allCases, id: \.self) { rate in
                                Text(rate.siderealMultiple.map { "\(Int($0))×" } ?? "Max").tag(rate)
                            }
                        }
                        .labelsHidden().fixedSize()
                    } else {
                        Picker("Speed", selection: $mount.jogSpeed) {
                            ForEach([0.01, 0.05, 0.2, 1, 3, 6], id: \.self) { Text("\($0, format: .number)°/s").tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                LabeledContent("Fine") {
                    Picker("Fine step", selection: $fineStep) {
                        Text("1′").tag(1.0)
                        Text("5′").tag(5.0)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                LabeledContent("Time") {
                    HStack(spacing: 2) {
                        Button("−") { mount.timeOffset -= 0.1 }.help("Aim 0.1 s earlier along the track")
                        Text(String(format: "%+.1f s", mount.timeOffset)).font(.caption.monospacedDigit()).frame(minWidth: 46)
                        Button("+") { mount.timeOffset += 0.1 }.help("Aim 0.1 s later along the track")
                    }
                    .controlSize(.small)
                }
                HStack(spacing: 4) {
                    Text(String(format: "Az %+.0f′ · Alt %+.0f′", mount.azimuthOffset * 60, mount.altitudeOffset * 60))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button {
                        mount.timeOffset = 0
                        mount.azimuthOffset = 0
                        mount.altitudeOffset = 0
                    } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .help("Reset the time and position offsets")
                    .accessibilityLabel("Reset offsets")
                    .disabled(mount.timeOffset == 0 && mount.azimuthOffset == 0 && mount.altitudeOffset == 0)
                }
            }
            .font(.callout)
        }
    }

    private var gap: some View { Color.clear.frame(width: 1, height: 1) }
}

/// Small outer arrow: one tap, one fine step.
struct FineButton: View {
    @Environment(AppModel.self) private var model
    let direction: JogDirection
    let step: Double

    var body: some View {
        Button {
            Task { await model.mount.nudge(direction, arcminutes: step) }
        } label: {
            Image(systemName: symbol).font(.caption.bold()).frame(width: 30, height: 22)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Fine: \(Int(step))′ \(name). Shifts the tracking offsets while Step or Smooth tracking; otherwise a short slow move.")
        .accessibilityLabel("Fine \(name), \(Int(step)) arc-minutes")
    }

    private var symbol: String {
        switch direction {
        case .up: "chevron.up"
        case .down: "chevron.down"
        case .left: "chevron.left"
        case .right: "chevron.right"
        }
    }

    private var name: String {
        switch direction {
        case .up: "up"
        case .down: "down"
        case .left: "left"
        case .right: "right"
        }
    }
}

/// Large inner arrow: press and hold to move at the chosen speed; release to stop.
struct JogButton: View {
    @Environment(AppModel.self) private var model
    let direction: JogDirection
    let symbol: String
    let label: String
    @State private var pressed = false

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: symbol).font(.body.bold())
            Text(label).font(.system(size: 9))
        }
        .frame(width: 44, height: 40)
        .background(pressed ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
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
        .accessibilityHint("Hold to move, release to stop")
        .accessibilityAddTraits(.isButton)
    }
}
