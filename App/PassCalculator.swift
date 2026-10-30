import SkyKit
import SwiftUI

/// Every pass of one object over the coming days (up to two weeks), grouped by day.
struct PassCalculatorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var objectID: String
    @State private var days = 7.0
    @State private var minimumPeak = 10.0
    @State private var visibleOnly = false
    @State private var rows: [CalculatedPass] = []
    @State private var computing = false
    @State private var failure: String?
    @State private var detail: SatellitePass?

    private struct Request: Hashable {
        let objectID: String
        let days: Double
        let minimumPeak: Double
        let visibleOnly: Bool
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                Divider()
                results
            }
            .navigationTitle("Pass calculator")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: csv, preview: SharePreview("\(object?.name ?? "Passes").csv")) {
                        Label("Export CSV", systemImage: "square.and.arrow.up")
                    }
                    .disabled(rows.isEmpty)
                }
            }
            .task(id: Request(objectID: objectID, days: days, minimumPeak: minimumPeak, visibleOnly: visibleOnly)) {
                await compute()
            }
            .sheet(item: $detail) { pass in
                NavigationStack {
                    PassDetailView(pass: pass)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { detail = nil } } }
                }
                #if os(macOS)
                .frame(minWidth: 560, minHeight: 640)
                #endif
            }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 680)
        #endif
    }

    private var object: SkyObject? { model.object(objectID) }

    /// The selected objects, plus the one shown if it isn't selected.
    private var choices: [SkyObject] {
        var list = model.selectedObjects
        if let object, !list.contains(where: { $0.id == object.id }) { list.insert(object, at: 0) }
        return list
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let object { ObjectBadge(object: object) }
                Picker("Object", selection: $objectID) {
                    ForEach(choices) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .lineLimit(1)
                Spacer(minLength: 0)
                if computing { ProgressView().controlSize(.small) }
            }
            // One row where it fits; on an iPhone it wraps onto more lines rather than
            // pushing the row past both edges of the screen.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { daysPicker; peakPicker; visibleToggle }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) { daysPicker; peakPicker }
                    visibleToggle
                }
                VStack(alignment: .leading, spacing: 8) {
                    daysPicker
                    HStack(spacing: 12) { peakPicker; visibleToggle }
                }
            }
            .font(.callout)
            Text(summary).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var daysPicker: some View {
        Picker("Days", selection: $days) {
            ForEach([1.0, 3, 7, 14], id: \.self) { Text($0 == 1 ? "1 day" : "\(Int($0)) days").tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var peakPicker: some View {
        Picker("Peaks at least", selection: $minimumPeak) {
            ForEach([0.0, 10, 20, 30, 45, 60], id: \.self) { Text("Peaks ≥ \(Int($0))°").tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }

    @ViewBuilder
    private var visibleToggle: some View {
        if object?.isSatellite == true {
            Toggle("Visible only", isOn: $visibleOnly).fixedSize()
        }
    }

    private var summary: String {
        if let failure { return failure }
        if computing && rows.isEmpty { return "Calculating…" }
        let count = rows.count == 1 ? "1 pass" : "\(rows.count) passes"
        let visible = object?.isSatellite == true && !visibleOnly ? " · \(rows.filter(\.isVisible).count) visible" : ""
        return "\(count) in the next \(Int(days)) day\(days == 1 ? "" : "s")\(visible) · from \(Int(model.settings.minimumAltitude))° above the horizon"
    }

    // MARK: Results

    @ViewBuilder
    private var results: some View {
        if rows.isEmpty && !computing {
            ContentUnavailableView("No passes", systemImage: "calendar.badge.exclamationmark",
                                   description: Text("Nothing in the next \(Int(days)) days with these settings. Try a lower peak or more days."))
        } else {
            List {
                ForEach(days(of: rows), id: \.day) { group in
                    Section {
                        ForEach(group.rows) { row in
                            Button { detail = row.satellitePass } label: { CalculatorRow(row: row) }
                                .buttonStyle(.plain)
                                .disabled(row.satellitePass == nil)
                                .contextMenu { menu(for: row) }
                        }
                    } header: {
                        Text(group.day, format: .dateTime.weekday(.wide).month().day())
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private func menu(for row: CalculatedPass) -> some View {
        let when = row.start ?? row.peak ?? .now
        let offset = when.timeIntervalSinceNow
        Button("Show on the timeline") {
            model.timeShift = min(max(offset, -AppModel.maximumTimeShift), AppModel.maximumTimeShift)
            model.highlight(objectID: objectID)
            if let pass = row.satellitePass { model.highlight(pass: pass) }
            dismiss()
        }
        .disabled(abs(offset) > AppModel.maximumTimeShift)
        if let pass = row.satellitePass {
            Button("Details") { detail = pass }
        }
    }

    private func days(of rows: [CalculatedPass]) -> [(day: Date, rows: [CalculatedPass])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: rows) { calendar.startOfDay(for: $0.start ?? $0.peak ?? .now) }
        return grouped.keys.sorted().map { ($0, grouped[$0]!) }
    }

    // MARK: Calculation

    private func compute() async {
        guard let object else { return }
        computing = true
        failure = nil
        defer { computing = false }
        let s = model.settings
        let from = Date.now, to = from + days * 86_400
        let minimumPeak = minimumPeak, visibleOnly = visibleOnly
        do {
            let result: [CalculatedPass] = try await Task.detached {
                switch object {
                case .satellite(let sat):
                    var predictor = PassPredictor(observer: s.observer)
                    predictor.minimumAltitude = s.minimumAltitude
                    predictor.darkSkySunAltitude = s.darkSkySunAltitude
                    // Coarser tracks than the live list: two weeks of one-second samples is a lot.
                    predictor.sampleInterval = sat.period < 225 ? 5 : 60
                    return try predictor.passes(of: sat, from: from, to: to)
                        .filter { $0.maxAltitude >= minimumPeak && (!visibleOnly || $0.isVisible) }
                        .map(CalculatedPass.init)
                default:
                    return try s.observer.upPeriods(of: object.target, from: from, to: to, horizon: s.minimumAltitude)
                        .filter { ($0.maxAltitude ?? 90) >= minimumPeak }
                        .map { CalculatedPass($0, object: object) }
                }
            }.value
            guard !Task.isCancelled else { return }
            rows = result
        } catch {
            rows = []
            failure = "Couldn't calculate: \(error.localizedDescription)"
        }
    }

    // MARK: Export

    private var csv: String {
        let time = Date.ISO8601FormatStyle(timeZone: .current).year().month().day().time(includingFractionalSeconds: false)
        func date(_ d: Date?) -> String { d.map { $0.formatted(time) } ?? "" }
        func degrees(_ x: Double?) -> String { x.map { String(format: "%.0f", $0) } ?? "" }
        var lines = ["Object,Rise,Rise azimuth,Peak,Peak altitude,Set,Set azimuth,Duration (s),Visible,Eclipsed"]
        for r in rows {
            let name = (object?.name ?? "").replacingOccurrences(of: "\"", with: "\"\"")
            lines.append([
                "\"\(name)\"", date(r.start), degrees(r.startAzimuth), date(r.peak), degrees(r.maxAltitude),
                date(r.end), degrees(r.endAzimuth), r.duration.map { String(Int($0)) } ?? "",
                r.satellitePass == nil ? "" : (r.isVisible ? "yes" : "no"),
                r.satellitePass == nil ? "" : (r.isEclipsed ? "yes" : "no"),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// One pass or up-period, for satellites and slow movers alike.
struct CalculatedPass: Identifiable, Sendable {
    let id: String
    /// Nil if it was already up when the calculation started.
    let start: Date?
    let peak: Date?
    /// Nil if it's still up at the end, or never sets.
    let end: Date?
    let startAzimuth: Double?
    let endAzimuth: Double?
    let maxAltitude: Double?
    let satellitePass: SatellitePass?

    var duration: TimeInterval? {
        guard let start, let end else { return nil }
        return end.timeIntervalSince(start)
    }
    var isVisible: Bool { satellitePass?.isVisible ?? false }
    var isEclipsed: Bool { satellitePass?.isEclipsed ?? false }

    init(_ pass: SatellitePass) {
        id = pass.id
        start = pass.truncated ? nil : pass.start.date
        peak = pass.culmination.date
        end = pass.end.date
        startAzimuth = pass.start.position.azimuth
        endAzimuth = pass.end.position.azimuth
        maxAltitude = pass.maxAltitude
        satellitePass = pass
    }

    init(_ period: UpPeriod, object: SkyObject) {
        id = "\(object.id)-\(Int((period.rise ?? period.peak ?? .distantPast).timeIntervalSince1970))"
        start = period.rise
        peak = period.peak
        end = period.set
        startAzimuth = period.riseAzimuth
        endAzimuth = period.setAzimuth
        maxAltitude = period.maxAltitude
        satellitePass = nil
    }
}

struct CalculatorRow: View {
    let row: CalculatedPass

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(time(row.start, else: "Up now")) → \(time(row.end, else: "stays up"))")
                    .font(.headline.monospacedDigit())
                Text(detail).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                if row.satellitePass != nil {
                    HStack(spacing: 5) {
                        if row.isVisible { Chip(text: "Visible", systemImage: "eye.fill", tint: Theme.focus) }
                        if row.isEclipsed { Chip(text: "Eclipsed", systemImage: "moon.fill", tint: Theme.eclipsed) }
                    }
                }
            }
            Spacer(minLength: 6)
            if let pass = row.satellitePass {
                PassProfile(pass: pass, now: .now).frame(width: 60, height: 28)
            }
            VStack(alignment: .trailing, spacing: 0) {
                Text(row.maxAltitude.map { "\(Int($0.rounded()))°" } ?? "—")
                    .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
                Text(row.peak.map { "at \($0.formatted(date: .omitted, time: .shortened))" } ?? "peak")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts: [String] = []
        if let a = row.startAzimuth, let b = row.endAzimuth { parts.append("\(compass(a)) → \(compass(b))") }
        if let d = row.duration {
            parts.append(d < 3600 ? Duration.seconds(d).formatted(.time(pattern: .minuteSecond))
                                  : Duration.seconds(d).formatted(.time(pattern: .hourMinute)) + " h")
        }
        if row.start == nil && row.end == nil { parts.append("Circumpolar: never sets") }
        return parts.joined(separator: " · ")
    }

    private func time(_ date: Date?, else fallback: String) -> String {
        date.map { $0.formatted(date: .omitted, time: .shortened) } ?? fallback
    }
}
