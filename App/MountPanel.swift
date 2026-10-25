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
            Card(title: "Move", systemImage: "arrow.up.and.down.and.arrow.left.and.right") {
                ControlPad()
                    .disabled(mount.state != .connected)
                    .opacity(mount.state == .connected ? 1 : 0.45)
            }
            if mount.state == .connected {
                Card(title: "Tracking", systemImage: "scope") {
                    tracking
                    if showsAlignment {
                        Divider().padding(.vertical, 2)
                        alignment
                    }
                }
                if mount.kind == .usb {
                    Card(title: "Camera guiding", systemImage: "camera.viewfinder") { GuidingPanel() }
                }
            }
            if !mount.status.isEmpty {
                Label(mount.status, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .padding(.horizontal, 4)
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
        let connected = mount.state == .connected
        return Card {
            HStack(spacing: 8) {
                StatusDot(color: stateColor)
                Text(stateText).font(.callout.weight(.medium)).lineLimit(1)
                Spacer(minLength: 4)
                if connected {
                    Button { Task { await mount.disconnect() } } label: { Image(systemName: "power") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Disconnect")
                        .accessibilityLabel("Disconnect")
                } else {
                    Button("Connect") { Task { await mount.connect() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(mount.state == .connecting)
                }
            }
            if connected {
                HStack(alignment: .center, spacing: 18) {
                    let h = mount.skyPosition
                    Readout(label: "AZ", value: h.map { String(format: "%06.2f°", $0.azimuth) } ?? "———")
                    Readout(label: "ALT", value: h.map { String(format: "%+06.2f°", $0.altitude) } ?? "———")
                    Spacer(minLength: 4)
                    Button { Task { await mount.stopAll() } } label: {
                        Label("STOP", systemImage: "stop.fill")
                    }
                    .buttonStyle(StopButtonStyle())
                    .keyboardShortcut(.space, modifiers: [])
                    .help("Stop all motion and tracking (space)")
                }
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
        let target = model.targetObject
        return VStack(alignment: .leading, spacing: 8) {
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
                    Chip(text: "Smooth", systemImage: "waveform.path", tint: Theme.accent).help(modeExplanation)
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
            HStack(spacing: 8) {
                if let target {
                    ObjectBadge(object: target)
                } else {
                    Image(systemName: "scope").foregroundStyle(.secondary).frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.06), in: Circle()).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(target?.name ?? "No target set").font(.callout.weight(.medium)).lineLimit(1)
                    if let detail = targetDetail {
                        Text(detail).font(.caption.monospacedDigit())
                            .foregroundStyle(model.timeShift != 0 ? Theme.focus : mount.isTracking ? Theme.target : .secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Button(highlighted.map { "Set to \($0.name)" } ?? "Set target") { model.setTargetFromHighlight() }
                    .controlSize(.small)
                    .lineLimit(1)
                    .disabled(mount.isTracking || highlighted == nil || highlighted?.id == model.targetObjectID)
                    .help(mount.isTracking ? "Stop tracking to change the target" : "Use the highlighted object as the tracking target")
            }

            if let target, let scope = mount.skyPosition {
                PointingError(target: target, scope: scope)
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
                    Button { Task { await mount.stopAll() } } label: {
                        Label("Stop tracking", systemImage: "stop.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.scope)
                } else if mount.kind == .usb && model.settings.alignment == nil {
                    // Special mode reports raw axis angles: nothing to aim with until stars tie them to the sky.
                    Button { showingAlignment = true } label: {
                        Label("Align first…", systemImage: "star.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Smooth tracking needs a star alignment: centre two or three bright stars")
                } else {
                    Button {
                        if model.targetObject?.isSun == true { confirmingSun = true } else { Task { await startTracking() } }
                    } label: {
                        Label("Start tracking", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.go)
                    .disabled(!canTrack(model.targetObject))
                }
            }
        }
    }

    /// "Step · tracking" while running; otherwise when the pass starts and how high it gets.
    private var targetDetail: String? {
        guard model.targetObject != nil else { return nil }
        let shift = model.timeShift
        let timeline = shift == 0 ? "" : " · timeline \(shift < 0 ? "−" : "+")\(countdown(abs(shift)))"
        if let mode = model.mount.trackingMode { return "\(mode.rawValue) tracking\(timeline)" }
        if let pass = model.targetPass {
            return "\(pass.start.date.formatted(date: .omitted, time: .shortened)) · peaks \(Int(pass.maxAltitude))°\(timeline)"
        }
        return nil
    }

    private var showsAlignment: Bool {
        if model.mount.kind == .usb { return true }
        guard let target = model.targetObject else { return false }
        return !target.isSatellite && !model.mount.isTracking
    }

    @ViewBuilder
    private var alignment: some View {
        let mount = model.mount
        if mount.kind == .usb {
            HStack {
                Label("Alignment: \(alignmentSummary)", systemImage: "star.circle").font(.caption).foregroundStyle(.secondary)
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

/// How far the scope is from where the target is (with the fine-tune offsets), in arc-seconds,
/// on a logarithmic bar from 1″ to 10°: green within an arc-minute, amber within ten.
struct PointingError: View {
    @Environment(AppModel.self) private var model
    let target: SkyObject
    let scope: Horizontal

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            if let error = error(at: context.date) {
                content(error)
            }
        }
    }

    private func content(_ error: (total: Double, azimuth: Double, altitude: Double)) -> some View {
        let arcsec = error.total * 3600
        let color = arcsec < 60 ? Theme.target : arcsec < 600 ? Theme.focus : Theme.scope
        // 1″ at the left, 10° (36,000″) at the right.
        let fraction = min(max(log10(max(arcsec, 1)) / log10(36_000), 0), 1)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Off target")
                Spacer()
                Text(String(format: "Az %+.0f″  Alt %+.0f″", error.azimuth * 3600, error.altitude * 3600))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(arcsec < 100_000 ? "\(Int(arcsec.rounded()))″" : String(format: "%.1f°", error.total))
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule().fill(color.gradient)
                        .frame(width: max(6, proxy.size.width * fraction))
                        .shadow(color: color.opacity(0.5), radius: 3)
                    // Marks at 1′ and 10′.
                    ForEach([60.0, 600.0], id: \.self) { mark in
                        Rectangle().fill(Color.primary.opacity(0.35))
                            .frame(width: 1)
                            .offset(x: proxy.size.width * log10(mark) / log10(36_000))
                    }
                }
            }
            .frame(height: 6)
            .animation(.easeOut(duration: 0.3), value: fraction)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Off target by \(Int(arcsec.rounded())) arc-seconds")
    }

    /// Angular distance and its components on the sky (azimuth scaled by cos altitude), degrees.
    private func error(at date: Date) -> (total: Double, azimuth: Double, altitude: Double)? {
        let mount = model.mount
        let time = AstroTime(model.viewDate(date) + mount.timeOffset)
        guard var aim = try? model.settings.observer.look(at: target.target, time) else { return nil }
        aim.azimuth = normalizedDegrees(aim.azimuth + mount.azimuthOffset)
        aim.altitude += mount.altitudeOffset
        let a1 = scope.altitude.radians, a2 = aim.altitude.radians
        let dAz = wrap180(aim.azimuth - scope.azimuth).radians, dAlt = a2 - a1
        // Haversine: stays accurate down to fractions of an arc-second.
        let h = sin(dAlt / 2) * sin(dAlt / 2) + cos(a1) * cos(a2) * sin(dAz / 2) * sin(dAz / 2)
        let total = (2 * asin(min(1, h.squareRoot()))).degrees
        return (total, dAz.degrees * cos((a1 + a2) / 2), dAlt.degrees)
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
        HStack(alignment: .center, spacing: 16) {
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                GridRow {
                    gap; gap
                    FineButton(direction: .up, step: fineStep)
                    gap; gap
                }
                GridRow {
                    gap; gap
                    JogButton(direction: .up, symbol: "arrowtriangle.up.fill", label: wifi ? "N" : "Up")
                    gap; gap
                }
                GridRow {
                    FineButton(direction: .left, step: fineStep)
                    JogButton(direction: .left, symbol: "arrowtriangle.left.fill", label: wifi ? "W" : "Az−")
                    Image(systemName: "scope")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.scope)
                        .frame(width: 30, height: 30)
                        .background(Theme.scope.opacity(0.12), in: Circle())
                        .accessibilityHidden(true)
                    JogButton(direction: .right, symbol: "arrowtriangle.right.fill", label: wifi ? "E" : "Az+")
                    FineButton(direction: .right, step: fineStep)
                }
                GridRow {
                    gap; gap
                    JogButton(direction: .down, symbol: "arrowtriangle.down.fill", label: wifi ? "S" : "Down")
                    gap; gap
                }
                GridRow {
                    gap; gap
                    FineButton(direction: .down, step: fineStep)
                    gap; gap
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
                GridRow {
                    rowLabel("Speed")
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
                GridRow {
                    rowLabel("Fine")
                    Picker("Fine step", selection: $fineStep) {
                        Text("1′").tag(1.0)
                        Text("5′").tag(5.0)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                GridRow {
                    rowLabel("Time")
                    HStack(spacing: 2) {
                        Button { mount.timeOffset -= 0.1 } label: { Image(systemName: "minus") }
                            .help("Aim 0.1 s earlier along the track").accessibilityLabel("Earlier")
                        Text(String(format: "%+.1f s", mount.timeOffset))
                            .font(.callout.monospacedDigit()).frame(minWidth: 50)
                        Button { mount.timeOffset += 0.1 } label: { Image(systemName: "plus") }
                            .help("Aim 0.1 s later along the track").accessibilityLabel("Later")
                    }
                    .controlSize(.small)
                }
                GridRow {
                    rowLabel("Offset")
                    HStack(spacing: 4) {
                        Text(String(format: "Az %+.0f′  Alt %+.0f′", mount.azimuthOffset * 60, mount.altitudeOffset * 60))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(mount.azimuthOffset == 0 && mount.altitudeOffset == 0 ? .secondary : .primary)
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
            }
            .font(.callout)
        }
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text.uppercased()).font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
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
            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
        }
        .buttonStyle(PadButtonStyle(width: 30, height: 22, cornerRadius: 7))
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
        VStack(spacing: 1) {
            Image(systemName: symbol).font(.system(size: 13, weight: .bold))
            Text(label).font(.system(size: 9, weight: .semibold))
        }
        .modifier(PadFace(pressed: pressed, width: 46, height: 42, cornerRadius: 10))
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

/// The look shared by the pad's keys: raised when idle, lit in the accent colour while pressed.
struct PadFace: ViewModifier {
    let pressed: Bool
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .foregroundStyle(pressed ? Color.white : Color.primary.opacity(isEnabled ? 0.85 : 0.4))
            .frame(width: width, height: height)
            .background {
                if pressed {
                    shape.fill(Theme.accent.gradient)
                } else {
                    shape.fill(LinearGradient(colors: [Color.primary.opacity(0.10), Color.primary.opacity(0.05)],
                                              startPoint: .top, endPoint: .bottom))
                }
            }
            .overlay(shape.strokeBorder(pressed ? Theme.accent : Color.primary.opacity(0.12)))
            .shadow(color: pressed ? Theme.accent.opacity(0.6) : .clear, radius: 6)
            .scaleEffect(pressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.08), value: pressed)
            .contentShape(shape)
    }
}

struct PadButtonStyle: ButtonStyle {
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(PadFace(pressed: configuration.isPressed, width: width, height: height, cornerRadius: cornerRadius))
    }
}

/// The big red emergency stop.
struct StopButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Capsule().fill(LinearGradient(colors: [Theme.scope, Theme.scope.opacity(0.75)],
                                                      startPoint: .top, endPoint: .bottom)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.25)))
            .shadow(color: Theme.scope.opacity(configuration.isPressed ? 0.3 : 0.55), radius: configuration.isPressed ? 3 : 8)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
