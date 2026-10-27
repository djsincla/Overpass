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
    @AppStorage("observe.columnFraction") private var columnFraction = 0.42
    @AppStorage("observe.threeListFraction") private var threeListFraction = 0.3
    @AppStorage("observe.threeDomeFraction") private var threeDomeFraction = 0.6
    @AppStorage("observe.layout") private var layout = Layout.listLeft
    /// The sky, or the Earth (as a globe or a flat map) with the ground tracks.
    @AppStorage("observe.view") private var view = SkyView.sky
    @State private var recentreRequest = 0
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    /// How the sky, the list and the mount panel sit on a wide screen.
    enum Layout: String, CaseIterable, Identifiable {
        case skyLeft, listLeft, threeColumns
        var id: Self { self }
        var title: String {
            switch self {
            case .skyLeft: "Sky on the left"
            case .listLeft: "List on the left"
            case .threeColumns: "List, sky, mount"
            }
        }
    }

    enum Panel: String, CaseIterable, Identifiable {
        case passes = "Passes", objects = "Objects", mount = "Mount"
        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.settings.hasLocation {
                    GeometryReader { proxy in
                        if proxy.size.width > 760 && proxy.size.height > 560 {
                            // Mac and iPad: arranged as chosen in the Layout menu, dividers draggable.
                            wideLayout
                        } else if proxy.size.width > proxy.size.height {
                            // iPhone on its side: the sky as tall as the screen, the switchable panel beside it.
                            HStack(spacing: 0) {
                                dome
                                    .padding(8)
                                    .frame(width: min(proxy.size.height, proxy.size.width * 0.5))
                                Divider()
                                switchablePanel
                            }
                        } else {
                            // iPhone: dome over the switchable panel, divider draggable.
                            ResizableSplit(axis: .vertical, fraction: $phoneDomeFraction, range: 0.2...0.7) {
                                dome.padding(.horizontal)
                            } second: {
                                switchablePanel
                            }
                        }
                    }
                } else {
                    LocationNeededView()
                }
            }
            .navigationTitle("Overpass")
            #if os(iOS)
            // On a phone on its side the large title takes a quarter of the height.
            .navigationBarTitleDisplayMode(verticalSizeClass == .compact ? .inline : .automatic)
            #endif
            .toolbar {
                @Bindable var model = model
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $model.settings.redMode) {
                        Label("Red mode", systemImage: "eye")
                    }
                    .help("Night vision: red on black")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.calculatorObjectID = model.highlightedObject?.id ?? model.selectedObjects.first?.id
                    } label: {
                        Label("Pass calculator", systemImage: "calendar.badge.clock")
                    }
                    .help("Every pass of an object over the next two weeks")
                    .disabled(model.selectedObjects.isEmpty)
                }
                if isWide {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Picker("Layout", selection: $layout) {
                                ForEach(Layout.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.inline)
                        } label: {
                            Label("Layout", systemImage: "rectangle.split.3x1")
                        }
                        .help("Arrange the sky, the list and the mount panel")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingFilters = true } label: {
                        Label("Pass filters", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
                if model.isPredicting {
                    ToolbarItem(placement: .status) { ProgressView().controlSize(.small) }
                }
                // Always reachable, however the panels are arranged or scrolled.
                if model.mount.isTracking || model.mount.isPreparing {
                    ToolbarItem(placement: .primaryAction) {
                        Button(role: .destructive) { Task { await model.mount.stopAll() } } label: {
                            Label("Cancel tracking", systemImage: "xmark.circle.fill")
                        }
                        .tint(Theme.scope)
                        .keyboardShortcut(.escape, modifiers: [])
                        .help("Cancel tracking or the move to the start point, and stop the mount (Esc)")
                    }
                }
            }
            .sheet(isPresented: $showingFilters) { FilterSheet() }
            .sheet(isPresented: Binding(get: { model.calculatorObjectID != nil },
                                        set: { if !$0 { model.calculatorObjectID = nil } })) {
                PassCalculatorView(objectID: model.calculatorObjectID ?? "")
            }
        }
    }

    /// The Layout menu only matters where the screen is wide enough for side-by-side panels.
    private var isWide: Bool {
        #if os(iOS)
        sizeClass == .regular && verticalSizeClass != .compact
        #else
        true
        #endif
    }

    @ViewBuilder
    private var wideLayout: some View {
        switch layout {
        case .skyLeft:
            ResizableSplit(axis: .horizontal, fraction: $domeFraction, range: 0.25...0.75) {
                dome.padding()
            } second: {
                listOverMount
            }
        case .listLeft:
            ResizableSplit(axis: .horizontal, fraction: $columnFraction, range: 0.25...0.75) {
                listOverMount
            } second: {
                dome.padding()
            }
        case .threeColumns:
            ResizableSplit(axis: .horizontal, fraction: $threeListFraction, range: 0.15...0.6) {
                listPane
            } second: {
                ResizableSplit(axis: .horizontal, fraction: $threeDomeFraction, range: 0.3...0.8) {
                    dome.padding()
                } second: {
                    ScrollView { MountPanel().padding(12) }
                }
            }
        }
    }

    private var listOverMount: some View {
        ResizableSplit(axis: .vertical, fraction: $listFraction, range: 0.15...0.85) {
            listPane
        } second: {
            ScrollView { MountPanel().padding(12) }
        }
    }

    /// iPhone: Passes, Objects or the mount panel, switched at the top.
    private var switchablePanel: some View {
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

    /// Passes or Objects, switched at the top.
    private var listPane: some View {
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
    }

    /// On wide screens the mount panel is always visible, so the list only switches between two.
    private var listBinding: Binding<Panel> {
        Binding(get: { panel == .mount ? .passes : panel }, set: { panel = $0 })
    }

    private var dome: some View {
        VStack(spacing: 0) {
        // Above the view, so it covers neither the sky's compass nor the map's own controls.
        HStack(spacing: 8) {
            Picker("View", selection: $view) {
                ForEach(SkyView.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("The sky overhead, or the Earth with the ground tracks as a globe or a flat map")
            if view != .sky {
                Button { recentreRequest += 1 } label: { Image(systemName: "location") }
                    .buttonStyle(.borderless)
                    .help("Back to the whole Earth, centred on you")
                    .accessibilityLabel("Centre on your location")
            }
        }
        .padding(.vertical, 6)
        TimelineView(.periodic(from: Theme.clockAnchor, by: 1)) { context in
            let date = model.viewDate(context.date)
            let shown = model.shownPasses(at: date)
            let highlighted = model.highlightedPass(at: date)
            let pass = shown.first { $0.id == highlighted?.id } ?? shown.last
            Group {
                if view == .globe {
                    EarthGlobeView(home: Geodetic(latitude: model.settings.latitude, longitude: model.settings.longitude),
                                   tracks: globeTracks(shown, focus: pass, at: date),
                                   sun: (try? SolarSystemBody.sun.earthFixedPosition(at: AstroTime(date))) ?? Vec3(1, 0, 0),
                                   redMode: model.settings.redMode,
                                   recentreRequest: recentreRequest,
                                   onTapTrack: { id in if let p = shown.first(where: { $0.id == id }) { model.highlight(pass: p) } })
                } else if view == .map {
                    GlobeView(home: Geodetic(latitude: model.settings.latitude, longitude: model.settings.longitude),
                              flat: view == .map,
                              tracks: globeTracks(shown, focus: pass, at: date),
                              recentreRequest: recentreRequest,
                              onTapTrack: { id in if let p = shown.first(where: { $0.id == id }) { model.highlight(pass: p) } })
                } else {
                    sky(date: date, pass: pass, others: shown.filter { $0.id != pass?.id })
                }
            }
            .overlay(alignment: .topLeading) {
                if !model.shownTrackKeys.isEmpty { TrackLegend(passes: shown, focusID: pass?.id) }
            }
        }
        }
    }

    private func globeTracks(_ passes: [SatellitePass], focus: SatellitePass?, at date: Date) -> [GlobeTrack] {
        passes.map { pass in
            let points = model.groundTrack(for: pass)
            let visiblePoints = points.filter { $0.date >= pass.start.date && $0.date <= pass.end.date }
            let inWindow = points.first.map { $0.date <= date } == true && points.last.map { $0.date >= date } == true
            let now = inWindow ? model.subpoint(of: pass.noradID, at: date) : nil
            return GlobeTrack(id: pass.id, name: pass.name, color: Theme.track(model.trackIndex(pass)),
                              segments: GroundTrack.segments(points),
                              visible: GroundTrack.segments(visiblePoints),
                              path: points.map(\.place), visiblePath: visiblePoints.map(\.place),
                              now: now, footprint: now.map { GroundTrack.footprint(center: $0, height: $0.height) },
                              focused: pass.id == focus?.id)
        }
    }

    private func sky(date: Date, pass: SatellitePass?, others: [SatellitePass]) -> some View {
            SkyDome(observer: model.settings.observer, date: date, pass: pass,
                    passColor: pass.map { Theme.track(model.trackIndex($0)) } ?? .cyan,
                    otherTracks: others.map { ($0, Theme.track(model.trackIndex($0))) },
                    plan: pass.flatMap(model.plan(for:)), tolerance: model.settings.pointingTolerance,
                    cableStopAzimuth: model.mount.effectiveCableStop,
                    liveObjects: model.liveObjects(at: date),
                    highlightedObjectID: model.highlightedObject?.id,
                    targetObjectID: model.targetObjectID,
                    scopePosition: model.mount.skyPosition,
                    slewTarget: model.mount.slewTarget,
                    onTapObject: { model.highlight(objectID: $0) },
                    menu: { AnyView(domeMenu($0)) })
    }

    /// Right-click on anything in the sky: track it, target it, select it, or plan around it.
    @ViewBuilder
    private func domeMenu(_ id: String) -> some View {
        let mount = model.mount
        let name = model.object(id)?.name ?? id
        let isTarget = model.targetObjectID == id
        let busy = mount.isTracking || mount.isPreparing
        Text(name)
        if isTarget && busy {
            Button("Stop tracking") { Task { await mount.stopAll() } }
            Button("Untrack") { Task { await model.untrack() } }
        } else {
            if model.object(id)?.isSun == true {
                Button("Track the Sun from the mount panel (needs a filter)") {}.disabled(true)
            } else {
                Button("Track \(name)") { Task { await model.track(objectID: id) } }
                    .disabled(busy || !model.canTrack(model.object(id)))
            }
            Button("Set as tracking target") { model.highlight(objectID: id); model.setTargetFromHighlight() }
                .disabled(busy || isTarget)
            if isTarget {
                Button("Untrack") { Task { await model.untrack() } }
            }
        }
        Divider()
        Button("Highlight") { model.highlight(objectID: id) }
        if let pass = model.passes.first(where: { "sat:\($0.noradID)" == id && $0.end.date > model.viewDate() }) {
            Button(model.isShown(pass) ? "Hide track" : "Add track") { model.toggleTrack(pass) }
        }
        Button(model.isSelected(id) ? "Remove from selection" : "Add to selection") { model.toggle(id) }
        Button("Pass calculator…") { model.calculatorObjectID = id }
    }

    @ViewBuilder
    private func list(_ panel: Panel) -> some View {
        VStack(spacing: 0) {
            TimeBar()
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
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
    #if os(iOS)
    @State private var editMode = EditMode.inactive
    #endif

    var body: some View {
        if model.predictionTargets.isEmpty {
            ContentUnavailableView("Nothing selected", systemImage: "checklist",
                                   description: Text("Choose satellites in the Objects tab, and their passes appear here."))
        } else if model.passes.isEmpty && !model.isPredicting {
            ContentUnavailableView("No passes", systemImage: "moon.stars",
                                   description: Text("None of your \(model.predictionTargets.count) selected satellites pass in the next \(Int(model.filter.hoursAhead)) hours with these filters."))
        } else {
            // Passes still to come at the time the bar is set to; refreshed as time moves on.
            TimelineView(.periodic(from: Theme.clockAnchor, by: 5)) { context in
            let date = model.viewDate(context.date)
            let lead = [model.targetPassID, model.highlightedPass(at: date)?.id].compactMap { $0 }
            let groups = PassGroup.docked(model.passes.filter { $0.end.date > date }, preferring: lead)
            // The selection is the shown tracks: click for one, ⌘-click or ⇧-click for several
            // (Select on iPhone and iPad). Selecting only changes what the sky and globe show.
            let selection = Binding<Set<String>>(
                get: { Set(model.shownPasses(at: date).map(\.id)) },
                set: { model.setShownTracks(ids: $0, inListOrder: groups.map(\.lead)) })
            VStack(spacing: 0) {
            #if os(iOS)
            HStack {
                Text(editMode.isEditing ? "Choose up to \(AppModel.maximumShownTracks) passes to show" : "")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(editMode.isEditing ? "Done" : "Select") {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
                .font(.callout)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            #endif
            List(groups, selection: selection) { group in
                let pass = group.lead
                HStack {
                    if model.isShown(pass) && model.shownTrackKeys.count > 1 {
                        Circle().fill(Theme.track(model.trackIndex(pass))).frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                    }
                    #if os(iOS)
                    // Tapping a pass only refocuses the dome on it. It never moves the mount.
                    Button { model.highlight(pass: pass) } label: { PassRow(pass: pass, docked: group.others.map(\.name)) }
                        .buttonStyle(.plain)
                        .allowsHitTesting(!editMode.isEditing)
                    #else
                    PassRow(pass: pass, docked: group.others.map(\.name))
                    #endif
                    if model.targetPassID == pass.id {
                        Image(systemName: "scope").foregroundStyle(Theme.target).accessibilityLabel("Tracking target")
                    }
                    Button { detail = pass } label: { Image(systemName: "info.circle").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Details for \(pass.name)")
                }
                #if os(iOS)
                .listRowBackground(RowHighlight(focused: !editMode.isEditing && model.highlightedPass(at: date)?.id == pass.id,
                                                target: model.targetPassID == pass.id))
                #endif
                .swipeActions(edge: .leading) {
                    Button(model.isShown(pass) ? "Hide track" : "Add track", systemImage: model.isShown(pass) ? "eye.slash" : "plus") {
                        model.toggleTrack(pass)
                    }
                    .tint(Theme.accent)
                }
                .contextMenu {
                    Button(model.isShown(pass) ? "Hide track" : "Add track") { model.toggleTrack(pass) }
                    if model.targetPassID == pass.id {
                        Button("Untrack") { Task { await model.untrack() } }
                    } else {
                        Button("Set as tracking target") { model.setTarget(pass: pass) }
                            .disabled(model.mount.isTracking || pass.end.date < model.viewDate())
                    }
                    Button("Details") { detail = pass }
                    Button("Pass calculator…") { model.calculatorObjectID = "sat:\(pass.noradID)" }
                }
            }
            .listStyle(.plain)
            #if os(iOS)
            .environment(\.editMode, $editMode)
            #else
            // Delete takes the focused pass off the sky and globe.
            .onDeleteCommand {
                if let pass = model.highlightedPass(at: model.viewDate()), model.isShown(pass) { model.hideTrack(pass) }
            }
            #endif
            }
            }
            .sheet(item: $detail) { pass in
                NavigationStack {
                    PassDetailView(pass: pass)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { detail = nil } }
                            ToolbarItem(placement: .primaryAction) {
                                Button("Set as tracking target") { model.setTarget(pass: pass); detail = nil }
                                    .disabled(model.mount.isTracking || pass.end.date < model.viewDate())
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
            TimelineView(.periodic(from: Theme.clockAnchor, by: 1)) { context in
                let date = model.viewDate(context.date)
                List(sorted(model.selectedObjects.filter { passesFilters($0, date) }, date)) { object in
                    Button { model.highlight(objectID: object.id) } label: {
                        ObjectPositionRow(object: object, date: date)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(RowHighlight(focused: model.highlightedObject?.id == object.id,
                                                    target: model.targetObjectID == object.id))
                    .contextMenu {
                        if model.targetObjectID == object.id {
                            Button("Untrack") { Task { await model.untrack() } }
                        } else {
                            Button("Set as tracking target") { model.highlight(objectID: object.id); model.setTargetFromHighlight() }
                                .disabled(model.mount.isTracking)
                        }
                        Button("Pass calculator…") { model.calculatorObjectID = object.id }
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
            // Known magnitudes first, then satellites by radar size, then by physical size
            // (largest first), then the rest.
            let keyed = objects.map { o -> (SkyObject, Int, Double) in
                if let m = model.magnitude(o, at: date) { return (o, 0, m) }
                if let rcs = model.radarCrossSection(o) { return (o, 1, -rcs) }
                if let size = model.info(o)?.largestDimension { return (o, 2, -size) }
                return (o, 3, 0)
            }
            return keyed.sorted { ($0.1, $0.2) != ($1.1, $1.2) ? ($0.1, $0.2) < ($1.1, $1.2) : $0.0.name < $1.0.name }.map(\.0)
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
        HStack(spacing: 10) {
            ObjectBadge(object: object)
            VStack(alignment: .leading, spacing: 1) {
                Text(object.name).font(.body.weight(.medium)).lineLimit(1)
                Brightness(object: object, date: date)
            }
            Spacer()
            ObjectStatus(object: object, date: date)
        }
        .padding(.vertical, 2)
    }
}

/// The object's kind as a tinted icon in a circle.
struct ObjectBadge: View {
    let object: SkyObject

    var body: some View {
        let color = Theme.color(of: object)
        Image(systemName: Theme.symbol(of: object))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 28, height: 28)
            .background(color.opacity(0.15), in: Circle())
            .accessibilityHidden(true)
    }
}

/// The focused row in amber (matching the ring on the dome), the tracking target in green.
struct RowHighlight: View {
    let focused: Bool
    let target: Bool

    var body: some View {
        let color: Color? = focused ? Theme.focus : target ? Theme.target : nil
        if let color {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(color.opacity(0.45)))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
        } else {
            Color.clear
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
                                Image(systemName: "moon.fill").foregroundStyle(Theme.eclipsed).accessibilityLabel("Eclipsed")
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
                .foregroundStyle(trend == .rising ? Theme.rising : Theme.setting)
            if let max { Text("· max \(Int(max.rounded()))°").foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int(altitude.rounded())) degrees, \(trend == .rising ? "rising" : "setting")"
                            + (max.map { ", maximum \(Int($0.rounded())) degrees" } ?? ""))
    }
}

/// Apparent magnitude: smaller is brighter. Satellites need a standard magnitude, which TLEs
/// don't include, so for them this says whether they're lit and gives the radar or physical size as a guide.
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
                let lit = (try? s.isSunlit(at: AstroTime(date))) == true
                let info = model.info(object)
                let size = info?.radarCrossSection.map { "RCS \(RadarSize.format($0))" }
                    ?? info.flatMap(SatelliteDimensions.text)
                Text([lit ? "sunlit" : "eclipsed", size].compactMap { $0 }.joined(separator: " · "))
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

/// The shown tracks over the sky or globe: tap one to focus it, × to take it off.
struct TrackLegend: View {
    @Environment(AppModel.self) private var model
    let passes: [SatellitePass]
    let focusID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(passes) { pass in
                HStack(spacing: 6) {
                    Circle().fill(Theme.track(model.trackIndex(pass))).frame(width: 9, height: 9)
                    Button { model.highlight(pass: pass) } label: {
                        HStack(spacing: 4) {
                            Text(pass.name).font(.caption.weight(pass.id == focusID ? .bold : .regular)).lineLimit(1)
                            Text(pass.start.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    Button { model.hideTrack(pass) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hide \(pass.name)")
                    .help("Take this track off")
                }
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(8)
    }
}

/// What the Observe screen's main view shows.
enum SkyView: String, CaseIterable, Identifiable {
    case sky = "Sky", globe = "Globe", map = "Map"
    var id: Self { self }
}
