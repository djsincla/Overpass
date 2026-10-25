import CoreLocation
import Foundation
import Observation
import SkyKit

/// What the conjunction search covers, saved between launches.
struct ConjunctionSettings: Codable, Equatable {
    /// A named place to search around; nil means home (the location in Settings).
    var place: SearchPlace?
    /// Search radius, km.
    var radius: Double = 50
    var daysAhead: Double = 7
    var moon = true
    var sun = true
    /// The Moon or Sun must be at least this high where the band is.
    var minimumAltitude: Double = 10
    /// Also search the satellites selected on the Observe screen, not just the space stations.
    var includeSelected = false
}

struct SearchPlace: Codable, Equatable {
    var name: String
    var location: Geodetic
}

/// An event the user is following: refreshed and recalculated as it approaches.
struct WatchedConjunction: Codable, Identifiable, Equatable {
    var event: Conjunction
    /// The calculation before the latest, to show how it moved.
    var previous: Conjunction?
    var drift: ConjunctionDrift?
    var updated: Date
    /// The search radius it was watched with (a recalculation that misses may look wider).
    var radius: Double
    /// The latest calculation no longer comes within the search radius.
    var missesArea = false
    var id: String { event.noradID + "-" + event.body.rawValue + "-" + String(Int(event.closest.timeIntervalSince1970 / 600)) }
}

/// Space station transits of the Moon and Sun around a place.
@MainActor @Observable
final class ConjunctionsModel {
    weak var app: AppModel?

    var settings: ConjunctionSettings { didSet { app?.save(settings, "conjunctionSettings") } }
    private(set) var results: [Conjunction] = []
    private(set) var watched: [WatchedConjunction] { didSet { app?.save(watched, "watchedConjunctions") } }
    private(set) var isSearching = false
    private(set) var isUpdating = false
    private(set) var lastSearch: Date?
    var message: String?

    /// The space stations: one element set per station (docked modules share an orbit).
    static let stationIDs = ["25544": "ISS", "48274": "Tiangong (CSS)"]

    private var watchTask: Task<Void, Never>?

    init() {
        settings = AppModel.load("conjunctionSettings", default: ConjunctionSettings())
        watched = AppModel.load("watchedConjunctions", default: [WatchedConjunction]())
    }

    // MARK: Where and what

    var centre: Geodetic? {
        if let place = settings.place { return place.location }
        guard let s = app?.settings, s.hasLocation else { return nil }
        return Geodetic(latitude: s.latitude, longitude: s.longitude, height: s.heightMeters / 1000)
    }

    var centreName: String { settings.place?.name ?? "Home" }

    var bodies: [SolarSystemBody] { (settings.moon ? [.moon] : []) + (settings.sun ? [.sun] : []) }

    /// The stations from the TLE catalog, plus the Observe selection if asked.
    var satellites: [SatelliteTarget] {
        guard let app else { return [] }
        var list = app.satellites.filter { Self.stationIDs[$0.noradID] != nil }
        if settings.includeSelected {
            for case .satellite(let s) in app.selectedObjects { list.append(s) }
        }
        // One per NORAD id, the newest elements (a satellite can be in several sources).
        var unique: [String: SatelliteTarget] = [:]
        for s in list where unique[s.noradID].map({ s.epoch > $0.epoch }) ?? true { unique[s.noradID] = s }
        return unique.values.sorted { $0.name < $1.name }
    }

    var stationsMissing: Bool { app?.satellites.contains { Self.stationIDs[$0.noradID] != nil } != true }

    func finder(around centre: Geodetic) -> ConjunctionFinder {
        var f = ConjunctionFinder(centre: centre)
        f.radius = settings.radius
        f.bodies = bodies
        f.minimumBodyAltitude = settings.minimumAltitude
        return f
    }

    /// Looks a place name up and makes it the search centre.
    func setPlace(named query: String) async {
        do {
            let marks = try await CLGeocoder().geocodeAddressString(query)
            guard let mark = marks.first, let location = mark.location else {
                message = "Couldn't find \(query)."
                return
            }
            let name = [mark.name, mark.locality, mark.administrativeArea].compactMap { $0 }
                .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ", ")
            settings.place = SearchPlace(name: name.isEmpty ? query : name,
                                         location: Geodetic(latitude: location.coordinate.latitude,
                                                            longitude: location.coordinate.longitude))
        } catch {
            message = "Couldn't look up \(query): \(error.localizedDescription)"
        }
    }

    // MARK: Search

    func search() async {
        guard let centre else {
            message = "Set your location in Settings, or choose a place to search around."
            return
        }
        let sats = satellites
        guard !sats.isEmpty else {
            message = "No space station elements yet: turn on the Space stations source in Objects."
            return
        }
        guard !bodies.isEmpty else { return }
        isSearching = true
        defer { isSearching = false }
        let finder = finder(around: centre)
        let now = Date.now
        results = await finder.find(sats, from: now, to: now + settings.daysAhead * 86_400)
        lastSearch = now
    }

    // MARK: Watching

    func isWatched(_ event: Conjunction) -> Bool { watched.contains { $0.event.id == event.id || Self.sameEvent($0.event, event) } }

    func watch(_ event: Conjunction) {
        guard !isWatched(event) else { return }
        watched.append(WatchedConjunction(event: event, updated: .now, radius: event.radius))
        watched.sort { $0.event.closest < $1.event.closest }
    }

    func unwatch(_ id: String) { watched.removeAll { $0.id == id } }

    static func sameEvent(_ a: Conjunction, _ b: Conjunction) -> Bool {
        a.noradID == b.noradID && a.body == b.body && abs(a.closest.timeIntervalSince(b.closest)) < 600
    }

    /// Checks watched events every 30 minutes while the app runs.
    func startWatching() {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.updateWatched(force: false)
                try? await Task.sleep(for: .seconds(1800))
            }
        }
    }

    /// The element sets should be this fresh for an event this far away.
    static func wantedFreshness(until event: TimeInterval) -> TimeInterval? {
        switch event {
        case ..<(6 * 3600): 2 * 3600
        case ..<86_400: 4 * 3600
        case ..<(3 * 86_400): 12 * 3600
        default: nil
        }
    }

    /// Refreshes the station elements when an upcoming watched event needs fresher ones, then
    /// recalculates each watched event whose elements changed. `force` refreshes and
    /// recalculates regardless (the "Refresh TLE now" button).
    func updateWatched(force: Bool) async {
        guard let app else { return }
        let now = Date.now
        watched.removeAll { $0.event.closest < now - 3600 }
        let upcoming = watched.filter { $0.event.closest > now }
        guard !upcoming.isEmpty else { return }
        isUpdating = true
        defer { isUpdating = false }

        // Refresh the station source if any upcoming event wants fresher elements than we have.
        let stale = upcoming.contains { w in
            guard let wanted = Self.wantedFreshness(until: w.event.closest.timeIntervalSince(now)) else { return false }
            let sat = app.satellites.first { $0.noradID == w.event.noradID }
            return (sat.map { now.timeIntervalSince($0.epoch) } ?? .infinity) > wanted
        }
        if force || stale {
            for source in app.sources where source.enabled && source.id == "celestrak-stations" {
                await app.refresh(source.id, quietly: !force)
            }
        }

        for (i, w) in watched.enumerated() where w.event.closest > now {
            guard let sat = app.satellites.first(where: { $0.noradID == w.event.noradID }),
                  force || sat.epoch > w.event.elementEpoch else { continue }
            var finder = finder(around: w.event.centre)
            finder.radius = w.radius
            if let fresh = await finder.recalculate(w.event, with: sat) {
                watched[i].previous = w.event
                watched[i].drift = ConjunctionDrift(from: w.event, to: fresh)
                watched[i].event = fresh
                watched[i].missesArea = false
            } else {
                // Recalculate without the radius limit, to show where it went.
                finder.radius = max(w.radius * 4, 200)
                if let wider = await finder.recalculate(w.event, with: sat) {
                    watched[i].previous = w.event
                    watched[i].drift = ConjunctionDrift(from: w.event, to: wider)
                    watched[i].event = wider
                }
                watched[i].missesArea = true
            }
            watched[i].updated = now
        }
    }
}
