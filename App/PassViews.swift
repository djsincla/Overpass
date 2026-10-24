import SkyKit
import SwiftUI

struct PassRow: View {
    let pass: SatellitePass

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pass.name).font(.headline)
                Text("\(pass.start.date, format: .dateTime.weekday().hour().minute()) · \(Duration.seconds(pass.duration).formatted(.time(pattern: .minuteSecond)))")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(pass.maxAltitude.rounded()))°").font(.title3.monospacedDigit().bold())
                HStack(spacing: 4) {
                    if pass.isVisible { Image(systemName: "eye.fill").foregroundStyle(.yellow) }
                    Text(compass(pass.start.position.azimuth) + "→" + compass(pass.end.position.azimuth))
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
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
                    SkyDome(observer: model.settings.observer, date: context.date, pass: pass, plan: plan,
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
