import Foundation
import Testing
@testable import SkyKit

@Suite struct GeodesyTests {
    @Test func roundTripsThroughEarthFixed() {
        let place = Observer(latitude: 35.36, longitude: -120.84, height: 120, refraction: false)
        let g = Geodesy.geodetic(ofEarthFixed: place.position)
        #expect(abs(g.latitude - 35.36) < 1e-9 && abs(g.longitude - -120.84) < 1e-9)
        #expect(abs(g.height - 0.120) < 1e-6)
    }

    @Test func rayMeetsTheGround() throws {
        let origin = Vec3(20_000, 0, 0)
        let hit = try #require(Geodesy.intersectEllipsoid(origin: origin, direction: Vec3(-1, 0, 0)))
        #expect(abs(hit.x - Observer.wgs84A) < 1e-9)
        #expect(Geodesy.intersectEllipsoid(origin: origin, direction: Vec3(1, 0, 0)) == nil)
        #expect(Geodesy.intersectEllipsoid(origin: origin, direction: Vec3(0, 1, 0)) == nil)
    }

    @Test func distanceBearingAndDestinationAgree() {
        let a = Geodetic(latitude: 35, longitude: -120)
        let b = Geodesy.destination(from: a, bearing: 60, distance: 25)
        #expect(abs(Geodesy.distance(a, b) - 25) < 1e-9)
        #expect(abs(Geodesy.bearing(from: a, to: b) - 60) < 1e-6)
    }
}

@Suite struct ConjunctionTests {
    let iss = TLEParser.parse(issTLE)[0]

    /// A moment when the ISS's line to the Moon reaches the ground with the Moon well up there.
    func aTransit() throws -> (date: Date, point: ConjunctionPathPoint) {
        var finder = ConjunctionFinder(centre: Geodetic(latitude: 0, longitude: 0))
        finder.minimumBodyAltitude = 30
        var t = iss.epoch
        while t < iss.epoch + 86_400 {
            if let p = try finder.shadow(of: iss, on: .moon, at: t), p.left != nil, p.right != nil { return (t, p) }
            t += 60
        }
        throw CancellationError()
    }

    @Test func centrelineSeesTheSatelliteOnTheMoonsCentre() throws {
        let (t, point) = try aTransit()
        let time = AstroTime(t)
        func separation(_ g: Geodetic) throws -> Double {
            let site = g.observer
            return angularSeparation(try iss.earthFixedPosition(at: time) - site.position,
                                     SolarSystemBody.moon.earthFixedPosition(at: time) - site.position)
        }
        #expect(try separation(point.centre) < 1.0 / 3600)
        // At either edge it's on the limb.
        let site = point.centre.observer
        let disc = asin(ConjunctionFinder.physicalRadius(.moon) / (SolarSystemBody.moon.earthFixedPosition(at: time) - site.position).length).degrees
        for edge in [point.left!, point.right!] {
            #expect(abs(try separation(edge) - disc) < 0.03 * disc)
        }
    }

    @Test func searchFindsItNearby() async throws {
        let (t, point) = try aTransit()
        var finder = ConjunctionFinder(centre: Geodesy.destination(from: point.centre, bearing: 90, distance: 10))
        finder.radius = 30
        finder.bodies = [.moon]
        finder.minimumBodyAltitude = 10
        let found = await finder.find([iss], from: t - 600, to: t + 600)
        let event = try #require(found.first)
        #expect(event.distance <= 10.01)
        // The traced band passes through the transit point at its moment.
        let at = try #require(event.path.min { abs($0.date.timeIntervalSince(t)) < abs($1.date.timeIntervalSince(t)) })
        #expect(abs(at.date.timeIntervalSince(t)) < 0.03)
        #expect(Geodesy.distance(at.centre, point.centre) < 0.5)
        #expect(event.width > 0.5 && event.width < 30)
        #expect(event.duration > 0.1 && event.duration < 5)
        #expect(event.illumination != nil)
    }

    @Test func searchIgnoresAnotherPlace() async throws {
        let (t, point) = try aTransit()
        // 60 km across the band's direction of travel, with a 1 km radius: out of reach.
        let finder0 = ConjunctionFinder(centre: point.centre)
        let later = try #require(try finder0.shadow(of: iss, on: .moon, at: t + 0.5))
        let along = Geodesy.bearing(from: point.centre, to: later.centre)
        var finder = ConjunctionFinder(centre: Geodesy.destination(from: point.centre, bearing: along + 90, distance: 60))
        finder.radius = 1
        finder.bodies = [.moon]
        #expect(await finder.find([iss], from: t - 600, to: t + 600).isEmpty)
    }

    @Test func driftFollowsTimingError() async throws {
        let (t, point) = try aTransit()
        var finder = ConjunctionFinder(centre: point.centre)
        finder.radius = 30
        finder.bodies = [.moon]
        let original = try #require(await finder.find([iss], from: t - 600, to: t + 600).first)
        // The satellite half a second further along its track: the event comes about 0.5 s sooner,
        // on nearly the same line (it's the same orbit, just earlier).
        var shifted = finder
        shifted.satelliteTimeOffset = 0.5
        let updated = try #require(await shifted.recalculate(original, with: iss))
        let drift = ConjunctionDrift(from: original, to: updated)
        #expect(abs(drift.seconds - -0.5) < 0.1)
        #expect(drift.distance < 0.5)
    }
}
