import SkyKit
import SwiftUI

/// The one screen for observing: the sky, what's coming up, and the mount.
struct ObserveView: View {
    @Environment(AppModel.self) private var model
    @State private var panel = Panel.passes
    @State private var showingFilters = false
    // Where the dividers were left, remembered between launches.
    @AppStorage("observe.domeFraction") private var domeFraction = 0.5
    @AppStorage("observe.listFraction") private var listFraction = 0.45
    @AppStorage("observe.phoneDomeFraction") private var phoneDomeFraction = 0.42

    enum Panel: String, CaseIterable, Identifiable {
        case passes = "Passes", objects = "Objects", mount = "Mount"
        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.settings.hasLocation {
                    GeometryReader { proxy in
                        if proxy.size.width > 760 {
                            // Mac and iPad: dome | (list over mount panel), both dividers draggable.
                            ResizableSplit(axis: .horizontal, fraction: $domeFraction, range: 0.25...0.75) {
                                dome.padding()
                            } second: {
                                ResizableSplit(axis: .vertical, fraction: $listFraction, range: 0.15...0.85) {
                                    VStack(spacing: 0) {
                                        Picker("List", selection: listBinding) {
                                            Text("Passes").tag(Panel.passes)
                                            Text("Objects").tag(Panel.objects)
                                        }
                                        .pickerStyle(.segmented)
                                        .labelsHidden()
                                        .padding(8)
                                        list(listBinding.wrappedValue)
                                    }
                                } second: {
                                    ScrollView { MountPanel().padding(12) }
                                }
                            }
                        } else {
                            // iPhone: dome over the switchable panel, divider draggable.
                            ResizableSplit(axis: .vertical, fraction: $phoneDomeFraction, range: 0.2...0.7) {
                                dome.padding(.horizontal)
                            } second: {
                                VStack(spacing: 0) {
                                    Picker("Panel", selection: $panel) {
                                        ForEach(Panel.allCases) { Text($0.rawValue).tag($0) }
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                    .padding(8)
                                    if panel == .mount {
                                        ScrollView { MountPanel().padding(12) }
                                    } else {
                                        list(panel)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    LocationNeededView()
                }
            }
            .navigationTitle("Overpass")
            .toolbar {
                @Bindable var model = model
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $model.settings.redMode) {
                        Label("Red mode", systemImage: "eye")
                    }
                    .help("Night vision: red on black")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingFilters = true } label: {
                        Label("Pass filters", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
                if model.isPredicting {
                    ToolbarItem(placement: .status) { ProgressView().controlSize(.small) }
                }
            }
            .sheet(isPresented: $showingFilters) { FilterSheet() }
        }
    }

    /// On wide screens the mount panel is always visible, so the list only switches between two.
    private var listBinding: Binding<Panel> {
        Binding(get: { panel == .mount ? .passes : panel }, set: { panel = $0 })
    }

    private var dome: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let pass = model.highlightedPass(at: context.date)
            SkyDome(observer: model.settings.observer, date: context.date, pass: pass,
                    plan: pass.flatMap(model.plan(for:)), tolerance: model.settings.pointingTolerance,
                    cableStopAzimuth: model.settings.cableStopAzimuth,
                    liveObjects: model.liveObjects(at: context.date),
                    highlightedObjectID: model.highlightedObject?.id,
                    targetObjectID: model.targetObjectID,
                    scopePosition: model.mount.skyPosition,
                    onTapObject: { model.highlight(objectID: $0) })
        }
    }

    @ViewBuilder
    private func list(_ panel: Panel) -> some View {
        VStack(spacing: 0) {
            QuickFilters()
            switch panel {
            case .objects: SelectedObjectsList()
            default: PassesList()
            }
        }
    }
}

struct PassesList: View {
    @Environment(AppModel.self) private var model
    @State private var detail: SatellitePass?

    var body: some View {
        if model.predictionTargets.isEmpty {
            ContentUnavailableView("Nothing selected", systemImage: "checklist",
                                   description: Text("Choose satellites in the Objects tab, and their passes appear here."))
        } else if model.passes.isEmpty && !model.isPredicting {
            ContentUnavailableView("No passes", systemImage: "moon.stars",
                                   description: Text("None of your \(model.predictionTargets.count) selected satellites pass in the next \(Int(model.filter.hoursAhead)) hours with these filters."))
        } else {
            List(model.passes) { pass in
                HStack {
                    // Clicking a pass only refocuses the dome on it. It never moves the mount.
                    Button { model.highlight(pass: pass) } label: { PassRow(pass: pass) }
                        .buttonStyle(.plain)
                    if model.targetPassID == pass.id {
                        Image(systemName: "scope").foregroundStyle(.green).accessibilityLabel("Tracking target")
                    }
                    Button { detail = pass } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Details for \(pass.name)")
                }
                .listRowBackground(model.highlightedPass(at: .now)?.id == pass.id ? Color.accentColor.opacity(0.15) : nil)
                .contextMenu {
                    Button("Set as tracking target") { model.setTarget(pass: pass) }
                        .disabled(model.mount.isTracking)
                    Button("Details") { detail = pass }
                }
            }
            .listStyle(.plain)
            .sheet(item: $detail) { pass in
                NavigationStack {
                    PassDetailView(pass: pass)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { detail = nil } }
                            ToolbarItem(placement: .primaryAction) {
                                Button("Set as tracking target") { model.setTarget(pass: pass); detail = nil }
                                    .disabled(model.mount.isTracking)
                            }
                        }
                }
                #if os(macOS)
                .frame(minWidth: 560, minHeight: 640)
                #endif
            }
        }
    }
}

/// The two filters people change most, right above the list.
struct QuickFilters: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack {
            Picker("Min elevation", selection: $model.filter.minimumMaxAltitude) {
                ForEach([0.0, 10, 20, 30, 45, 60], id: \.self) { Text("Peaks ≥ \(Int($0))°").tag($0) }
            }
            .fixedSize()
            Toggle("Hide eclipsed", isOn: $model.filter.hideEclipsed)
                .fixedSize()
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}

/// Selected objects (and satellites), with where they are now.
struct SelectedObjectsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.selectedObjects.isEmpty {
            ContentUnavailableView("Nothing selected", systemImage: "checklist",
                                   description: Text("Choose the Moon, planets, stars or satellites in the Objects tab."))
        } else {
            @Bindable var model = model
            VStack(spacing: 0) {
            Picker("Sort", selection: $model.filter.objectSort) {
                ForEach(FilterSettings.ObjectSort.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                List(sorted(model.selectedObjects.filter { passesFilters($0, context.date) }, context.date)) { object in
                    Button { model.highlight(objectID: object.id) } label: {
                        ObjectPositionRow(object: object, date: context.date)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(model.highlightedObject?.id == object.id ? Color.accentColor.opacity(0.15) : nil)
                    .contextMenu {
                        Button("Set as tracking target") { model.highlight(objectID: object.id); model.setTargetFromHighlight() }
                            .disabled(model.mount.isTracking)
                    }
                }
                .listStyle(.plain)
            }
            }
        }
    }

    private func sorted(_ objects: [SkyObject], _ date: Date) -> [SkyObject] {
        switch model.filter.objectSort {
        case .name:
            return objects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .riseTime:
            let keyed = objects.map { ($0, model.riseTime($0, at: date)) }
            return keyed.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.name < $1.0.name }.map(\.0)
        case .brightness:
            // Unknown brightness (most satellites) goes last.
            let keyed = objects.map { ($0, model.magnitude($0, at: date) ?? .infinity) }
            return keyed.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.name < $1.0.name }.map(\.0)
        }
    }

    /// Minimum elevation compares with how high the object gets (this pass or the next), so
    /// something low now but climbing high stays listed. Eclipsed means in shadow right now.
    private func passesFilters(_ object: SkyObject, _ date: Date) -> Bool {
        let time = AstroTime(date)
        switch object {
        case .satellite(let s):
            if model.filter.hideEclipsed, (try? s.isSunlit(at: time)) == false { return false }
            guard let pass = model.currentOrNextPass(s.noradID, at: date) else { return model.filter.minimumMaxAltitude == 0 }
            return pass.maxAltitude >= model.filter.minimumMaxAltitude
        default:
            let peak = (try? model.settings.observer.visibility(of: object.target, at: date))?.maxAltitude
            return (peak ?? -90) >= model.filter.minimumMaxAltitude
        }
    }
}

struct ObjectPositionRow: View {
    @Environment(AppModel.self) private var model
    let object: SkyObject
    let date: Date

    var body: some View {
        HStack {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(object.name)
                Brightness(object: object, date: date)
            }
            Spacer()
            ObjectStatus(object: object, date: date)
        }
    }

    var symbol: String {
        switch object {
        case .satellite: "antenna.radiowaves.left.and.right"
        case .body(.sun): "sun.max"
        case .body(.moon): "moon"
        case .body: "circle.fill"
        case .star: "star"
        }
    }
}

/// "34° ↑ · max 62°" when up; "rises 21:14 · max 45°" when not.
struct ObjectStatus: View {
    @Environment(AppModel.self) private var model
    let object: SkyObject
    let date: Date

    var body: some View {
        Group {
            switch object {
            case .satellite(let s):
                if let pass = model.currentOrNextPass(s.noradID, at: date) {
                    if let now = pass.status(at: date) {
                        HStack(spacing: 6) {
                            if (try? s.isSunlit(at: AstroTime(date))) == false {
                                Image(systemName: "moon.fill").foregroundStyle(.secondary).accessibilityLabel("Eclipsed")
                            }
                            ElevationNow(altitude: now.altitude, trend: now.trend, max: pass.maxAltitude)
                        }
                    } else {
                        Text("rises in \(countdown(pass.start.date.timeIntervalSince(date))) · max \(Int(pass.maxAltitude.rounded()))°")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("no pass in \(Int(model.filter.hoursAhead)) h").foregroundStyle(.secondary)
                }
            default:
                if let v = try? model.settings.observer.visibility(of: object.target, at: date) {
                    if v.isUp {
                        ElevationNow(altitude: v.altitude, trend: v.trend, max: v.maxAltitude)
                    } else if let rise = v.rise {
                        Text("rises in \(countdown(rise.timeIntervalSince(date)))" + (v.maxAltitude.map { " · max \(Int($0.rounded()))°" } ?? ""))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("doesn't rise").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.callout.monospacedDigit())
    }
}

struct ElevationNow: View {
    let altitude: Double
    let trend: ObjectVisibility.Trend
    let max: Double?

    var body: some View {
        HStack(spacing: 4) {
            Text("\(Int(altitude.rounded()))°")
            Image(systemName: trend == .rising ? "arrow.up" : "arrow.down")
                .foregroundStyle(trend == .rising ? .green : .orange)
            if let max { Text("· max \(Int(max.rounded()))°").foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int(altitude.rounded())) degrees, \(trend == .rising ? "rising" : "setting")"
                            + (max.map { ", maximum \(Int($0.rounded())) degrees" } ?? ""))
    }
}

/// Apparent magnitude: smaller is brighter. Satellites need a standard magnitude, which TLEs
/// don't include, so for them this only says whether they're lit.
struct Brightness: View {
    @Environment(AppModel.self) private var model
    let object: SkyObject
    let date: Date

    var body: some View {
        Group {
            if let m = model.magnitude(object, at: date) {
                Text("mag \(m, format: .number.precision(.fractionLength(1)))")
                    .accessibilityLabel("Magnitude \(m.formatted(.number.precision(.fractionLength(1))))")
            } else if case .satellite(let s) = object {
                Text((try? s.isSunlit(at: AstroTime(date))) == true ? "sunlit · mag unknown" : "eclipsed")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}
