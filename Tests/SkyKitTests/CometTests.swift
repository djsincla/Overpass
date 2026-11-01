import Foundation
import Testing
@testable import SkyKit

/// `CometEls.txt` lines from 31 Oct 2026, checked against JPL Horizons (astrometric J2000, geocentric)
/// for 2026-11-01 00:00 UT.
let cometFixture = """
    PK26R020  2026 10 25.2362  0.789531  0.898738  205.5265  179.2305   78.0993  20261031  16.0  4.0  P/2026 R2 (Leonard)                                      MPEC 2026-UA3
0161P         2026 11 27.1785  1.265108  0.836176   47.0654    1.4736   95.7920  20261031   8.5  6.0  161P/Hartley-IRAS                                        MPEC 2026-TP0
0012P         2024 04 21.2101  0.781945  0.954750  199.0363  255.8681   74.1453  20261031   5.0  6.0  12P/Pons-Brooks                                          MPC194091
    CK23A030  2024 09 27.8385  0.391301  1.000181  308.5869   21.6798  139.0985  20261031   6.5  3.2  C/2023 A3 (Tsuchinshan-ATLAS)                            MPEC 2026-K60
    CJ47X01b  1947 10 23.9898  0.124509  0.999438  196.9641  338.0844  140.8695  20261031   9.0  4.0  C/1947 X1-B (Southern comet)                              38,  189
not a comet line
"""

@Suite struct CometTests {
    let comets = MPCComets.parse(cometFixture)
    let time = AstroTime(Date(timeIntervalSince1970: 1_793_491_200))

    func comet(_ prefix: String) throws -> Comet { try #require(comets.first { $0.name.hasPrefix(prefix) }) }

    @Test func parsesTheFixedColumns() throws {
        #expect(comets.count == 5)
        let c = try comet("161P")
        #expect(c.q == 1.265108 && c.e == 0.836176 && c.inclination == 95.7920)
        #expect(c.absoluteMagnitude == 8.5 && c.slope == 6.0)
        #expect(c.designation == "161P")
        #expect(try comet("C/2023 A3").designation == "C/2023 A3")
        #expect(try comet("C/1947 X1-B").designation == "C/1947 X1-B")
        // 2026-11-27.1785 TT.
        #expect(abs(c.perihelionJD - 2_461_371.6785) < 1e-6)
    }

    @Test(arguments: [("P/2026 R2", 241.56762, -63.76320, 0.72850),
                      ("161P", 298.72755, 13.75154, 0.92443),
                      ("12P", 246.40298, -30.98409, 9.87504),
                      ("C/2023 A3", 267.40028, 13.57682, 9.30883)])
    func matchesHorizons(prefix: String, ra: Double, dec: Double, delta: Double) throws {
        let c = try comet(prefix)
        let here = c.geocentricJ2000(jdTT: time.jdTT)
        let horizons = Vec3.unit(longitude: ra, latitude: dec)
        #expect(angularSeparation(here, horizons) * 3600 < 15)
        #expect(abs(c.distances(time).delta - delta) < 0.001)
    }

    @Test func ellipseMatchesThePlanetSolver() {
        // Earth's mean elements at J2000 as a "comet": the two solvers agree.
        let e = 0.01671123, a = 1.00000261
        let peri = 102.93768193, meanLongitude = 100.46457166
        let daysSincePerihelion = (meanLongitude - peri).radians / (Comet.k / (a * a * a).squareRoot())
        let earth = Comet(name: "Earth", perihelionJD: 2_451_545 - daysSincePerihelion, q: a * (1 - e), e: e,
                          argumentOfPerihelion: peri, node: 0, inclination: 0)
        let reference = SolarSystemBody.Planet.earth.heliocentric(jdTT: 2_451_545 + 100)
        // The planet theory's rates drift a little in 100 days; within 20″ is the same orbit.
        #expect(angularSeparation(earth.heliocentric(jdTT: 2_451_545 + 100), reference) * 3600 < 20)
    }

    @Test func nearParabolicOrbitsAgree() {
        // e just below, at and just above 1 give nearly the same place 50 days out.
        func place(_ e: Double) -> (Double, Double) { Comet.orbitalPlane(q: 0.5, e: e, days: 50) }
        let below = place(0.9999), at = place(1), above = place(1.0001)
        #expect(abs(below.0 - at.0) < 1e-3 && abs(above.0 - at.0) < 1e-3)
        #expect(abs(below.1 - at.1) < 1e-3 && abs(above.1 - at.1) < 1e-3)
        // A parabola at perihelion is at q on the x axis.
        #expect(Comet.orbitalPlane(q: 0.5, e: 1, days: 0) == (0.5, 0))
    }

    @Test func hyperbolaKeepsItsEnergy() {
        // Vis-viva: v² = k²(2/r + 1/a) for a hyperbola, by central difference.
        let q = 0.4, e = 1.3, a = q / (e - 1)
        let p0 = Comet.orbitalPlane(q: q, e: e, days: 99.995), p1 = Comet.orbitalPlane(q: q, e: e, days: 100.005)
        let mid = Comet.orbitalPlane(q: q, e: e, days: 100)
        let v = hypot(p1.0 - p0.0, p1.1 - p0.1) / 0.01
        let r = hypot(mid.0, mid.1)
        #expect(abs(v * v - Comet.k * Comet.k * (2 / r + 1 / a)) / (v * v) < 1e-6)
    }

    @Test func magnitudeAndRecentring() throws {
        let c = try comet("161P")
        let m = try #require(c.apparentMagnitude(time))
        // 8.5 + 5 log 0.9244 + 15 log 1.3166.
        #expect(abs(m - 10.12) < 0.02)
        let interval = c.recentreInterval(time)
        #expect((60...900).contains(interval))
        // About 105″ an hour: 30″ takes about 17 minutes, held to 15.
        #expect(interval == 900)
        #expect(try comet("P/2026 R2").recentreInterval(time, arcseconds: 10) < 900)
    }
}

@Suite struct DeepSkyTests {
    @Test func catalogues() throws {
        #expect(DeepSky.messier.map(\.id) == (1...110).map { "M\($0)" })
        #expect(DeepSky.caldwell.map(\.id) == (1...109).map { "C\($0)" })
        let m31 = try #require(DeepSky.object("M31"))
        #expect(m31.name == "M31 Andromeda Galaxy" && m31.kind == .galaxy && m31.constellation == "And")
        #expect(DeepSky.object("M102")?.designation == "NGC 5866")
        #expect(NamedStars.all.count > 200)
        #expect(NamedStars.star("Albireo")?.designation == "β Cyg")
        // Every alignment star is in the named list too.
        for s in BrightStars.all { #expect(NamedStars.star(s.name) != nil) }
    }

    @Test func ngcAndIC() throws {
        #expect(DeepSky.ngc.count > 7_500 && DeepSky.ic.count > 4_500)
        let ngc224 = try #require(DeepSky.object("NGC 224"))
        #expect(ngc224.alsoKnownAs == "M31" && ngc224.name == "NGC 224 Andromeda Galaxy")
        #expect(DeepSky.object("IC 434")?.kind == .nebula)
        #expect(DeepSky.normalisedID("ngc891") == "NGC 891")
        #expect(DeepSky.normalisedID("m 13") == "M13")
        #expect(DeepSky.normalisedID("Ic 434") == "IC 434")
        #expect(DeepSky.normalisedID("Vega") == nil)
    }

    @Test func precessesToDate() throws {
        // M31 on 1 Nov 2026, 26.83 years on: the annual rates (Δα = m + n sin α tan δ, Δδ = n cos α,
        // m = 46.12″, n = 20.04″) give 11.053°, 41.416°.
        let m31 = try #require(DeepSky.object("M31"))
        let date = AstroTime(Date(timeIntervalSince1970: 1_793_491_200))
        let s = m31.equatorialOfDate(date).spherical
        #expect(abs(s.longitude - 11.053) < 0.003 && abs(s.latitude - 41.416) < 0.003)
    }
}
