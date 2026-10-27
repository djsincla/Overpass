import Foundation
import Testing
@testable import SkyKit

@Suite struct GroundTrackTests {
    let iss = TLEParser.parse(issTLE)[0]

    @Test func pointsLieUnderTheSatellite() throws {
        let start = iss.epoch
        let points = GroundTrack.points(of: iss, from: start, to: start + 600, step: 60)
        #expect(points.count == 11)
        for point in points {
            // Straight up from the ground below it.
            let sat = try iss.earthFixedPosition(at: AstroTime(point.date))
            let ground = Geodetic(latitude: point.place.latitude, longitude: point.place.longitude).observer
            let look = ground.horizontal(ofEarthFixed: sat)
            // Exactly overhead can round just past 90° and read as NaN.
            #expect(look.altitude.isNaN || look.altitude > 89.9)
            // The ISS stays within its inclination of the equator.
            #expect(abs(point.place.latitude) < 52)
        }
    }

    @Test func oneOrbitCrossesTheDateLineOnce() {
        let start = iss.epoch
        let points = GroundTrack.points(of: iss, from: start, to: start + iss.period * 60, step: 20)
        let segments = GroundTrack.segments(points)
        // Westward drift means one orbit crosses ±180° once, occasionally twice.
        #expect((2...3).contains(segments.count))
        for segment in segments {
            for (a, b) in zip(segment, segment.dropFirst()) { #expect(abs(b.longitude - a.longitude) < 180) }
        }
        // The pieces meet at the meridian.
        for (a, b) in zip(segments, segments.dropFirst()) {
            #expect(abs(abs(a.last!.longitude) - 180) < 1e-9)
            #expect(a.last!.longitude == -b.first!.longitude)
            #expect(abs(a.last!.latitude - b.first!.latitude) < 1e-9)
        }
    }

    @Test func splitsWherePointsJumpAcrossTheMeridian() {
        let t = Date(timeIntervalSince1970: 0)
        let points = [GroundPoint(date: t, place: Geodetic(latitude: 0, longitude: 170)),
                      GroundPoint(date: t + 1, place: Geodetic(latitude: 10, longitude: -170))]
        let segments = GroundTrack.segments(points)
        #expect(segments.count == 2)
        #expect(segments[0].last == Geodetic(latitude: 5, longitude: 180))
        #expect(segments[1].first == Geodetic(latitude: 5, longitude: -180))
    }
}
