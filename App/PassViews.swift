import SkyKit
import SwiftUI

struct PassRow: View {
    @Environment(AppModel.self) private var model
    let pass: SatellitePass

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = model.viewDate(context.date)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(pass.name).font(.headline).lineLimit(1)
                    Text("\(pass.start.date, format: .dateTime.weekday().hour().minute()) · \(Duration.seconds(pass.duration).formatted(.time(pattern: .minuteSecond))) · \(compass(pass.start.position.azimuth)) → \(compass(pass.end.position.azimuth))")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing: 5) {
                        RiseCountdown(start: pass.start.date, end: pass.end.date, now: now)
                        if pass.isVisible { Chip(text: "Visible", systemImage: "eye.fill", tint: Theme.focus) }
                        if pass.isEclipsed { Chip(text: "Eclipsed", systemImage: "moon.fill", tint: Theme.eclipsed) }
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
        }
        .accessibilityElement(children: .combine)
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
    case ..<60: return "\(s) s"
    case ..<600: return "\(s / 60) min \(String(format: "%02d", s % 60)) s"
    case ..<3600: return "\(s / 60) min"
    case ..<86_400: return "\(s / 3600) h \(String(format: "%02d", (s % 3600) / 60)) min"
    default: return "\(s / 86_400) d \((s % 86_400) / 3600) h"
    }
}

func compass(_ azimuth: Double) -> String {
    let names = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
    return names[Int((normalizedDegrees(azimuth) / 22.5).rounded()) % 16]
}

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
                        Text("12 hours").tag(12.0)
                        Text("1 day").tag(24.0)
                        Text("3 days").tag(72.0)
                        Text("7 days").tag(168.0)
                    }
                    Picker("Sort by", selection: $model.filter.sort) {
                        ForEach(FilterSettings.Sort.allCases) { Text($0.rawValue).tag($0) }
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
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, unit: String) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.unit = unit
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
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
                TimelineView(.periodic(from: .now, by: 1)) { context in
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
                    fact("Closest", "\(Int(pass.minimumRange)) km")
                    fact("Nearest the Sun", "\(Int(pass.minimumSunSeparation))°")
                    fact("Fastest azimuth", String(format: "%.1f°/s", pass.peakAzimuthRate))
                    fact("Fastest altitude", String(format: "%.1f°/s", pass.peakAltitudeRate))
                    fact("Mount", mountSummary(plan))
                    if let sat = model.satellites.first(where: { $0.noradID == pass.noradID }) {
                        fact("Elements", "\(String(format: "%.1f", sat.elementAge() / 86_400)) days old")
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
        guard let range = pass.visibleSamples else { return "No (in shadow or daylight)" }
        let from = pass.track[range.lowerBound].date, to = pass.track[range.upperBound - 1].date
        return "\(from.formatted(date: .omitted, time: .shortened))–\(to.formatted(date: .omitted, time: .shortened))"
    }

    func mountSummary(_ plan: MountPlan?) -> String {
        guard let plan else { return "Can't track: crosses the cable stop or exceeds the altitude limits" }
        let how = switch plan.orientation {
        case .normal: "Normal"
        case .overTheTop: "Over the top"
        case .flipAtCulmination: "Flips over the top at the peak"
        }
        return plan.secondsOffTarget == 0 ? how : "\(how); loses it for \(Int(plan.secondsOffTarget)) s near the top"
    }

    func pointRow(_ label: String, _ s: PassSample) -> some View {
        GridRow {
            Text(label)
            Text(s.date, format: .dateTime.hour().minute().second())
            Text("\(Int(s.position.azimuth))° \(compass(s.position.azimuth))")
            Text("\(Int(s.position.altitude.rounded()))°")
        }
    }

    func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}
