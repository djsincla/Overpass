import Foundation
import Testing
@testable import SkyKit

/// The rotation for a phone held upright (portrait, no roll) with its back camera on `aim`.
private func rotation(aim: Horizontal) -> [[Double]] {
    let f = PhoneSkyProjection.skyVector(aim)
    let r = PhoneSkyProjection.skyVector(Horizontal(azimuth: aim.azimuth + 90, altitude: 0))
    // Up on the screen is right × forward.
    let u = (r.1 * f.2 - r.2 * f.1, r.2 * f.0 - r.0 * f.2, r.0 * f.1 - r.1 * f.0)
    return [[r.0, r.1, r.2], [u.0, u.1, u.2], [-f.0, -f.1, -f.2]]
}

@Suite struct PhoneSkyTests {
    let size = (w: 390.0, h: 844.0)

    func projection(_ aim: Horizontal, _ orientation: PhoneSkyProjection.Orientation = .portrait) -> PhoneSkyProjection {
        PhoneSkyProjection(rotation: rotation(aim: aim), focal: PhoneSkyProjection.focal(longSide: size.h, fieldOfView: 60),
                           width: size.w, height: size.h, orientation: orientation)
    }

    @Test func aimIsTheCentre() throws {
        let aim = Horizontal(azimuth: 120, altitude: 35)
        let p = try #require(projection(aim).point(aim))
        #expect(abs(p.x - size.w / 2) < 1e-6 && abs(p.y - size.h / 2) < 1e-6)
        let c = projection(aim).centre
        #expect(abs(c.azimuth - 120) < 1e-9 && abs(c.altitude - 35) < 1e-9)
    }

    /// Held level with the picture slid down a sixth of the screen, the horizon sits a third of the
    /// way up, and everything else moves the same amount.
    @Test func shiftedDownTheHorizonIsLower() throws {
        let aim = Horizontal(azimuth: 200, altitude: 0)
        var sky = projection(aim)
        let before = try #require(sky.point(Horizontal(azimuth: 205, altitude: 12)))
        sky.verticalShift = size.h / 6
        let horizon = try #require(sky.point(aim))
        #expect(abs(horizon.y - size.h * 2 / 3) < 1e-6 && abs(horizon.x - size.w / 2) < 1e-6)
        #expect(sky.opticalCentre.y == horizon.y)
        let after = try #require(sky.point(Horizontal(azimuth: 205, altitude: 12)))
        #expect(abs(after.y - before.y - size.h / 6) < 1e-6 && abs(after.x - before.x) < 1e-6)
    }

    @Test func eastIsRightAndHigherIsUp() throws {
        let sky = projection(Horizontal(azimuth: 0, altitude: 0))
        let right = try #require(sky.point(Horizontal(azimuth: 10, altitude: 0)))
        let up = try #require(sky.point(Horizontal(azimuth: 0, altitude: 10)))
        #expect(right.x > size.w / 2 && abs(right.y - size.h / 2) < 1e-6)
        #expect(up.y < size.h / 2 && abs(up.x - size.w / 2) < 1e-6)
        // 10° off centre is tan(10°) of the focal length away.
        let focal = PhoneSkyProjection.focal(longSide: size.h, fieldOfView: 60)
        #expect(abs(right.x - size.w / 2 - focal * tan(10.0.radians)) < 1e-6)
    }

    @Test func behindTheCameraIsntDrawn() {
        let sky = projection(Horizontal(azimuth: 0, altitude: 0))
        #expect(sky.point(Horizontal(azimuth: 180, altitude: 0)) == nil)
        // Directly behind and a bit to the east: turn right.
        let turn = sky.turn(towards: Horizontal(azimuth: 150, altitude: 0))
        #expect(abs(turn) < 0.01)
    }

    @Test func landscapeTurnsTheScreen() throws {
        // Device top to the left (landscape right): higher in the sky is still up on screen.
        let sky = PhoneSkyProjection(rotation: landscapeRotation(), focal: 400, width: size.h, height: size.w, orientation: .landscapeRight)
        let up = try #require(sky.point(Horizontal(azimuth: 0, altitude: 10)))
        let right = try #require(sky.point(Horizontal(azimuth: 10, altitude: 0)))
        #expect(up.y < size.w / 2 && abs(up.x - size.h / 2) < 1e-6)
        #expect(right.x > size.h / 2)
    }

    /// Camera north at the horizon with the device's top pointing west (to the left).
    private func landscapeRotation() -> [[Double]] {
        // Device x (right side of the phone) points up, y (top) points west, z back towards you (south).
        [[0, 0, 1], [0, 1, 0], [-1, 0, 0]]
    }
}

@Suite struct ScreenToSkyTests {
    @Test(arguments: [PhoneSkyProjection.Orientation.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight])
    func screenPointsTurnBackIntoTheSky(orientation: PhoneSkyProjection.Orientation) throws {
        let aim = Horizontal(azimuth: 200, altitude: 40)
        let f = PhoneSkyProjection.skyVector(aim)
        let r = PhoneSkyProjection.skyVector(Horizontal(azimuth: aim.azimuth + 90, altitude: 0))
        let u = (r.1 * f.2 - r.2 * f.1, r.2 * f.0 - r.0 * f.2, r.0 * f.1 - r.1 * f.0)
        let sky = PhoneSkyProjection(rotation: [[r.0, r.1, r.2], [u.0, u.1, u.2], [-f.0, -f.1, -f.2]],
                                     focal: PhoneSkyProjection.focal(longSide: 844, fieldOfView: 60),
                                     width: 390, height: 844, orientation: orientation, verticalShift: 30)
        for h in [aim, Horizontal(azimuth: 215, altitude: 52), Horizontal(azimuth: 188, altitude: 31)] {
            let p = try #require(sky.point(h))
            let back = sky.horizontal(atX: p.x, y: p.y)
            #expect(angularSeparation(back.unitVector, h.unitVector) < 1e-6)
        }
    }
}

@Suite struct SatelliteIdentifierTests {
    let observer = Observer(latitude: 40, longitude: -75)

    @Test func findsTheISSAndUsesItsDirection() throws {
        let iss = TLEParser.parse(issTLE)[0]
        let pass = try #require(try PassPredictor(observer: observer).passes(of: iss, from: iss.epoch, to: iss.epoch + 2 * 86_400)
            .first { !$0.truncated && $0.maxAltitude > 30 })
        let date = pass.culmination.date
        let here = try observer.look(at: iss, AstroTime(date))
        let later = try observer.look(at: iss, AstroTime(date + 2))
        // Pointed 3° off, the ISS is the best match.
        let aim = Horizontal(azimuth: here.azimuth + 3 / cos(here.altitude.radians), altitude: here.altitude)
        let tapped = SatelliteIdentifier.candidates(among: [iss], observer: observer, at: date, pointedAt: aim)
        #expect(tapped.first?.satellite.noradID == iss.noradID)
        #expect(abs((tapped.first?.offset ?? 0) - 3) < 0.2 && tapped.first?.directionError == nil)

        // A swipe along its path agrees; one against it doesn't.
        let along = SatelliteIdentifier.candidates(among: [iss], observer: observer, at: date, pointedAt: here, towards: later)
        #expect((along.first?.directionError ?? 180) < 2)
        let against = SatelliteIdentifier.candidates(among: [iss], observer: observer, at: date, pointedAt: later, towards: here)
        #expect((against.first?.directionError ?? 0) > 170)
        #expect((against.first?.score ?? 0) > (along.first?.score ?? 0))
    }

    @Test func slowMoversArentDots() throws {
        // XMM-Newton near apogee crawls at about 0.004°/s: not something seen moving.
        let xmm = try SatelliteTarget(name: "XMM-NEWTON",
            line1: "1 25989U 99066A   26297.00284216  .00000152  00000+0  00000+0 0  9998",
            line2: "2 25989  63.8201 281.3207 4642884  62.5830   0.1940  0.50123653 23653")
        let observer = Observer(latitude: 35.36, longitude: -120.84)
        let date = Date(timeIntervalSince1970: 1_793_520_000)
        let here = try observer.look(at: xmm, AstroTime(date))
        #expect(here.altitude > 0)
        #expect(SatelliteIdentifier.candidates(among: [xmm], observer: observer, at: date, pointedAt: here).isEmpty)
        #expect(SatelliteIdentifier.candidates(among: [xmm], observer: observer, at: date, pointedAt: here, minimumRate: 0).count == 1)
    }

    @Test func nothingFarAwayOrBelowTheHorizon() throws {
        let iss = TLEParser.parse(issTLE)[0]
        let here = try observer.look(at: iss, AstroTime(iss.epoch))
        let opposite = Horizontal(azimuth: here.azimuth + 180, altitude: max(10, -here.altitude))
        #expect(SatelliteIdentifier.candidates(among: [iss], observer: observer, at: iss.epoch, pointedAt: opposite, radius: 15).isEmpty)
    }
}
