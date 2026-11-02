import SkyKit
import SwiftUI

/// Passes of objects flying together (a space station's modules and docked ships, each with
/// its own TLE), shown as one row.
struct PassGroup: Identifiable {
    let lead: SatellitePass
    let others: [SatellitePass]
    var id: String { lead.id }

    /// Groups passes that rise and set within 10 s of each other and peak within 1°, keeping the
    /// order. A pass in `preferring` (the target or the highlighted one) leads its group.
    static func docked(_ passes: [SatellitePass], preferring: [String] = []) -> [PassGroup] {
        var groups: [[SatellitePass]] = []
        for pass in passes {
            if let i = groups.firstIndex(where: { together($0[0], pass) }) {
                groups[i].append(pass)
            } else {
                groups.append([pass])
            }
        }
        return groups.map { group in
            let lead = group.first { preferring.contains($0.id) } ?? group[0]
            return PassGroup(lead: lead, others: group.filter { $0.id != lead.id })
        }
    }

    static func together(_ a: SatellitePass, _ b: SatellitePass) -> Bool {
        abs(a.start.date.timeIntervalSince(b.start.date)) < 10 && abs(a.end.date.timeIntervalSince(b.end.date)) < 10
            && abs(a.maxAltitude - b.maxAltitude) < 1
            && abs(wrap180(a.culmination.position.azimuth - b.culmination.position.azimuth)) < 2
    }
}

struct PassRow: View {
    @Environment(AppModel.self) private var model
    let pass: SatellitePass
    /// Others flying with it (docked modules), named on the "+N" chip.
    var docked: [String] = []

    var body: some View {
        // The shared ticker, not a TimelineView: one inside each List cell kept the main thread
        // about 70% busy on an iPhone (30% on a Mac) whatever its period (measured 26 Oct 2026).
        let now = model.viewDate(Ticker.shared.now)
        do {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(pass.name).font(.headline).lineLimit(1).layoutPriority(1)
                        SourceTag(noradID: pass.noradID)
                    }
                    Text("\(pass.start.date, format: .dateTime.weekday().hour().minute()) · \(Duration.seconds(pass.duration).formatted(.time(pattern: .minuteSecond))) · \(compass(pass.start.position.azimuth)) → \(compass(pass.end.position.azimuth))")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing: 5) {
                        RiseCountdown(start: pass.start.date, end: pass.end.date, now: now)
                        if pass.isVisible { Chip(text: String(localized: "Visible"), systemImage: "eye.fill", tint: Theme.focus) }
                        if pass.isEclipsed { Chip(text: String(localized: "Eclipsed"), systemImage: "moon.fill", tint: Theme.eclipsed) }
                        if !docked.isEmpty {
                            Chip(text: String(localized: "+\(docked.count) docked"), systemImage: "link", tint: Theme.sunlit)
                                .help("Flying together: \(docked.joined(separator: ", "))")
                        }
                    }
                }
                Spacer(minLength: 6)
                PassProfile(pass: pass, now: now)
                    .frame(width: 64, height: 30)
                VStack(alignment: .trailing, spacing: 0) {
                    if let status = pass.status(at: now) {
                        HStack(spacing: 2) {
                            Text("\(Int(status.altitude.rounded()))°")
                            Image(systemName: status.trend == .rising ? "arrow.up" : "arrow.down")
                                .font(.caption.bold())
                                .foregroundStyle(status.trend == .rising ? Theme.rising : Theme.setting)
                        }
                        .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
                        Text("max \(Int(pass.maxAltitude.rounded()))°").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    } else {
                        Text("\(Int(pass.maxAltitude.rounded()))°")
                            .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
                        Text("peak").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 50, alignment: .trailing)
            }
            .padding(.vertical, 3)
            .accessibilityElement(children: .combine)
        }
    }
}

/// Where a satellite's elements come from, in small type after its name: "Amateur radio", with
/// "+1" when another source lists it too. It gives way before the name does when space is short.
struct SourceTag: View {
    @Environment(AppModel.self) private var model
    let noradID: String
    /// On Look Up's dark card, over the camera picture.
    var onDark = false

    var body: some View {
        if let origin = model.origin(of: noradID) {
            Text(origin.others.isEmpty ? origin.name : "\(origin.name) +\(origin.others.count)")
                .font(.caption)
                .foregroundStyle(onDark ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .help(origin.others.isEmpty ? String(localized: "Elements from \(origin.name)")
                      : String(localized: "Elements from \(origin.name), the newest; also in \(origin.others.joined(separator: ", "))"))
                .accessibilityLabel("from \(origin.name)")
        }
    }
}

/// "Rises in 12 min", "Up now · sets in 3 min", ticking each second in the last minutes.
struct RiseCountdown: View {
    let start: Date
    let end: Date
    let now: Date

    var body: some View {
        Group {
            if now < start {
                Text("Rises in \(countdown(start.timeIntervalSince(now)))")
                    .foregroundStyle(start.timeIntervalSince(now) < 300 ? Theme.setting : .secondary)
            } else if now < end {
                HStack(spacing: 4) {
                    StatusDot(color: Theme.rising).scaleEffect(0.8)
                    Text("Up now · sets in \(countdown(end.timeIntervalSince(now)))")
                }
                .foregroundStyle(Theme.rising)
            }
        }
        .font(.caption.weight(.medium).monospacedDigit())
    }
}

/// Seconds while it's under a minute, minutes and seconds under ten, then coarser.
func countdown(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded(.up))
    switch s {
    case ..<60: return String(localized: "\(s) s")
    case ..<600: return String(localized: "\(s / 60) min \(String(format: "%02d", s % 60)) s")
    case ..<3600: return String(localized: "\(s / 60) min")
    case ..<86_400: return String(localized: "\(s / 3600) h \(String(format: "%02d", (s % 3600) / 60)) min")
    default: return String(localized: "\(s / 86_400) d \((s % 86_400) / 3600) h", comment: "Days and hours")
    }
}

func compass(_ azimuth: Double) -> String {
    compassPoints[Int((normalizedDegrees(azimuth) / 22.5).rounded()) % 16]
}

/// The sixteen points from north, clockwise. German writes O for east, Spanish O for west.
let compassPoints = [
    String(localized: "N", comment: "Compass point"), String(localized: "NNE", comment: "Compass point"),
    String(localized: "NE", comment: "Compass point"), String(localized: "ENE", comment: "Compass point"),
    String(localized: "E", comment: "Compass point"), String(localized: "ESE", comment: "Compass point"),
    String(localized: "SE", comment: "Compass point"), String(localized: "SSE", comment: "Compass point"),
    String(localized: "S", comment: "Compass point"), String(localized: "SSW", comment: "Compass point"),
    String(localized: "SW", comment: "Compass point"), String(localized: "WSW", comment: "Compass point"),
    String(localized: "W", comment: "Compass point"), String(localized: "WNW", comment: "Compass point"),
    String(localized: "NW", comment: "Compass point"), String(localized: "NNW", comment: "Compass point"),
]

struct FilterSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("When") {
                    Picker("Look ahead", selection: $model.filter.hoursAhead) {
                        Text("6 hours").tag(6.0)
                        Text("8 hours").tag(8.0)
                        Text("12 hours").tag(12.0)
                        Text("1 day").tag(24.0)
                        Text("3 days").tag(72.0)
                        Text("7 days").tag(168.0)
                    }
                    Picker("Sort by", selection: $model.filter.sort) {
                        ForEach(FilterSettings.Sort.allCases) { Text($0.label).tag($0) }
                    }
                }
                Section("Pass") {
                    LabeledSlider("Peaks at least", value: $model.filter.minimumMaxAltitude, in: 0...85, step: 5, unit: "°")
                    LabeledSlider("Lasts at least", value: $model.filter.minimumDurationMinutes, in: 0...10, step: 1, unit: " min")
                    Toggle("Visible only", isOn: $model.filter.visibleOnly)
                    LabeledSlider("Keep away from the Sun", value: $model.filter.minimumSunSeparation, in: 0...45, step: 5, unit: "°")
                }
                Section {
                    Toggle("Mount can track it", isOn: $model.filter.trackableOnly)
                    if model.filter.trackableOnly {
                        LabeledSlider("Allow losing it for", value: $model.filter.maximumSecondsOffTarget, in: 0...60, step: 5, unit: " s")
                    }
                } header: {
                    Text("Mount")
                } footer: {
                    Text("Uses the cable stop, altitude limits and axis speeds from Settings. Passes near the zenith need a fast azimuth swing, so the mount may lose them briefly at the top.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Filters")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
    }
}

struct LabeledSlider: View {
    let title: Text
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    /// A literal title is looked up in the string catalog, as with SwiftUI's own controls.
    init(_ titleKey: LocalizedStringKey, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, unit: String) {
        self.init(title: Text(titleKey), value: value, in: range, step: step, unit: unit)
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, unit: String) {
        self.init(title: Text(title), value: value, in: range, step: step, unit: unit)
    }

    private init(title: Text, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, unit: String) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.unit = unit
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                title
                Spacer()
                Text("\(value, format: .number.precision(.fractionLength(0)))\(unit)").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

struct PassDetailView: View {
    @Environment(AppModel.self) private var model
    let pass: SatellitePass

    var body: some View {
        let plan = model.plan(for: pass)
        ScrollView {
            VStack(spacing: 16) {
                TimelineView(.periodic(from: Theme.clockAnchor, by: 1)) { context in
                    SkyDome(observer: model.settings.observer, date: model.viewDate(context.date), pass: pass, plan: plan,
                            tolerance: model.settings.pointingTolerance, cableStopAzimuth: model.settings.cableStopAzimuth)
                }
                .frame(maxWidth: 520)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        Text("Time").bold()
                        Text("Azimuth").bold()
                        Text("Altitude").bold()
                    }
                    pointRow("Rises", pass.start)
                    pointRow("Peaks", pass.culmination)
                    pointRow("Sets", pass.end)
                }
                .font(.callout.monospacedDigit())

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    fact("Duration", Duration.seconds(pass.duration).formatted(.time(pattern: .minuteSecond)))
                    fact("Visible", visibility)
                    fact("Closest", model.units.distance(pass.minimumRange))
                    fact("Nearest the Sun", "\(Int(pass.minimumSunSeparation))°")
                    fact("Fastest azimuth", "\(pass.peakAzimuthRate.formatted(.number.precision(.fractionLength(1))))°/s")
                    fact("Fastest altitude", "\(pass.peakAltitudeRate.formatted(.number.precision(.fractionLength(1))))°/s")
                    fact("Mount", mountSummary(plan))
                    if let sat = model.satellites.first(where: { $0.noradID == pass.noradID }) {
                        fact("Elements", String(localized: "\((sat.elementAge() / 86_400).formatted(.number.precision(.fractionLength(1)))) days old"))
                    }
                }
                .font(.callout)
                .frame(maxWidth: 520, alignment: .leading)
            }
            .padding()
        }
        .navigationTitle(pass.name)
    }

    var visibility: String {
        guard let range = pass.visibleSamples else { return String(localized: "No (in shadow or daylight)") }
        let from = pass.track[range.lowerBound].date, to = pass.track[range.upperBound - 1].date
        return "\(from.formatted(date: .omitted, time: .shortened))–\(to.formatted(date: .omitted, time: .shortened))"
    }

    func mountSummary(_ plan: MountPlan?) -> String {
        guard let plan else { return String(localized: "Can't track: exceeds the altitude limits") }
        let how = switch plan.orientation {
        case .normal: String(localized: "Normal", comment: "How the mount follows a pass")
        case .overTheTop: String(localized: "Over the top")
        case .flipAtCulmination: String(localized: "Flips over the top at the peak")
        }
        if plan.unwindSeconds > 0 {
            return String(localized: "\(how); crosses north, where the mount goes the long way round (about \(Int(plan.unwindSeconds)) s)")
        }
        return plan.secondsOffTarget == 0 ? how : String(localized: "\(how); loses it for \(Int(plan.secondsOffTarget)) s near the top")
    }

    func pointRow(_ label: LocalizedStringKey, _ s: PassSample) -> some View {
        GridRow {
            Text(label)
            Text(s.date, format: .dateTime.hour().minute().second())
            Text("\(Int(s.position.azimuth))° \(compass(s.position.azimuth))")
            Text("\(Int(s.position.altitude.rounded()))°")
        }
    }

    func fact(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}
