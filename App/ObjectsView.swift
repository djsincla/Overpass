import SkyKit
import SwiftUI
import UniformTypeIdentifiers

/// Everything you can select: the Sun, Moon and planets, bright stars, and satellites by source.
/// What's selected here is what gets predicted, highlighted and offered for tracking.
///
/// A sidebar of pages (the selection, the solar system, the stars, each satellite source) with
/// the chosen page on the right. Turning sources on and off lives in Manage sources.
struct ObjectsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var selectedOnly = false
    @State private var maxAgeDays: Double = 0
    /// Each source's column sort, saved between launches.
    @AppStorage("objects.columnSorts") private var savedSorts = Data()
    @AppStorage("objects.page") private var savedPage = Page.selected.rawValue
    @State private var page: Page?
    @State private var listWidth: CGFloat = 900
    @State private var addingURL = false
    @State private var importing = false
    @State private var managingSources = false
    @State private var confirmingSun = false
    /// Unticked while "Selected only" is on: kept visible so a mis-tap can be undone.
    @State private var recentlyUnselected: Set<String> = []

    /// A sidebar entry.
    enum Page: Hashable {
        case selected, solarSystem, stars
        case source(String)

        var rawValue: String {
            switch self {
            case .selected: "selected"
            case .solarSystem: "solar"
            case .stars: "stars"
            case .source(let id): "source:" + id
            }
        }

        init(rawValue: String) {
            switch rawValue {
            case "solar": self = .solarSystem
            case "stars": self = .stars
            case let s where s.hasPrefix("source:"): self = .source(String(s.dropFirst(7)))
            default: self = .selected
            }
        }
    }

    var body: some View {
        columns
        #if os(macOS)
        .searchable(text: $search, placement: .toolbar, prompt: "Name, number, launched>2020…")
        #else
        .searchable(text: $search, placement: .sidebar, prompt: "Name, number, launched>2020…")
        #endif
        .onAppear { if page == nil { page = Page(rawValue: savedPage) } }
        .onChange(of: page) { _, new in
            if let new { savedPage = new.rawValue }
            recentlyUnselected = []
        }
        .sheet(isPresented: $managingSources) { ManageSourcesSheet(addingURL: $addingURL, importing: $importing) }
        .sheet(isPresented: $addingURL) { AddSourceSheet() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text, .data]) { result in
            if case .success(let url) = result { Task { await model.importFile(url) } }
        }
        .alert("Overpass", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
        .alert("Select the Sun?", isPresented: $confirmingSun) {
            Button("I'll use a solar filter") { model.toggle(SkyObject.body(.sun).id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only point a telescope or camera at the Sun with a proper full-aperture solar filter fitted.")
        }
    }

    /// On the Mac, the sidebar and list side by side under the window's one toolbar: a split
    /// view gives each column its own toolbar section and centred the tab switcher over the
    /// list instead of the window, so it moved when this tab came up.
    @ViewBuilder
    private var columns: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            sidebar
                .listStyle(.sidebar)
                .frame(width: 230)
            Divider()
            NavigationStack {
                detail
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listWidth = $0 }
            }
        }
        #else
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            NavigationStack {
                detail
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listWidth = $0 }
            }
        }
        #endif
    }

    /// A sidebar row that picks `page`: on the Mac, where there is no split view to navigate, a
    /// button that sets it and shows it chosen; a navigation link elsewhere.
    @ViewBuilder
    private func pageRow<Label: View>(_ page: Page, @ViewBuilder label: () -> Label) -> some View {
        #if os(macOS)
        Button { self.page = page } label: {
            label().frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6)
                .fill(self.page == page ? Color.accentColor.opacity(0.28) : .clear)
                .padding(.horizontal, 8))
        #else
        NavigationLink(value: page, label: label)
        #endif
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $page) {
            Section {
                pageRow(Page.selected) {
                    Label("Selected", systemImage: "checkmark.circle").badge(model.selected.count)
                }
                pageRow(Page.solarSystem) {
                    Label("Solar system", systemImage: "sun.max")
                        .badge(SolarSystemBody.allCases.filter { model.isSelected(SkyObject.body($0).id) }.count)
                }
                pageRow(Page.stars) {
                    Label("Bright stars", systemImage: "sparkles")
                        .badge(BrightStars.all.filter { model.isSelected(SkyObject.star($0).id) }.count)
                }
            }
            Section("Satellites") {
                ForEach(model.groups.filter { $0.source.enabled }) { group in
                    pageRow(Page.source(group.id)) {
                        Label {
                            Text(group.source.name)
                        } icon: {
                            Image(systemName: group.status?.lastError != nil ? "exclamationmark.triangle" : "antenna.radiowaves.left.and.right")
                                .foregroundStyle(group.status?.lastError != nil ? .orange : Color.accentColor)
                        }
                        .badge(group.satellites.count)
                    }
                    .contextMenu {
                        Button("Refresh now") { Task { await model.refresh(group.id) } }
                        Button("Turn off") { Task { await model.setEnabled(group.id, false) } }
                    }
                }
                Button { managingSources = true } label: {
                    Label("Manage sources…", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.borderless)
            }
        }
        .navigationTitle("Objects")
        .refreshable { await model.refreshDue() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Manage sources…") { managingSources = true }
                    Button("Refresh all sources") { Task { await model.refreshAll() } }
                    Button("Add a TLE URL…") { addingURL = true }
                    Button("Import a TLE file…") { importing = true }
                    Divider()
                    Button("Deselect satellites that never rise here") { Task { await model.deselectNeverRising() } }
                        .disabled(model.isPruning)
                    Button("Clear selection", role: .destructive) { model.selected = [] }
                } label: {
                    Label("More", systemImage: model.isRefreshing ? "arrow.triangle.2.circlepath" : "ellipsis.circle")
                }
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if !search.isEmpty {
            searchResults
        } else {
            switch page ?? .selected {
            case .selected: selectedPage
            case .solarSystem: bodiesPage
            case .stars: starsPage
            case .source(let id):
                if let group = model.groups.first(where: { $0.id == id && $0.source.enabled }) {
                    sourcePage(group)
                } else {
                    ContentUnavailableView("Source turned off", systemImage: "antenna.radiowaves.left.and.right.slash",
                                           description: Text("Turn it on again in Manage sources."))
                }
            }
        }
    }

    private var selectedPage: some View {
        let bodies = SolarSystemBody.allCases.map(SkyObject.body).filter { model.isSelected($0.id) || recentlyUnselected.contains($0.id) }
        let stars = BrightStars.all.map(SkyObject.star).filter { model.isSelected($0.id) || recentlyUnselected.contains($0.id) }
        let sats = model.satellites.filter { model.isSelected("sat:\($0.noradID)") || recentlyUnselected.contains("sat:\($0.noradID)") }
        return List {
            if model.selected.isEmpty && recentlyUnselected.isEmpty {
                ContentUnavailableView("Nothing selected", systemImage: "checkmark.circle",
                                       description: Text("Pick satellites from a source, or the Sun, Moon and planets. Passes are predicted for what's selected, and it's marked on the sky."))
            }
            if !bodies.isEmpty || !stars.isEmpty {
                Section("Sky") {
                    ForEach(bodies + stars, id: \.id) { selectRow($0) }
                }
            }
            if !sats.isEmpty {
                satelliteSection(sats, sortID: "selected") {
                    Text("Satellites")
                }
            }
        }
        .navigationTitle("Selected")
        .toolbar { detailToolbar(showsSelectedOnly: false) }
    }

    private var bodiesPage: some View {
        List {
            Section {
                ForEach(SolarSystemBody.allCases, id: \.self) { body in
                    let object = SkyObject.body(body)
                    if visible(object) { selectRow(object) }
                }
            } footer: {
                Text("Selected bodies are marked on the sky and can be tracked.")
            }
        }
        .navigationTitle("Solar system")
        .toolbar { detailToolbar(showsAge: false) }
    }

    private var starsPage: some View {
        List {
            ForEach(BrightStars.all, id: \.name) { star in
                let object = SkyObject.star(star)
                if visible(object) { selectRow(object, detail: String(format: "mag %.1f", star.magnitude)) }
            }
        }
        .navigationTitle("Bright stars")
        .toolbar { detailToolbar(showsAge: false) }
    }

    private func sourcePage(_ group: SourceGroup) -> some View {
        let shown = group.satellites.filter { visible(.satellite($0)) }
        return List {
            Section {
                SourceHeader(group: group, shown: shown, filtered: shown.count < group.satellites.count,
                             clearFilters: clearFilters)
            }
            satelliteSection(shown, sortID: group.id) { EmptyView() }
        }
        .navigationTitle(group.source.name)
        .toolbar { detailToolbar() }
    }

    /// Everything that matches, from every page at once.
    private var searchResults: some View {
        let sky = (SolarSystemBody.allCases.map(SkyObject.body) + BrightStars.all.map(SkyObject.star)).filter(visible)
        let sats = model.satellites.filter { visible(.satellite($0)) }
        return List {
            if sky.isEmpty && sats.isEmpty {
                ContentUnavailableView.search(text: search)
            }
            if !sky.isEmpty {
                Section("Sky") { ForEach(sky, id: \.id) { selectRow($0) } }
            }
            if !sats.isEmpty {
                satelliteSection(sats, sortID: "search") { Text("Satellites · \(sats.count)") }
            }
        }
        .navigationTitle("Search")
        .toolbar { detailToolbar() }
    }

    /// A sortable table of satellites, lined up in columns that fit the width.
    private func satelliteSection<Header: View>(_ satellites: [SatelliteTarget], sortID: String,
                                                @ViewBuilder header: () -> Header) -> some View {
        let sort = sortBinding(sortID)
        let sorted = sort.wrappedValue.sorted(satellites) { model.info(.satellite($0)) }
        let columns = SatelliteColumn.fitting(listWidth)
        let limit = search.isEmpty ? 500 : 2000
        return Section {
            SatelliteColumnHeader(columns: columns, sort: sort)
            ForEach(sorted.prefix(limit), id: \.noradID) { sat in
                satelliteRow(sat, columns: columns)
            }
            if sorted.count > limit {
                Text("\(sorted.count - limit) more; search to narrow down").font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            header()
        }
    }

    @ToolbarContentBuilder
    private func detailToolbar(showsSelectedOnly: Bool = true, showsAge: Bool = true) -> some ToolbarContent {
        // Primary, not secondary: on a Mac secondary items sit beside the tab switcher and push it off centre.
        ToolbarItemGroup(placement: .primaryAction) {
            if showsSelectedOnly {
                Toggle(isOn: $selectedOnly) { Label("Selected only", systemImage: "checkmark.circle") }
                    .onChange(of: selectedOnly) { _, _ in recentlyUnselected = [] }
                    .help("Show only what's selected")
            }
            if showsAge {
                Picker(selection: $maxAgeDays) {
                    Text("Any TLE age").tag(0.0)
                    Text("TLE under 1 day").tag(1.0)
                    Text("TLE under 3 days").tag(3.0)
                    Text("TLE under 7 days").tag(7.0)
                } label: {
                    Label("TLE age", systemImage: "clock")
                }
                .help("Hide satellites whose elements are older than this")
            }
        }
    }

    private func satelliteRow(_ sat: SatelliteTarget, columns: [SatelliteColumn]) -> some View {
        let object = SkyObject.satellite(sat)
        let on = model.isSelected(object.id)
        return Button {
            if on { recentlyUnselected.insert(object.id) }
            model.toggle(object.id)
        } label: {
            SatelliteColumnRow(satellite: sat, info: model.info(object), columns: columns, selected: on)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func selectRow(_ object: SkyObject, detail: String? = nil) -> some View {
        let on = model.isSelected(object.id)
        return Button {
            if on { recentlyUnselected.insert(object.id) }
            if object.isSun && !on { confirmingSun = true } else { model.toggle(object.id) }
        } label: {
            HStack {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(object.name)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Filtering

    private func sortBinding(_ groupID: String) -> Binding<ColumnSort> {
        Binding {
            let sorts = (try? JSONDecoder().decode([String: ColumnSort].self, from: savedSorts)) ?? [:]
            return sorts[groupID] ?? ColumnSort()
        } set: { sort in
            var sorts = (try? JSONDecoder().decode([String: ColumnSort].self, from: savedSorts)) ?? [:]
            sorts[groupID] = sort
            savedSorts = (try? JSONEncoder().encode(sorts)) ?? savedSorts
        }
    }

    private func clearFilters() {
        selectedOnly = false
        maxAgeDays = 0
        search = ""
    }

    private func visible(_ object: SkyObject) -> Bool {
        if selectedOnly && !model.isSelected(object.id) && !recentlyUnselected.contains(object.id) { return false }
        if !search.isEmpty {
            let query = SatelliteQuery(search)
            if case .satellite(let s) = object {
                if !query.matches(name: s.name, noradID: s.noradID, info: model.info(object)) { return false }
            } else {
                // Only satellites have attributes to compare.
                if query.comparesAttributes { return false }
                let words = search.split(whereSeparator: \.isWhitespace)
                if !words.allSatisfy({ object.name.localizedCaseInsensitiveContains($0) }) { return false }
            }
        }
        if maxAgeDays > 0, case .satellite(let s) = object, s.elementAge() > maxAgeDays * 86_400 { return false }
        return true
    }
}

/// Every TLE source with its switch, plus adding one by URL or file.
struct ManageSourcesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var addingURL: Bool
    @Binding var importing: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(model.groups) { group in SourceRow(group: group) }
                } footer: {
                    Text("A source that's on appears in the sidebar with its satellites. Turning one off keeps it here, so you can turn it back on.")
                }
                Section {
                    Button("Add a TLE URL…") { dismiss(); addingURL = true }
                    Button("Import a TLE file…") { dismiss(); importing = true }
                } footer: {
                    Text("Search matches names, numbers, owners and launch dates, and compares attributes: launched>2020, period<100, perigee>500, inc>50, rcs>10, span>20, size=large, owner=PRC, type=debris.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("TLE sources")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .frame(minWidth: 460, minHeight: 520)
    }
}

/// One source: an on/off switch that is always visible, its status, and refresh.
struct SourceRow: View {
    @Environment(AppModel.self) private var model
    let group: SourceGroup

    var body: some View {
        HStack {
            Toggle(isOn: Binding(get: { group.source.enabled },
                                 set: { on in Task { await model.setEnabled(group.id, on) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.source.name)
                    Group {
                        if let error = group.status?.lastError {
                            Text(error).foregroundStyle(.red)
                        } else if !group.source.enabled {
                            Text("Off")
                        } else if let when = group.status?.lastRefreshed {
                            let age = group.medianAge.map { String(format: " · median TLE %.1f d", $0 / 86_400) } ?? ""
                            Text("\(group.satellites.count) satellites · updated \(when, style: .relative) ago\(age)")
                        } else {
                            Text("Downloading…")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if group.source.enabled {
                Button { Task { await model.refresh(group.id) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Refresh \(group.source.name)")
            }
        }
        .contextMenu {
            Button("Refresh now") { Task { await model.refresh(group.id) } }
            if !group.id.hasPrefix("celestrak-") {
                Button("Remove", role: .destructive) { Task { await model.removeSource(group.id) } }
            }
        }
    }
}

struct SourceHeader: View {
    @Environment(AppModel.self) private var model
    let group: SourceGroup
    /// The source's satellites that pass the filters (search, selected only, TLE age).
    let shown: [SatelliteTarget]
    let filtered: Bool
    let clearFilters: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.source.name)
                Group {
                    if let error = group.status?.lastError {
                        Text(error).foregroundStyle(.red)
                    } else if let when = group.status?.lastRefreshed {
                        let age = group.medianAge.map { String(format: " · median TLE %.1f d", $0 / 86_400) } ?? ""
                        let selectedCount = group.satellites.filter { model.isSelected("sat:\($0.noradID)") }.count
                        Text("\(selectedCount) of \(group.satellites.count) selected · updated \(when, style: .relative) ago\(age)")
                        if filtered {
                            Text("Showing \(shown.count): the rest are hidden by the filters above")
                                .foregroundStyle(Theme.setting)
                        }
                    } else {
                        Text("Not downloaded yet")
                    }
                }
                .font(.caption2).textCase(nil).lineLimit(2)
            }
            Spacer()
            Menu {
                Button(filtered ? "Select the \(shown.count) shown" : "Select all \(shown.count)") { select(shown, true) }
                Button(filtered ? "Deselect the \(shown.count) shown" : "Deselect all") { select(shown, false) }
                Button("Deselect ones that never rise here") { Task { await model.deselectNeverRising(in: group) } }
                    .disabled(model.isPruning)
                if filtered {
                    Divider()
                    Button("Show all \(group.satellites.count)") { clearFilters() }
                }
            } label: {
                Image(systemName: "checklist")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Select satellites in \(group.source.name)")
            Button { Task { await model.refresh(group.id) } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("Refresh \(group.source.name)")
        }
    }
}

extension SourceHeader {
    /// One assignment, so the change triggers a single prediction run.
    private func select(_ satellites: [SatelliteTarget], _ on: Bool) {
        let ids = satellites.map { "sat:\($0.noradID)" }
        var selection = model.selected
        if on { selection.formUnion(ids) } else { selection.subtract(ids) }
        model.selected = selection
    }
}

/// Radar cross-section, as published: "399 m²", "28 m²", "0.12 m²".
enum RadarSize {
    static func format(_ squareMetres: Double) -> String {
        let digits = squareMetres >= 10 ? 0 : squareMetres >= 1 ? 1 : 2
        return "\(squareMetres.formatted(.number.precision(.fractionLength(digits)))) m²"
    }
}

enum SatelliteDimensions {
    /// "12.6 × 4.2 m, span 23.9 m"; the span only when it's wider than the body.
    static func text(_ info: SatelliteInfo, units: Units) -> String? {
        let body = [info.length, info.diameter].compactMap { $0 }
        guard !body.isEmpty || info.span != nil else { return nil }
        let unit = units.lengthUnit
        var text = body.map(units.lengthNumber).joined(separator: " × ")
        if let span = info.span, span > (body.max() ?? 0) {
            text += text.isEmpty ? "span \(units.length(span))" : " \(unit), span \(units.length(span))"
        } else if !text.isEmpty {
            text += " \(unit)"
        }
        return text
    }
}

/// Element sets go stale: LEO predictions drift noticeably after 2–3 days.
struct ElementAge: View {
    let seconds: TimeInterval

    var body: some View {
        let days = seconds / 86_400
        Text(days < 1 ? "\(Int(days * 24)) h" : String(format: "%.1f d", days))
            .font(.caption.monospacedDigit())
            .foregroundStyle(days > 3 ? .orange : .secondary)
            .accessibilityLabel("Elements \(String(format: "%.1f", days)) days old")
    }
}

struct AddSourceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var urlText = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("URL", text: $urlText)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                Text("Any address that serves two- or three-line element sets, for example a CelesTrak GP query with FORMAT=tle.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .navigationTitle("Add a TLE source")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)) {
                            Task { await model.addSource(name: name.isEmpty ? url.host() ?? "Custom" : name, url: url) }
                        }
                        dismiss()
                    }
                    .disabled(URL(string: urlText)?.scheme?.hasPrefix("http") != true)
                }
            }
        }
    }
}
