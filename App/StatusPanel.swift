import IOptronKit
import SkyKit
import SwiftUI

/// What a row's Status menu item opens.
struct StatusSheetRequest: Identifiable {
    let objectID: String
    var passID: String?
    var id: String { objectID + (passID ?? "") }
}

/// The tracking target, or the highlighted object, in numbers: where it is and how it moves,
/// its pass, its radio, what the camera and mount make of it, and what the mount reports.
/// Given `objectID`, that object instead, leaving the target and highlight alone.
struct StatusPanel: View {
    @Environment(AppModel.self) private var model
    var objectID: String?
    var passID: String?
    /// The mount's report belongs with the panel in Observe, not in a sheet about one object.
    var showsMount = true

    var body: some View {
        TimelineView(.periodic(from: Theme.clockAnchor, by: 1)) { context in
            let date = model.viewDate(context.date)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let object = objectID.flatMap(model.object) ?? model.targetObject ?? model.highlightedObject {
                        content(object, at: date)
                    } else {
                        Text("Pick a satellite in Passes or on the sky to see it here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if showsMount { MountReportSection() }
                }
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private func content(_ object: SkyObject, at date: Date) -> some View {
        if case .satellite(let s) = object,
           let state = try? SatelliteState(s, observer: model.settings.observer, at: date) {
            let pass = passID.flatMap { id in model.passes.first { $0.id == id && $0.end.date > date } }
                ?? model.targetPass.flatMap { $0.noradID == s.noradID && $0.end.date > date ? $0 : nil }
                ?? model.currentOrNextPass(s.noradID, at: date)
            let sunlit = (try? s.isSunlit(at: AstroTime(date))) ?? false
            SatelliteStatusView(satellite: s, state: state, pass: pass, sunlit: sunlit, date: date,
                                isTarget: model.targetObjectID == object.id)
        } else if let h = try? model.settings.observer.look(at: object.target, AstroTime(date)) {
            Header(name: object.name, detail: nil) {}
            StatusSection("Now") {
                TileGrid {
                    Tile("Elevation", fixed(h.altitude, 1) + "°", sub: h.altitude > 0 ? String(localized: "up") : String(localized: "below the horizon"))
                    Tile("Azimuth", fixed(h.azimuth, 1) + "°", sub: compass(h.azimuth))
                    if let m = model.magnitude(object, at: date) {
                        Tile("Magnitude", fixed(m, 1), sub: object.isComet ? String(localized: "predicted") : nil)
                    }
                    switch object {
                    case .deepSky(let d):
                        Tile("Kind", d.kind.name, sub: [d.designation, d.alsoKnownAs].compactMap { $0 }.filter { !$0.isEmpty && $0 != d.id }.first)
                        if let size = d.size {
                            Tile("Size", size >= 60 ? fixed(size / 60, 1) + "°" : fixed(size, 0) + "′", sub: d.constellation)
                        }
                    case .star(let st):
                        if let designation = st.designation { Tile("Designation", designation) }
                    case .comet(let c):
                        let (r, delta) = c.distances(AstroTime(date))
                        Tile("From the Sun", String(localized: "\(fixed(r, 2)) AU", comment: "Astronomical units"))
                        Tile("From Earth", String(localized: "\(fixed(delta, 2)) AU", comment: "Astronomical units"),
                             sub: model.units.distance(delta * SolarSystemBody.auKm))
                        Tile("Motion", fixed(c.motion(AstroTime(date)), 0) + "″/h", sub: String(localized: "against the stars"))
                    default:
                        EmptyView()
                    }
                }
            }
        }
    }
}

/// A satellite's status, section by section.
private struct SatelliteStatusView: View {
    @Environment(AppModel.self) private var model
    let satellite: SatelliteTarget
    let state: SatelliteState
    let pass: SatellitePass?
    let sunlit: Bool
    let date: Date
    let isTarget: Bool

    private var units: Units { model.units }
    private var up: Bool { state.position.altitude > 0 }

    var body: some View {
        Header(name: satellite.name,
               detail: isTarget ? String(localized: "NORAD \(satellite.noradID) · tracking target") : "NORAD \(satellite.noradID)") {
            Chip(text: sunlit ? String(localized: "Sunlit") : String(localized: "In shadow"), systemImage: sunlit ? "sun.max.fill" : "moon.fill",
                 tint: sunlit ? Theme.sunlit : Theme.eclipsed)
            Chip(text: up ? String(localized: "Up") : String(localized: "Below the horizon"), tint: up ? Theme.rising : .secondary)
        }
        now
        if let pass { passTimes(pass) }
        radio
        camera
        if let pass { mountSpeed(pass) }
    }

    // MARK: Now

    private var now: some View {
        let peak = pass.map(peakSkySpeed)
        return StatusSection("Now") {
            TileGrid {
                Tile("Elevation", fixed(state.position.altitude, 1) + "°",
                     sub: pass.map { String(localized: "peak \(Int($0.maxAltitude.rounded()))° at \(time($0.culmination.date))") })
                Tile("Azimuth", fixed(state.position.azimuth, 1) + "°", sub: compass(state.position.azimuth))
                Tile("Range", units.distance(state.position.range),
                     sub: pass.map { String(localized: "closest \(units.distance($0.minimumRange))") })
                Tile("Range rate", speed(state.rangeRate, signed: true),
                     sub: state.rangeRate < 0 ? String(localized: "approaching") : String(localized: "receding"),
                     subTint: state.rangeRate < 0 ? Theme.rising : Theme.setting)
                Tile("Speed", speed(state.orbitalSpeed), sub: String(localized: "ground \(speed(state.groundSpeed))"))
                Tile("Height", units.distance(state.subpoint.height))
                Tile("Sky speed", fixed(state.angularSpeed, 2) + "°/s",
                     sub: peak.map { String(localized: "peak \(fixed($0, 2))°/s") })
                if let m = model.magnitude(.satellite(satellite), at: date) {
                    Tile("Magnitude", fixed(m, 1), sub: sunlit ? String(localized: "smaller is brighter") : String(localized: "in shadow"))
                }
                Tile("Below it", Maidenhead.locator(state.subpoint),
                     sub: String(localized: "\(fixed(state.subpoint.latitude, 2))°, \(fixed(state.subpoint.longitude, 2))°",
                                 comment: "Latitude and longitude"))
            }
        }
    }

    // MARK: Pass

    private func passTimes(_ pass: SatellitePass) -> some View {
        var rows: [(String, Date)] = [(String(localized: "Rises"), pass.start.date), (String(localized: "Peaks"), pass.culmination.date),
                                      (String(localized: "Sets"), pass.end.date)]
        for crossing in pass.shadowCrossings(of: satellite) {
            rows.append((crossing.entersShadow ? String(localized: "Into shadow") : String(localized: "Out of shadow"), crossing.date))
        }
        rows.sort { $0.1 < $1.1 }
        let next = rows.first { $0.1 > date }
        return StatusSection(pass.start.date > date ? "Next pass" : "This pass") {
            StatusTable {
                ForEach(rows, id: \.0) { row in
                    StatusRow {
                        Text(row.0).fontWeight(row.0 == next?.0 ? .semibold : .regular)
                        Spacer()
                        Text(time(row.1, seconds: true)).monospacedDigit()
                        Text(countdown(row.1)).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 70, alignment: .trailing)
                    }
                    .foregroundStyle(row.1 < date ? .secondary : .primary)
                }
            }
        }
    }

    // MARK: Radio

    private var radio: some View {
        let list = model.transmitters[satellite.noradID]
        let active = list?.filter(\.isActive) ?? []
        // A second later, for the rate the shift is changing.
        let later = (try? SatelliteState(satellite, observer: model.settings.observer, at: date + 1))?.rangeRate ?? state.rangeRate
        return StatusSection("Radio") {
            if list == nil {
                Text("Loading transmitters from SatNOGS…").font(.callout).foregroundStyle(.secondary)
            } else if active.isEmpty {
                Text("SatNOGS lists no active transmitters for this satellite.").font(.callout).foregroundStyle(.secondary)
            } else {
                StatusTable {
                    StatusRow {
                        Text("Transmitter").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Receive on").frame(width: 120, alignment: .trailing)
                        Text("Transmit on").frame(width: 120, alignment: .trailing)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    ForEach(active) { t in
                        StatusRow {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.description).lineLimit(2)
                                Text([t.mode, t.downlink.map { "\(mhz($0)) MHz" }].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            frequency(t.downlink.map { (Doppler.downlink($0, rangeRate: state.rangeRate), Doppler.downlink($0, rangeRate: later), $0) })
                                .frame(width: 120, alignment: .trailing)
                            frequency(t.uplink.map { (Doppler.uplink($0, rangeRate: state.rangeRate), Doppler.uplink($0, rangeRate: later), $0) })
                                .frame(width: 120, alignment: .trailing)
                        }
                    }
                }
                .textSelection(.enabled)
                Text(up ? "Corrected for Doppler now, with the shift and how fast it's changing. From the SatNOGS DB."
                        : "Corrected for Doppler now, though it's below the horizon. From the SatNOGS DB.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: satellite.noradID) { await model.loadTransmitters(satellite.noradID) }
    }

    @ViewBuilder
    private func frequency(_ f: (now: Double, next: Double, nominal: Double)?) -> some View {
        if let f {
            VStack(alignment: .trailing, spacing: 1) {
                Text(mhz(f.now)).monospacedDigit()
                Text(verbatim: "\(fixed((f.now - f.nominal) / 1000, 1, signed: true)) kHz · \(fixed(f.next - f.now, 0, signed: true)) Hz/s")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        } else {
            Text("–").foregroundStyle(.secondary)
        }
    }

    // MARK: Camera

    private var camera: some View {
        let optics = model.settings.optics
        let peak = pass.map(peakSkySpeed)
        let size = model.info(.satellite(satellite))?.largestDimension
        let trackingError = model.mount.isTracking && model.mount.trackingObject?.id == "sat:\(satellite.noradID)"
            ? model.mount.trace.last?.error : nil
        return StatusSection("Camera") {
            TileGrid {
                Tile("Image scale", fixed(optics.imageScale, 2) + "″/px",
                     sub: "\(optics.focalLength.formatted()) mm, \(optics.pixelSize.formatted()) µm")
                Tile("Sharp without tracking", exposure(optics.exposureForOnePixel(rate: state.angularSpeed)),
                     sub: peak.map { String(localized: "at peak \(exposure(optics.exposureForOnePixel(rate: $0)))") })
                Tile("Frame rate, untracked",
                     String(localized: "\(fixed(optics.framesPerSecond(rate: state.angularSpeed), 0)) fps", comment: "Frames per second"),
                     sub: String(localized: "under a pixel a frame"))
                if let size {
                    Tile("Size", fixed(optics.pixels(size: size, range: state.position.range), 0) + " px",
                         sub: pass.map { String(localized: "\(fixed(optics.pixels(size: size, range: $0.minimumRange), 0)) px closest") })
                }
                if let trackingError {
                    Tile("Tracking error", fixed(trackingError * 3600 / optics.imageScale, 0) + " px",
                         sub: fixed(trackingError * 3600, 1) + "″")
                }
            }
            Text("Set the focal length and pixel size in Settings, Camera.").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Mount speed

    private func mountSpeed(_ pass: SatellitePass) -> some View {
        let s = model.settings
        let plan = model.plan(for: pass)
        return StatusSection("Mount speed") {
            VStack(alignment: .leading, spacing: 8) {
                RateBar(label: "Azimuth", need: pass.peakAzimuthRate, limit: s.maximumAzimuthRate)
                RateBar(label: "Altitude", need: pass.peakAltitudeRate, limit: s.maximumAltitudeRate)
                if let plan {
                    Text(verdict(plan)).font(.callout).foregroundStyle(plan.secondsOffTarget > 0 ? Theme.setting : .secondary)
                } else {
                    Text("The mount can't follow this pass within its limits.").font(.callout).foregroundStyle(Theme.scope)
                }
            }
        }
    }

    private func verdict(_ plan: MountPlan) -> String {
        var parts: [String] = []
        switch plan.orientation {
        case .normal: break
        case .overTheTop: parts.append(String(localized: "Tracked over the top."))
        case .flipAtCulmination: parts.append(String(localized: "Flips over the top at the peak."))
        }
        parts.append(plan.secondsOffTarget > 0
                     ? String(localized: "Off target for about \(fixed(plan.secondsOffTarget, 0)) s, at most \(fixed(plan.maximumError, 1))° behind.")
                     : String(localized: "On target the whole pass."))
        if plan.unwindSeconds > 0 { parts.append(String(localized: "Unwinds past north for \(fixed(plan.unwindSeconds, 0)) s.")) }
        return parts.joined(separator: " ")
    }

    // MARK: Formatting

    private func peakSkySpeed(_ pass: SatellitePass) -> Double {
        pass.track.map { hypot($0.azimuthRate * cos($0.position.altitude.radians), $0.altitudeRate) }.max() ?? 0
    }

    private func speed(_ kmPerSecond: Double, signed: Bool = false) -> String {
        let v = units.imperial ? kmPerSecond / Units.kmPerMile : kmPerSecond
        return "\(fixed(v, 2, signed: signed)) \(units.distanceUnit)/s"
    }

    private func mhz(_ hz: Double) -> String { fixed(hz / 1e6, 4) }

    private func exposure(_ seconds: Double?) -> String {
        guard let seconds else { return String(localized: "any", comment: "Any exposure time") }
        return seconds >= 1 ? fixed(seconds, 1) + " s" : "1/\(Int((1 / seconds).rounded())) s"
    }

    private func time(_ date: Date, seconds: Bool = false) -> String {
        date.formatted(date: .omitted, time: seconds ? .standard : .shortened)
    }

    private func countdown(_ target: Date) -> String {
        let s = Int(target.timeIntervalSince(date).rounded())
        let a = abs(s)
        let text = a >= 3600 ? String(localized: "\(a / 3600) h \(a % 3600 / 60) min") : String(format: "%d:%02d", a / 60, a % 60)
        return s >= 0 ? String(localized: "in \(text)") : String(localized: "\(text) ago")
    }
}

/// What the mount said about itself when it connected.
private struct MountReportSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        StatusSection("Mount") {
            if model.mount.identity != nil {
                MountReportTable()
            } else {
                Text("Connect to see what the mount reports about itself.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// The mount's model, state, GPS, clock and firmware, as read on connecting.
struct MountReportTable: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let mount = model.mount
        if let identity = mount.identity {
            VStack(alignment: .leading, spacing: 6) {
                StatusTable {
                    row("Model", identity.isSpecialMode ? String(localized: "\(identity.model.name), Special mode")
                                                         : String(localized: "\(identity.model.name), Normal mode"))
                    if let report = mount.report {
                        row("When connected", MountReport.systemName(report.system)
                            + (report.system == 1 || report.system == 5 ? ", " + MountReport.rateName(report.trackingRate).lowercased() : ""))
                        row("GPS", MountSession.gpsName(report.site.gps))
                        let latitude = fixed(report.site.latitude, 4), longitude = fixed(report.site.longitude, 4)
                        row("Its location", report.northernHemisphere
                            ? String(localized: "\(latitude)°, \(longitude)° · northern hemisphere")
                            : String(localized: "\(latitude)°, \(longitude)° · southern hemisphere"))
                        row("Time from", MountReport.timeSourceName(report.timeSource))
                        if let clock = report.clock, let read = mount.reportDate {
                            row("Its clock", String(localized: "\(fixed(clock.timeIntervalSince(read), 1, signed: true)) s from this \(deviceName)")
                                + (report.utcOffsetMinutes.map { $0 == 0 ? ", UTC" : String(format: ", UTC%+d min", $0) } ?? ""))
                        }
                        row("Arrow speed", String(localized: "\(report.moveSpeed) of 9"))
                        if let main = report.mainBoard { row("Main board", main) }
                        if let hc = report.handController { row("Hand controller", hc) }
                        if let a = report.azimuthBoard { row("Azimuth motor board", a) }
                        if let b = report.altitudeBoard { row("Altitude motor board", b) }
                    }
                }
                .textSelection(.enabled)
                Text(mount.report == nil ? "The mount didn't answer the status commands."
                     : "Read on connecting, before Overpass set its location and time. Firmware dates are from the mount.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var deviceName: String {
        #if os(macOS)
        "Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        StatusRow {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
    }
}

/// One object's Status on its own, opened from a row's menu.
struct StatusSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: StatusSheetRequest

    var body: some View {
        NavigationStack {
            StatusPanel(objectID: request.objectID, passID: request.passID, showsMount: false)
                .navigationTitle("Status")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 620, minHeight: 560, idealHeight: 720)
        #endif
    }
}

extension MountModel {
    var name: String {
        switch self {
        case .haz31: "HAZ31"
        case .haz46: "HAZ46"
        case .haz71: "HAZ71"
        case .hae29: "HAE29"
        case .hae43: "HAE43"
        case .azMountPro: "AZ Mount Pro"
        case .unknown(let code): String(localized: "Mount \(code)")
        }
    }
}

// MARK: Building blocks

private struct Header<Chips: View>: View {
    let name: String
    let detail: String?
    @ViewBuilder let chips: () -> Chips

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.title3.weight(.semibold))
            HStack(spacing: 6) {
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                chips()
            }
        }
    }
}

/// An uppercase label over a rule, collapsible; collapsed sections are remembered.
private struct StatusSection<Content: View>: View {
    let title: LocalizedStringResource
    /// The English title, which is what's saved for a collapsed section whatever the language.
    let key: String
    @ViewBuilder let content: () -> Content
    @AppStorage("status.collapsed") private var collapsed = ""

    init(_ title: LocalizedStringResource, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.key = title.key
        self.content = content
    }

    private var isCollapsed: Bool { collapsed.split(separator: ",").contains(Substring(key)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                var set = Set(collapsed.split(separator: ",").map(String.init))
                if isCollapsed { set.remove(key) } else { set.insert(key) }
                collapsed = set.sorted().joined(separator: ",")
            } label: {
                HStack {
                    Text(title).font(.caption.weight(.semibold)).tracking(1.2).textCase(.uppercase)
                    Spacer()
                    Image(systemName: "chevron.down").imageScale(.small).rotationEffect(.degrees(isCollapsed ? -90 : 0))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider()
            if !isCollapsed { content() }
        }
    }
}

private struct TileGrid<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 8)], alignment: .leading, spacing: 8) { content() }
    }
}

/// A big value with an uppercase label above and a small line below.
private struct Tile: View {
    let label: LocalizedStringKey
    let value: String
    var sub: String?
    var subTint: Color = .secondary

    init(_ label: LocalizedStringKey, _ value: String, sub: String? = nil, subTint: Color = .secondary) {
        self.label = label
        self.value = value
        self.sub = sub
        self.subTint = subTint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2.weight(.medium)).tracking(0.8).textCase(.uppercase).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            if let sub { Text(sub).font(.caption).foregroundStyle(subTint).lineLimit(1).minimumScaleFactor(0.8) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct StatusTable<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct StatusRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) { content() }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            Divider().opacity(0.5)
        }
    }
}

/// The pass's peak speed on one axis against what the mount does.
private struct RateBar: View {
    let label: LocalizedStringKey
    let need: Double
    let limit: Double

    var body: some View {
        let over = need > limit
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.callout)
                Spacer()
                Text("\(fixed(need, 1))°/s of \(fixed(limit, 1))°/s").font(.callout).monospacedDigit()
                    .foregroundStyle(over ? Theme.scope : .primary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(over ? Theme.scope : Theme.rising)
                        .frame(width: proxy.size.width * min(1, need / limit))
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A number to a set count of decimals in the reader's own style (a decimal comma in German and
/// Spanish), without grouping, as `String(format:)` gave it.
private func fixed(_ x: Double, _ digits: Int, signed: Bool = false) -> String {
    x.formatted(.number.precision(.fractionLength(digits)).grouping(.never).sign(strategy: signed ? .always() : .automatic))
}
