import SkyKit
import SwiftUI
import UniformTypeIdentifiers

struct SatellitesView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var addingURL = false
    @State private var importing = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.sources) { source in
                        SourceRow(source: source, status: model.sourceStatus[source.id])
                            .swipeActions {
                                if !source.id.hasPrefix("celestrak-") {
                                    Button("Remove", role: .destructive) { Task { await model.removeSource(source.id) } }
                                }
                            }
                    }
                } header: {
                    Text("TLE sources")
                } footer: {
                    Text("Downloaded element sets are kept on this device, so passes still work without a signal. Refreshes are spaced at least 2 hours apart, as CelesTrak asks.")
                }

                Section("\(filtered.count) satellites") {
                    ForEach(filtered.prefix(500), id: \.noradID) { sat in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(sat.name)
                                Text("#\(sat.noradID)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            ElementAge(seconds: sat.elementAge())
                        }
                    }
                }
            }
            .navigationTitle("Satellites")
            .searchable(text: $search, prompt: "Name or catalogue number")
            .refreshable { await model.refreshDue() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Refresh due sources") { Task { await model.refreshDue() } }
                        Button("Add a URL…") { addingURL = true }
                        Button("Import a TLE file…") { importing = true }
                    } label: {
                        Label("Add", systemImage: model.isRefreshing ? "arrow.triangle.2.circlepath" : "plus")
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
        }
    }

    var filtered: [SatelliteTarget] {
        search.isEmpty ? model.satellites
            : model.satellites.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.noradID == search }
    }
}

struct SourceRow: View {
    @Environment(AppModel.self) private var model
    let source: TLESource
    let status: TLESourceStatus?

    var body: some View {
        Toggle(isOn: Binding(get: { source.enabled }, set: { on in Task { await model.setEnabled(source.id, on) } })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                Group {
                    if let error = status?.lastError {
                        Text(error).foregroundStyle(.red)
                    } else if let when = status?.lastRefreshed {
                        Text("\(status?.satelliteCount ?? 0) satellites · updated \(when, style: .relative) ago")
                    } else {
                        Text("Not downloaded yet")
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .contextMenu {
            Button("Refresh now") { Task { await model.refresh(source.id) } }
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
