import MapKit
import SkyKit
import SwiftUI

/// Space station transits of the Moon and Sun around a place, on a map.
struct ConjunctionsView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedID: String?
    @AppStorage("conjunctions.listFraction") private var listFraction = 0.38

    var body: some View {
        let c = model.conjunctions
        NavigationStack {
            GeometryReader { proxy in
                if proxy.size.width > 760 {
                    ResizableSplit(axis: .horizontal, fraction: $listFraction, range: 0.25...0.6) {
                        EventList(selectedID: $selectedID)
                    } second: {
                        ConjunctionMap(event: selected, previous: selectedWatch?.previous)
                            .overlay(alignment: .bottom) {
                                if let event = selected {
                                    EventDetail(event: event, watch: selectedWatch).padding(12)
                                }
                            }
                    }
                } else {
                    EventList(selectedID: $selectedID, pushesDetail: true)
                }
            }
            .navigationTitle("Conjunctions")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await c.updateWatched(force: true) } } label: {
                        Label("Refresh TLE now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .help("Download fresh space station elements and recalculate the watched events")
                    .disabled(c.isUpdating || c.watched.isEmpty)
                }
                // With the other buttons: on a Mac, .status sits beside the tab switcher and pushes it off centre.
                if c.isSearching || c.isUpdating {
                    ToolbarItem(placement: .primaryAction) { ProgressView().controlSize(.small) }
                }
            }
            .task(id: c.settings) {
                // Re-run whenever what or where changes (it takes about a second).
                try? await Task.sleep(for: .milliseconds(300))
                await c.search()
            }
            .onChange(of: model.satellites.count) { _, _ in
                // The catalog loads after launch, and again after each refresh.
                Task { await c.search() }
            }
            .alert("Conjunctions", isPresented: Binding(get: { c.message != nil }, set: { if !$0 { c.message = nil } })) {
                Button("OK") { c.message = nil }
            } message: {
                Text(c.message ?? "")
            }
        }
    }

    private var selectedWatch: WatchedConjunction? {
        model.conjunctions.watched.first { $0.id == selectedID || $0.event.id == selectedID }
    }

    private var selected: Conjunction? {
        selectedWatch?.event ?? model.conjunctions.results.first { $0.id == selectedID }
    }
}

// MARK: - Controls and list

struct EventList: View {
    @Environment(AppModel.self) private var model
    @Binding var selectedID: String?
    var pushesDetail = false

    var body: some View {
        let c = model.conjunctions
        List(selection: pushesDetail ? .constant(nil) : $selectedID) {
            Section { SearchControls() }

            if !c.watched.isEmpty {
                Section("Watching") {
                    ForEach(c.watched) { w in
                        row(w.event, watch: w).tag(w.id)
                    }
                }
            }

            ForEach(days, id: \.day) { group in
                Section {
                    ForEach(group.events) { event in row(event, watch: nil).tag(event.id) }
                } header: {
                    Text(group.day, format: .dateTime.weekday(.wide).month().day())
                }
            }

            if c.results.isEmpty && !c.isSearching && c.lastSearch != nil {
                Section {
                    Text("No transits within \(Int(c.settings.radius)) km of \(c.centreName) in the next \(Int(c.settings.daysAhead)) days. Try a wider range or more days.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func row(_ event: Conjunction, watch: WatchedConjunction?) -> some View {
        if pushesDetail {
            NavigationLink {
                ConjunctionMap(event: event, previous: watch?.previous)
                    .frame(minHeight: 320)
                    .safeAreaInset(edge: .bottom) { EventDetail(event: event, watch: watch).padding(12) }
                    .navigationTitle("\(Self.short(event.satelliteName)) × \(event.body.name)")
            } label: { EventRow(event: event, watch: watch) }
        } else {
            EventRow(event: event, watch: watch)
        }
    }

    private var days: [(day: Date, events: [Conjunction])] {
        let c = model.conjunctions
        let shown = c.results.filter { !c.isWatched($0) }
        let grouped = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.closest) }
        return grouped.keys.sorted().map { ($0, grouped[$0]!) }
    }

    static func short(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("ISS") { return "ISS" }
        if trimmed.contains("TIANHE") { return "Tiangong" }
        return trimmed
    }
}

/// Where, how far, which bodies, how long ahead.
struct SearchControls: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var editingPlace = false

    var body: some View {
        @Bindable var c = model.conjunctions
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: c.settings.place == nil ? "house.fill" : "mappin.circle.fill")
                    .foregroundStyle(Theme.accent)
                Text(c.centreName).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                Menu {
                    Button("Home (from Settings)") { c.settings.place = nil }
                    Button("Search for a place…") { editingPlace = true }
                } label: {
                    Text("Change")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if editingPlace {
                HStack {
                    TextField("Town, address or landmark", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(lookUp)
                    Button("Find", action: lookUp).disabled(query.isEmpty)
                }
            }
            HStack {
                Picker("Range", selection: $c.settings.radius) {
                    ForEach([10.0, 25, 50, 100, 200], id: \.self) { Text("within \(Int($0)) km").tag($0) }
                }
                .labelsHidden().fixedSize()
                Picker("Days", selection: $c.settings.daysAhead) {
                    ForEach([1.0, 3, 7, 14], id: \.self) { Text($0 == 1 ? "1 day" : "\(Int($0)) days").tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            HStack(spacing: 14) {
                Toggle(isOn: $c.settings.moon) { Label("Moon", systemImage: "moon.fill") }
                Toggle(isOn: $c.settings.sun) { Label("Sun", systemImage: "sun.max.fill") }
                Picker("Height", selection: $c.settings.minimumAltitude) {
                    ForEach([0.0, 10, 20, 30], id: \.self) { Text("≥ \(Int($0))° up").tag($0) }
                }
                .labelsHidden().fixedSize()
                .help("How high the Moon or Sun must be")
            }
            .toggleStyle(.button)
            SatelliteChooser()
            Toggle("Also my selected satellites", isOn: $c.settings.includeSelected)
                .font(.caption)
            Text(summary).font(.caption).foregroundStyle(.secondary)
            if c.stationsMissing {
                Label("Turn on the Space stations source in Objects to get the ISS and Tiangong elements.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Theme.setting)
            }
        }
        .padding(.vertical, 4)
    }

    private func lookUp() {
        let text = query
        Task {
            await model.conjunctions.setPlace(named: text)
            editingPlace = false
            query = ""
        }
    }

    private var summary: String {
        let c = model.conjunctions
        if c.isSearching { return "Searching…" }
        let names = c.satellites.map { EventList.short($0.name) }.joined(separator: ", ")
        let ages = c.satellites.map { Date.now.timeIntervalSince($0.epoch) }
        let age = ages.max().map { " · elements up to \(countdown($0)) old" } ?? ""
        return "\(c.results.count) in \(Int(c.settings.daysAhead)) days · \(names)\(age)"
    }
}

struct EventRow: View {
    @Environment(AppModel.self) private var model
    let event: Conjunction
    let watch: WatchedConjunction?

    var body: some View {
        let c = model.conjunctions
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.body == .sun ? "sun.max.fill" : "moon.fill")
                .foregroundStyle(ConjunctionMap.color(event.body))
                .frame(width: 26, height: 26)
                .background(ConjunctionMap.color(event.body).opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(event.closest, format: .dateTime.weekday(.abbreviated).hour().minute().second())
                        .font(.headline.monospacedDigit())
                    Spacer()
                    Button {
                        if let watch { c.unwatch(watch.id) } else { c.watch(event) }
                    } label: {
                        Image(systemName: c.isWatched(event) ? "star.fill" : "star")
                            .foregroundStyle(c.isWatched(event) ? Theme.focus : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(c.isWatched(event) ? "Stop watching" : "Watch: refresh the elements and recalculate as it gets closer")
                    .accessibilityLabel(c.isWatched(event) ? "Stop watching" : "Watch")
                }
                Text("\(EventList.short(event.satelliteName)) × \(event.body.name) · \(distanceText) · \(String(format: "%.1f km wide · %.1f s", event.width, event.duration))")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 5) {
                    Text("\(event.body.name) \(Int(event.bodyAltitude.rounded()))° up" + (event.illumination.map { " · \(Int(($0 * 100).rounded()))% lit" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                    if event.visibleFromCentre { Chip(text: "From \(c.centreName.components(separatedBy: ",")[0])", systemImage: "checkmark", tint: Theme.rising) }
                    if let drift = watch?.drift { Chip(text: String(format: "moved %+.1f s", drift.seconds), tint: Theme.sunlit) }
                    if watch?.missesArea == true { Chip(text: "now misses", systemImage: "exclamationmark.triangle", tint: Theme.setting) }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var distanceText: String {
        event.distance < 0.5 ? "over you" : String(format: "%.0f km %@", event.distance, compass(event.bearing))
    }
}

// MARK: - Detail

struct EventDetail: View {
    @Environment(AppModel.self) private var model
    let event: Conjunction
    let watch: WatchedConjunction?

    var body: some View {
        let c = model.conjunctions
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(EventList.short(event.satelliteName)) × \(event.body.name)").font(.headline)
                Spacer()
                Text(event.closest, format: .dateTime.month().day().hour().minute().second())
                    .font(.headline.monospacedDigit())
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow {
                    fact("Nearest line", String(format: "%.1f km %@ of %@", event.distance, compass(event.bearing), c.centreName.components(separatedBy: ",")[0]))
                    fact("Band", String(format: "%.1f km wide · %.2f s", event.width, event.duration))
                }
                GridRow {
                    fact("Look", "\(event.body.name) \(Int(event.bodyAltitude.rounded()))° up, \(compass(event.bodyAzimuth))")
                    fact("Station", String(format: "%.0f km away", event.satelliteRange))
                }
                GridRow {
                    fact("Elements", "\(countdown(Date.now.timeIntervalSince(event.elementEpoch))) old")
                    if let drift = watch?.drift, let previous = watch?.previous {
                        fact("Last update", String(format: "%+.1f s, %.1f km %@ since elements of %@", drift.seconds, drift.distance,
                                                   compass(drift.bearing), previous.elementEpoch.formatted(date: .omitted, time: .shortened)))
                    } else {
                        fact("Timing", "refresh near the event: element errors shift it by seconds")
                    }
                }
            }
            if event.body == .sun {
                Label("Only with a proper full-aperture solar filter on the scope and finder.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.scope)
            }
            HStack {
                Button {
                    let item = MKMapItem(placemark: MKPlacemark(coordinate: event.closestPoint.coordinate))
                    item.name = "\(EventList.short(event.satelliteName)) × \(event.body.name) \(event.closest.formatted(date: .omitted, time: .standard))"
                    item.openInMaps()
                } label: { Label("Open in Maps", systemImage: "map") }
                Spacer()
                if let watch {
                    Button("Stop watching") { c.unwatch(watch.id) }
                } else {
                    Button { c.watch(event) } label: { Label("Watch", systemImage: "star") }
                        .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.small)
        }
        .font(.callout)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: 560)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit()).lineLimit(2)
        }
    }
}

// MARK: - Map

extension Geodetic {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// The transit band on an Apple map. This is the one map left on MapKit, deliberately: the band
/// is a few kilometres wide and the transit lasts under a second at any spot, so choosing where to
/// stand takes street-level detail. The bundled world image is about 7 km a pixel, wider than the
/// band. MapKit needs a network connection while planning, and keeps what has been looked at.
struct ConjunctionMap: View {
    @Environment(AppModel.self) private var model
    let event: Conjunction?
    var previous: Conjunction?
    @State private var camera: MapCameraPosition = .automatic

    static func color(_ body: SolarSystemBody) -> Color { body == .sun ? .orange : Theme.focus }

    var body: some View {
        let c = model.conjunctions
        let centre = event?.centre ?? c.centre
        let radius = event?.radius ?? c.settings.radius
        Map(position: $camera) {
            if let centre {
                MapCircle(center: centre.coordinate, radius: radius * 1000)
                    .foregroundStyle(Theme.accent.opacity(0.07))
                    .stroke(Theme.accent.opacity(0.7), lineWidth: 1.5)
                Annotation(c.centreName.components(separatedBy: ",")[0], coordinate: centre.coordinate) {
                    Image(systemName: c.settings.place == nil ? "house.fill" : "mappin")
                        .font(.caption.bold()).foregroundStyle(.white)
                        .padding(5).background(Theme.accent, in: Circle())
                }
            }
            if let previous {
                MapPolyline(coordinates: previous.path.map(\.centre.coordinate))
                    .stroke(.gray.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
            }
            if let event {
                let color = Self.color(event.body)
                let lefts = event.path.compactMap(\.left?.coordinate)
                let rights = event.path.compactMap(\.right?.coordinate)
                if lefts.count > 1 && rights.count > 1 {
                    MapPolygon(coordinates: lefts + rights.reversed()).foregroundStyle(color.opacity(0.22))
                    MapPolyline(coordinates: lefts).stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    MapPolyline(coordinates: rights).stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                }
                MapPolyline(coordinates: event.path.map(\.centre.coordinate)).stroke(color, lineWidth: 3)
                ForEach(ticks(event), id: \.date) { tick in
                    Annotation("", coordinate: tick.point.coordinate, anchor: .center) {
                        VStack(spacing: 1) {
                            Circle().fill(color).frame(width: 7, height: 7)
                                .overlay(Circle().stroke(.black.opacity(0.5), lineWidth: 0.5))
                            if tick.labelled {
                                Text(tick.date, format: .dateTime.hour().minute().second())
                                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                    .padding(.horizontal, 3)
                                    .background(.regularMaterial, in: Capsule())
                            }
                        }
                    }
                }
                Annotation("", coordinate: event.closestPoint.coordinate) {
                    Image(systemName: "scope").font(.title3.bold()).foregroundStyle(color)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls {
            MapScaleView()
            #if os(macOS)
            MapZoomStepper()
            #endif
            MapCompass()
        }
        .onAppear { frame(centre: centre, radius: radius) }
        .onChange(of: event?.id) { _, _ in frame(centre: centre, radius: radius) }
        .onChange(of: c.settings) { _, _ in frame(centre: centre, radius: radius) }
    }

    /// The search circle filling the view.
    private func frame(centre: Geodetic?, radius: Double) {
        guard let centre else { return }
        withAnimation {
            camera = .region(MKCoordinateRegion(center: centre.coordinate,
                                                latitudinalMeters: radius * 2600, longitudinalMeters: radius * 2600))
        }
    }

    /// A dot every second along the centreline; every few seconds labelled with the time.
    private func ticks(_ event: Conjunction) -> [(date: Date, point: Geodetic, labelled: Bool)] {
        let whole = event.path.filter { abs($0.date.timeIntervalSince1970 - $0.date.timeIntervalSince1970.rounded()) < 0.026 }
        let every = max(1, Int((Double(whole.count) / 10).rounded(.up)))
        return whole.map { p in
            let second = Int(p.date.timeIntervalSince1970.rounded())
            return (p.date, p.centre, second % every == 0)
        }
    }
}

/// Which satellites the conjunction search covers: the space stations, and any chosen by name
/// or number from the loaded catalogue.
struct SatelliteChooser: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @FocusState private var typing: Bool

    var body: some View {
        @Bindable var c = model.conjunctions
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Space stations (ISS, Tiangong)", isOn: $c.settings.includeStations)
                .font(.caption)
            if !c.settings.chosen.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(c.settings.chosen, id: \.self) { id in
                            HStack(spacing: 4) {
                                Text(c.name(of: id).map(EventList.short) ?? "#\(id)").lineLimit(1)
                                Button { c.unchoose(id) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Remove \(c.name(of: id) ?? id)")
                            }
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Theme.accent.opacity(0.15), in: Capsule())
                            .help(c.name(of: id).map { "\($0), NORAD \(id)" } ?? "NORAD \(id): not in the loaded catalogue")
                        }
                    }
                }
            }
            TextField("Add a satellite: name or number", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($typing)
                .autocorrectionDisabled()
                .onSubmit { if let first = c.matches(text).first { add(first) } }
            if typing || !text.isEmpty {
                let matches = c.matches(text)
                ForEach(matches, id: \.noradID) { s in
                    Button { add(s) } label: {
                        HStack {
                            Text(s.name).lineLimit(1)
                            Spacer()
                            Text(s.noradID).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                }
                if !text.isEmpty && matches.isEmpty {
                    Text("Nothing called that in the loaded catalogue. Turn on a source that has it under Objects.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func add(_ satellite: SatelliteTarget) {
        model.conjunctions.choose(satellite)
        text = ""
    }
}
