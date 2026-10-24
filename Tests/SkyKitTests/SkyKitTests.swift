import Foundation
import SatelliteKit
import Testing
@testable import SkyKit

let issTLE = """
ISS (ZARYA)
1 25544U 98067A   08264.51782528 -.00002182  00000-0 -11606-4 0  2927
2 25544  51.6416 247.4627 0006703 130.5360 325.0288 15.72125391563537
"""

func degrees(_ d: Double, _ m: Double, _ s: Double) -> Double {
    (d < 0 ? -1 : 1) * (abs(d) + m / 60 + s / 3600)
}

@Suite struct EphemerisTests {
    @Test func sunMeeus25a() {
        // 1992 Oct 13.0 TD: α = 13h13m31.4s, δ = −7°47′06″.
        let (ra, dec) = SolarSystemBody.sun.raDec(AstroTime(jdTT: 2_448_908.5))
        #expect(abs(ra - 198.38083) < 0.003)
        #expect(abs(dec - -7.78507) < 0.003)
    }

    @Test func moonMeeus47a() {
        // 1992 Apr 12.0 TD: λ = 133.162655°, β = −3.229126°, Δ = 368409.7 km; α = 134.688470°, δ = 13.768368°.
        let time = AstroTime(jdTT: 2_448_724.5)
        let ecl = SolarSystemBody.moonEcliptic(time)
        #expect(abs(ecl.lambda - 133.162655) < 0.005)
        #expect(abs(ecl.beta - -3.229126) < 0.005)
        #expect(abs(ecl.distance - 368_409.7) < 20)
        let (ra, dec) = SolarSystemBody.moon.raDec(time)
        #expect(abs(ra - 134.688470) < 0.01)
        #expect(abs(dec - 13.768368) < 0.01)
    }

    @Test func venusMeeus33a() {
        // 1992 Dec 20.0 TD: apparent α = 21h04m41.454s, δ = −18°53′16.84″.
        let (ra, dec) = SolarSystemBody.venus.raDec(AstroTime(jdTT: 2_448_976.5))
        #expect(abs(ra - degrees(21, 4, 41.454) * 15) < 0.05)
        #expect(abs(dec - degrees(-18, 53, 16.84)) < 0.05)
    }

    @Test func precessionMeeus21b() {
        // θ Persei, J2000 position with proper motion applied, to 2028 Nov 13.19 TD.
        let star = Star(name: "θ Per", ra: degrees(2, 44, 12.975) * 15, dec: degrees(49, 13, 39.90), magnitude: 4)
        let s = star.equatorialOfDate(AstroTime(jdTT: 2_462_088.69)).spherical
        #expect(abs(s.longitude - degrees(2, 46, 11.331) * 15) < 0.0005)
        #expect(abs(s.latitude - degrees(49, 20, 54.54)) < 0.0005)
    }

    @Test func gmstMeeus12a() {
        // 1987 Apr 10 0h UT: GMST = 13h10m46.3668s.
        let time = AstroTime(Date(timeIntervalSince1970: (2_446_895.5 - 2_440_587.5) * 86_400))
        #expect(abs(time.gmst - degrees(13, 10, 46.3668) * 15) < 1e-4)
    }
}

@Suite struct ObserverTests {
    @Test func zenithAndNorth() {
        let observer = Observer(latitude: 40, longitude: -75, height: 100, refraction: false)
        let up = observer.position + 1000 * observer.position.normalized
        // Geodetic "up" differs from geocentric by up to ~0.19°.
        #expect(observer.horizontal(ofEarthFixed: up).altitude > 89.7)
        let pole = Vec3(0, 0, 1e9)
        let h = observer.horizontal(ofEarthFixed: pole)
        #expect(abs(h.azimuth) < 1e-6 || abs(h.azimuth - 360) < 1e-6)
        #expect(abs(h.altitude - 40) < 0.01)
    }

    @Test func refractionAtHorizon() {
        #expect(abs(Observer.refraction(geometricAltitude: 0) * 60 - 29) < 2)
        #expect(Observer.refraction(geometricAltitude: 90) < 1e-4)
    }
}

@Suite struct SatelliteTests {
    @Test func valladoVerificationCase() throws {
        // SGP4-VER case 00005 at t = 0: r = (7022.46529266, −1400.08296755, 0.03995155) km.
        let sat = try SatelliteTarget(name: "00005",
                                      line1: "1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753",
                                      line2: "2 00005  34.2682 348.7242 1859667 331.7664  19.3264 10.82419157413667")
        let r = try sat.satellite.position(minsAfterEpoch: 0)
        #expect(abs(r.x - 7022.46529266) < 0.01)
        #expect(abs(r.y - -1400.08296755) < 0.01)
        #expect(abs(r.z - 0.03995155) < 0.01)
    }

    @Test func parsesTLEFormats() {
        #expect(TLEParser.parse(issTLE).first?.name == "ISS (ZARYA)")
        let twoLine = issTLE.split(separator: "\n").dropFirst().joined(separator: "\n")
        #expect(TLEParser.parse(twoLine).count == 1)
        #expect(TLEParser.parse(issTLE + "\n" + issTLE).count == 2)
        #expect(TLEParser.parse("garbage\nmore garbage").isEmpty)
    }

    @Test func topocentricAgreesWithSatelliteKit() throws {
        // SatelliteKit 2.1.2's geo2eci uses (1 + e²sin²φ) instead of (1 − e²sin²φ), misplacing
        // observers away from the equator by ~18 km. At the equator the bug vanishes, so compare there.
        let sat = TLEParser.parse(issTLE)[0]
        let observer = Observer(latitude: 0, longitude: -75, height: 0, refraction: false)
        var compared = 0
        for minutes in stride(from: 0.0, to: 1440, by: 3) {
            let time = AstroTime(sat.epoch + minutes * 60)
            let mine = try observer.look(at: sat, time)
            guard mine.altitude > -30 else { continue }
            let theirs = try sat.satellite.topPosition(julianDays: time.jdUT, observer: LatLonAlt(0, -75, 0))
            // Remaining difference: WGS84 vs WGS72 equatorial radius (6378.137 vs 6378.135 km).
            #expect(abs(mine.altitude - theirs.elev) < 0.01)
            #expect(abs(mine.range - theirs.dist) < 0.05)
            if mine.altitude < 85 { #expect(abs(wrap180(mine.azimuth - theirs.azim)) < 0.01) }
            compared += 1
        }
        #expect(compared > 10)
    }

    @Test func observerMatchesWGS84Reference() {
        // 40°N 75°W at sea level (independently computed): X = 1266.326, Y = −4725.993, Z = 4077.986 km.
        let p = Observer(latitude: 40, longitude: -75).position
        #expect(abs(p.x - 1266.326) < 0.001)
        #expect(abs(p.y - -4725.993) < 0.001)
        #expect(abs(p.z - 4077.986) < 0.001)
    }
}

@Suite struct PassTests {
    let sat = TLEParser.parse(issTLE)[0]
    var predictor: PassPredictor { PassPredictor(observer: Observer(latitude: 40, longitude: -75)) }

    @Test func passesAreSane() throws {
        let passes = try predictor.passes(of: sat, from: sat.epoch, to: sat.epoch + 2 * 86_400)
        #expect((6...14).contains(passes.count))
        for pass in passes where !pass.truncated {
            #expect(abs(pass.start.position.altitude) < 0.05)
            #expect(abs(pass.end.position.altitude) < 0.05)
            #expect(pass.start.date < pass.culmination.date && pass.culmination.date < pass.end.date)
            #expect(pass.duration < 15 * 60)
            #expect(pass.maxAltitude <= 90)
            #expect(pass.minimumRange > 300)
        }
        // Passes don't overlap.
        for (a, b) in zip(passes, passes.dropFirst()) { #expect(a.end.date < b.start.date) }
    }

    @Test func horizonMaskShortensPasses() throws {
        var masked = predictor
        masked.horizonMask = HorizonMask([(0, 20), (180, 20)])
        let open = try predictor.passes(of: sat, from: sat.epoch, to: sat.epoch + 86_400)
        let blocked = try masked.passes(of: sat, from: sat.epoch, to: sat.epoch + 86_400)
        #expect(blocked.count <= open.count)
        for pass in blocked { #expect(pass.start.position.altitude > 19.9) }
    }

    @Test func horizonMaskInterpolates() {
        let mask = HorizonMask([(90, 10), (270, 30)])
        #expect(abs(mask.minimumAltitude(at: 180) - 20) < 1e-9)
        #expect(abs(mask.minimumAltitude(at: 0) - 20) < 1e-9)   // wraps through north
        #expect(abs(mask.minimumAltitude(at: 90) - 10) < 1e-9)
    }

    @Test func filters() throws {
        let passes = try predictor.passes(of: sat, from: sat.epoch, to: sat.epoch + 2 * 86_400)
        var filter = PassFilter()
        filter.minimumMaxAltitude = 45
        #expect(passes.filter(filter.matches).allSatisfy { $0.maxAltitude >= 45 })

        filter = PassFilter()
        filter.minimumMaxAltitude = 0
        filter.maximumAxisRate = 1
        #expect(passes.filter(filter.matches).allSatisfy { $0.peakAxisRate <= 1 })

        filter = PassFilter()
        filter.minimumMaxAltitude = 0
        filter.visibility = .visibleOnly
        #expect(passes.filter(filter.matches).allSatisfy { $0.isVisible })

        filter = PassFilter()
        filter.minimumMaxAltitude = 0
        filter.culminationAzimuth = (from: 270, to: 90)   // northern half, wrapping through 0
        for pass in passes.filter(filter.matches) {
            let az = pass.culmination.position.azimuth
            #expect(az >= 270 || az <= 90)
        }

        filter = PassFilter()
        filter.minimumMaxAltitude = 0
        filter.nameContains = "zarya"
        #expect(passes.filter(filter.matches).count == passes.count)
        filter.nameContains = "hubble"
        #expect(passes.filter(filter.matches).isEmpty)
    }

    @Test func sortsAndRunsInParallel() async {
        var filter = PassFilter()
        filter.minimumMaxAltitude = 0
        let passes = await predictor.passes(of: [sat], from: sat.epoch, to: sat.epoch + 86_400,
                                            filter: filter, sort: .maxAltitude)
        #expect(!passes.isEmpty)
        #expect(zip(passes, passes.dropFirst()).allSatisfy { $0.maxAltitude >= $1.maxAltitude })
    }
}

@Suite struct AlignmentTests {
    var truth: AlignmentModel {
        var m = AlignmentModel()
        m.yaw = 37
        m.tiltNorth = 0.3
        m.tiltEast = -0.2
        m.altitudeOffset = 1.5
        m.azimuthSense = -1
        return m
    }

    func points(_ skies: [(Double, Double)], model: AlignmentModel) -> [AlignmentPoint] {
        skies.map { az, alt in
            let sky = Horizontal(azimuth: az, altitude: alt)
            return AlignmentPoint(targetName: "", date: .now, sky: sky, axes: model.axes(for: sky))
        }
    }

    @Test func roundTrip() {
        let sky = Horizontal(azimuth: 123, altitude: 45)
        let back = truth.sky(for: truth.axes(for: sky))
        #expect(angularSeparation(back.unitVector, sky.unitVector) < 1e-9)
    }

    @Test func threeStarsRecoverModelAndSense() throws {
        let pts = points([(20, 30), (140, 55), (260, 40)], model: truth)
        let fit = try #require(AlignmentModel.fit(pts))
        #expect(fit.azimuthSense == -1)
        #expect(fit.rms(pts) < 1e-6)
        // Check predictions anywhere in the sky, not just the parameters.
        for sky in [Horizontal(azimuth: 300, altitude: 70), Horizontal(azimuth: 90, altitude: 15)] {
            let a = fit.axes(for: sky), b = truth.axes(for: sky)
            #expect(abs(wrap180(a.primary - b.primary)) < 1e-5)
            #expect(abs(a.secondary - b.secondary) < 1e-5)
        }
    }

    @Test func twoStarsAreEnough() throws {
        let pts = points([(50, 25), (200, 60)], model: truth)
        let fit = try #require(AlignmentModel.fit(pts))
        let check = truth.axes(for: Horizontal(azimuth: 120, altitude: 40))
        let got = fit.axes(for: Horizontal(azimuth: 120, altitude: 40))
        #expect(abs(wrap180(got.primary - check.primary)) < 0.01)
        #expect(abs(got.secondary - check.secondary) < 0.01)
    }

    @Test func oneStarOnLevelMount() throws {
        var level = truth
        level.tiltNorth = 0
        level.tiltEast = 0
        let fit = try #require(AlignmentModel.fit(points([(80, 35)], model: level), azimuthSense: -1))
        let sky = Horizontal(azimuth: 250, altitude: 60)
        #expect(abs(wrap180(fit.axes(for: sky).primary - level.axes(for: sky).primary)) < 1e-6)
    }

    @Test func starPickerSpreadsStars() {
        let picks = AlignmentStarPicker.suggest(observer: Observer(latitude: 40, longitude: -75),
                                                date: Date(timeIntervalSince1970: 1_792_800_000))
        #expect(picks.count == 3)
        for p in picks { #expect((20...75).contains(p.position.altitude)) }
        let azimuths = picks.map(\.position.azimuth)
        for i in azimuths.indices { for j in azimuths.indices where i < j {
            #expect(abs(wrap180(azimuths[i] - azimuths[j])) > 30)
        } }
    }
}
