import SkyKit
import SwiftUI

/// The one screen for observing: the sky, what's coming up, and the mount.
struct ObserveView: View {
    @Environment(AppModel.self) private var model
    @State private var panel = Panel.passes
    @State private var showingFilters = false

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
                            HStack(alignment: .top, spacing: 0) {
                                dome.padding().frame(width: min(proxy.size.width * 0.5, proxy.size.height))
                                Divider()
                                VStack(spacing: 0) {
                                    Picker("List", selection: listBinding) {
                                        Text("Passes").tag(Panel.passes)
                                        Text("Objects").tag(Panel.objects)
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                    .padding(8)
                                    list(listBinding.wrappedValue)
                                    Divider()
                                    ScrollView { MountPanel().padding() }
                                        .frame(maxHeight: proxy.size.height * 0.55)
                                }
                            }
                        } else {
                            VStack(spacing: 0) {
                                dome.padding(.horizontal).frame(maxHeight: proxy.size.height * 0.45)
                                Picker("Panel", selection: $panel) {
                                    ForEach(Panel.allCases) { Text($0.rawValue).tag($0) }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .padding(8)
                                if panel == .mount {
                                    ScrollView { MountPanel().padding() }
                                } else {
                                    list(panel)
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
        switch panel {
        case .objects: SelectedObjectsList()
        default: PassesList()
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

/// Selected non-satellite objects (and satellites), with where they are now.
struct SelectedObjectsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.selectedObjects.isEmpty {
            ContentUnavailableView("Nothing selected", systemImage: "checklist",
                                   description: Text("Choose the Moon, planets, stars or satellites in the Objects tab."))
        } else {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                List(model.selectedObjects) { object in
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

struct ObjectPositionRow: View {
    @Environment(AppModel.self) private var model
    let object: SkyObject
    let date: Date

    var body: some View {
        let h = try? model.settings.observer.look(at: object.target, AstroTime(date))
        HStack {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(.secondary)
            Text(object.name)
            Spacer()
            if let h {
                if h.altitude > 0 {
                    Text("\(Int(h.azimuth))° \(compass(h.azimuth)) · \(Int(h.altitude.rounded()))° up")
                        .font(.callout.monospacedDigit())
                } else {
                    Text("Below the horizon").font(.callout).foregroundStyle(.secondary)
                }
            }
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
