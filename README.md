# Overpass

Satellite, Sun, Moon and planet tracking for iOptron strain-wave mounts (HAZ/HAE) on iOS and macOS. A native replacement for Windows-only satellite trackers.

**Status:** early. The app shows the sky, passes, TLE sources and settings. Mount control and alignment screens are not built yet, and nothing has been tested against real hardware.

## Packages

- **IOptronKit:** iOptron *Special Mode* protocol (`:ZZZ#`, per-axis rate `:M0/:M1`, position `:P0/:P1`, slew, sync) and a transport-agnostic `MountClient`. See [docs/iOptron-Special-Mode-Protocol.md](docs/iOptron-Special-Mode-Protocol.md).
- **SkyKit:**
  - SGP4/SDP4 satellite prediction (via [SatelliteKit](https://github.com/gavineadie/SatelliteKit)) with WGS84 topocentric conversion.
  - Sun, Moon and planets (Meeus; JPL/Standish elements) and a bright-star catalogue.
  - Pass prediction with horizon masks and filters (visibility, altitude, duration, sector, Sun separation, mount speed).
  - Mount trajectory planning: a cable stop that is never crossed, over-the-top flip, and rate limiting around the zenith.
  - Star alignment: azimuth zero, tilt, altitude offset and axis direction.
  - TLE database management (CelesTrak groups, URLs, local files; cached, with refresh).

## Connecting to the mount

Special Mode works only over the mount's USB port. On a Mac, use USB serial directly (115200 baud). An iPhone or iPad needs a relay on the mount's USB port, such as a Raspberry Pi Zero 2 W running `ser2net`, reached over TCP.

## Building the app

The Xcode project is generated from `project.yml` and is not committed:

```sh
xcodegen
open Overpass.xcodeproj
```

The app has one multiplatform target (iOS 17+, macOS 14+). It signs with team HG979YFABK and bundle ID `com.djsincla.overpass`.

## Testing

```sh
swift test
```

Ephemerides are checked against worked examples in Meeus's *Astronomical Algorithms*, and SGP4 against Vallado's verification case.
