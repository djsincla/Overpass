import SkyKit
import SwiftUI
import UniformTypeIdentifiers

/// Everything you can select: the Sun, Moon and planets, bright stars, and satellites by source.
/// What's selected here is what gets predicted, highlighted and offered for tracking.
struct ObjectsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var selectedOnly = false
    @State private var maxAgeDays: Double = 0
    @State private var addingURL = false
    @State private var importing = false
    @State private var confirmingSun = false
    @State private var expanded: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Selected only", isOn: $selectedOnly)
                    Picker("TLE age", selection: $maxAgeDays) {
                        Text("Any").tag(0.0)
                        Text("Under 1 day").tag(1.0)
                        Text("Under 3 days").tag(3.0)
                        Text("Under 7 days").tag(7.0)
                    }
                } footer: {
                    Text("\(model.selected.count) selected. Passes are predicted for selected satellites; selected objects are marked on the sky.")
                }

                Section("Solar system") {
                    ForEach(SolarSystemBody.allCases, id: \.self) { body in
                        let object = SkyObject.body(body)
                        if visible(object) { selectRow(object) }
                    }
                }

                Section(isExpanded: binding("stars")) {
                    ForEach(BrightStars.all, id: \.name) { star in
                        let object = SkyObject.star(star)
                        if visible(object) {
                            selectRow(object, detail: String(format: "mag %.1f", star.magnitude))
                        }
                    }
                } header: {
                    Text("Bright stars")
                }

                ForEach(model.groups.filter { $0.source.enabled }) { group in
                    sourceSection(group)
                }

                Section("More sources") {
                    ForEach(model.groups.filter { !$0.source.enabled }) { group in
                        Toggle(group.source.name, isOn: Binding(get: { false },
                                                                set: { on in Task { await model.setEnabled(group.id, on) } }))
                    }
                }
            }
            .navigationTitle("Objects")
            .searchable(text: $search, prompt: "Name or catalogue number")
            .refreshable { await model.refreshDue() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Refresh all sources") { Task { await model.refreshAll() } }
                        Button("Add a TLE URL…") { addingURL = true }
                        Button("Import a TLE file…") { importing = true }
                        Divider()
                        Button("Clear selection", role: .destructive) { model.selected = [] }
                    } label: {
                        Label("More", systemImage: model.isRefreshing ? "arrow.triangle.2.circlepath" : "ellipsis.circle")
                    }
                }
            }
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
    }

    // MARK: Sections

    private func sourceSection(_ group: SourceGroup) -> some View {
        let shown = group.satellites.filter { visible(.satellite($0)) }
        let limit = search.isEmpty ? 300 : 2000
        return Section(isExpanded: binding(group.id)) {
            ForEach(shown.prefix(limit), id: \.noradID) { sat in
                selectRow(.satellite(sat), detail: "#\(sat.noradID)", age: sat.elementAge())
            }
            if shown.count > limit {
                Text("\(shown.count - limit) more; search to narrow down").font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            SourceHeader(group: group, shown: shown.count)
        }
    }

    private func selectRow(_ object: SkyObject, detail: String? = nil, age: TimeInterval? = nil) -> some View {
        let on = model.isSelected(object.id)
        return Button {
            if object.isSun && !on { confirmingSun = true } else { model.toggle(object.id) }
        } label: {
            HStack {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? Color.accentColor : .secondary)
                VStack(alignment: .leading) {
                    Text(object.name)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if let age { ElementAge(seconds: age) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Filtering

    private func visible(_ object: SkyObject) -> Bool {
        if selectedOnly && !model.isSelected(object.id) { return false }
        if !search.isEmpty {
            let matchesName = object.name.localizedCaseInsensitiveContains(search)
            let matchesID: Bool = if case .satellite(let s) = object { s.noradID == search } else { false }
            if !matchesName && !matchesID { return false }
        }
        if maxAgeDays > 0, case .satellite(let s) = object, s.elementAge() > maxAgeDays * 86_400 { return false }
        return true
    }

    /// Sections start collapsed except the first source, so a 10,000-satellite group doesn't swamp the list.
    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) || !search.isEmpty || selectedOnly || (id != "stars" && model.groups.first?.id == id) },
                set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }
}

struct SourceHeader: View {
    @Environment(AppModel.self) private var model
    let group: SourceGroup
    let shown: Int

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.source.name)
                Group {
                    if let error = group.status?.lastError {
                        Text(error).foregroundStyle(.red)
                    } else if let when = group.status?.lastRefreshed {
                        let age = group.medianAge.map { String(format: " · median TLE %.1f d", $0 / 86_400) } ?? ""
                        Text("\(shown) of \(group.satellites.count) · updated \(when, style: .relative) ago\(age)")
                    } else {
                        Text("Not downloaded yet")
                    }
                }
                .font(.caption2).textCase(nil).lineLimit(2)
            }
            Spacer()
            Button { Task { await model.refresh(group.id) } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("Refresh \(group.source.name)")
            Menu {
                Button("Turn off") { Task { await model.setEnabled(group.id, false) } }
                if !group.id.hasPrefix("celestrak-") {
                    Button("Remove", role: .destructive) { Task { await model.removeSource(group.id) } }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("\(group.source.name) options")
        }
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
