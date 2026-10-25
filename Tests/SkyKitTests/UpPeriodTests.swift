import Foundation
import Testing
@testable import SkyKit

@Suite struct UpPeriodTests {
    let observer = Observer(latitude: 40, longitude: -75, refraction: false)
    // 2026-10-26 12:00 UTC (07:00 local mean time at 75° W): the Sun is up.
    let from = Date(timeIntervalSince1970: 1_793_016_000)

    @Test func sunRisesOnceADay() throws {
        let periods = try observer.upPeriods(of: SolarSystemBody.sun, from: from, to: from + 7 * 86_400)
        // Today's (already up, so no rise in the window) plus seven sunrises: the seventh,
        // a week on, comes just before the window closes.
        #expect(periods.count == 8)
        #expect(periods[0].rise == nil && periods[0].set != nil)
        for (a, b) in zip(periods, periods.dropFirst()) {
            let gap = try #require(b.rise).timeIntervalSince(try #require(a.set))
            // Roughly 13 hours of night at 40° N in late October.
            #expect(gap > 12 * 3600 && gap < 15 * 3600)
        }
        // Rises in the east, sets in the west; peaks around 37° at noon.
        let day = periods[1]
        let rise = try #require(day.riseAzimuth), set = try #require(day.setAzimuth)
        let peak = try #require(day.maxAltitude)
        #expect(rise > 90 && rise < 120)
        #expect(set > 240 && set < 270)
        #expect(abs(peak - 37) < 3)
    }

    @Test func circumpolarStarNeverSets() throws {
        let polaris = try #require(BrightStars.all.first { $0.name == "Polaris" })
        let periods = try observer.upPeriods(of: polaris, from: from, to: from + 3 * 86_400)
        #expect(periods.count == 1)
        #expect(periods[0].rise == nil && periods[0].set == nil)
    }
}

@Suite struct NeverRisingTests {
    @Test func issNeverRisesNearThePole() async throws {
        let iss = TLEParser.parse(issTLE)[0]
        let week = (iss.epoch, iss.epoch + 7 * 86_400)
        // 51.6° inclination at 420 km: seen from 40° N most days, never from 85° N.
        let midLatitudes = PassPredictor(observer: Observer(latitude: 40, longitude: -75))
        let arctic = PassPredictor(observer: Observer(latitude: 85, longitude: -75))
        #expect(try midLatitudes.rises(iss, from: week.0, to: week.1))
        #expect(!(try arctic.rises(iss, from: week.0, to: week.1)))
        #expect(await arctic.neverRising([iss], from: week.0, to: week.1).map(\.noradID) == [iss.noradID])
        #expect(await midLatitudes.neverRising([iss], from: week.0, to: week.1).isEmpty)
    }
}
