<p align="center"><img src="docs/images/icon.png" width="128" alt="Overpass app icon"></p>

<h1 align="center">Overpass</h1>

<p align="center">Version 0.1.0 &nbsp;·&nbsp; macOS 14 and iOS 17 &nbsp;·&nbsp; iOptron HAZ and HAE mounts</p>

<p align="center"><a href="https://djsincla.github.io/Overpass/">djsincla.github.io/Overpass</a></p>

For the longest time I have been running Heavenscape SkyTrack on a Windows laptop to drive my iOptron strain-wave mounts. It works, but it meant keeping a Windows machine alive for one job, and that machine was always the one that wanted an update on a clear night. Overpass is the native macOS and iOS replacement: it predicts satellite passes from TLEs, tracks satellites, the Sun, the Moon, planets and bright stars, and drives a HAZ or HAE mount over WiFi or USB.

![Overpass on a Mac, Smooth tracking EYESAT A (AO-27) on a HAZ46](docs/images/observe.png)

## What it does

**Passes.** SGP4 prediction from CelesTrak groups, your own URLs or local TLE files, with the age of each source's elements shown so you know when to refresh. Filter by peak elevation, duration, visibility, distance from the Sun and whether the mount can actually keep up. A time bar moves the sky and the pass list up to two days either way, and the mount follows it if you start tracking while it is moved, which is a reasonable way to rehearse a pass in daylight.

**Tracking.** Three modes, depending on how you are connected:

- **Passive** (WiFi): one goto, then the mount's own sidereal, lunar or solar rate. Fine for the Moon, planets and geostationary satellites.
- **Step** (WiFi): a goto to where the target will be, repeated every couple of seconds. This is what I used for amateur radio passes for years, and it is fine for an antenna and jumpy in a telescope.
- **Smooth** (USB): both axis rates varied about seven times a second against a planned track. On a HAZ46 it settles to a median error of about 2″.

**Cable stop.** Set the azimuth the mount must never rotate through and Overpass plans every slew and pass around it, going the long way round when it has to. Over-the-top flips are there for passes close to the zenith.

**Conjunctions.** Space station transits of the Moon and Sun around any place you choose, out to two weeks, drawn on a map with the band where the transit is visible and the time along its centreline. Watch an event and the app refreshes the station elements and recalculates it as the day gets closer, showing how far it moved.

**Also included.** A pass calculator out to fourteen days for any object, star alignment, camera guiding with an iPhone through Continuity Camera, and a red night-vision mode.

## Connecting to the mount

WiFi uses iOptron's normal command set on the mount's own network (10.10.100.254, port 8899 by default) and gives you Passive and Step tracking.

USB uses iOptron's Special Mode, which only works over the USB port, and gives you Smooth tracking. On a Mac the HAZ46 cable appears as `/dev/cu.PL2303G-USBtoUART210` through Prolific's driver. An iPhone or iPad needs a relay on the mount's USB port, such as a Raspberry Pi Zero 2 W running `ser2net`, reached over TCP.

Be aware that the mount stays in Special Mode across power cycles, and WiFi does not work while it is in it. Leave "Leave Special mode when disconnecting" turned on, unless you enjoy wondering why the WiFi stopped working.

## What I found out about the HAZ46

iOptron's Special Mode documentation stops short of a few things that matter, so this is what the mount actually does:

- P0 reads azimuth minus 180°, so its zero faces south, and P1 reads the zenith distance, so it counts down as the tube rises. I found this out when a satellite approaching the horizon had the tube pointing straight up.
- After the mount has been in Special Mode, `:GAC#` in Normal mode reads az 0°, alt 0° until the mount is aligned again, so it cannot be used to calibrate the Special Mode axes.
- After `:ZZZ#` the mount says nothing for about a second while it changes modes, and anything asked in that second times out.
- Every 5 seconds it answers a position request about 15 ms late. At satellite speeds that looks like a 10 to 20″ tracking error if you trust the timestamp of the reply.

The full command set and these notes are in [docs/iOptron-Special-Mode-Protocol.md](docs/iOptron-Special-Mode-Protocol.md).

## Accuracy

Satellite positions come from SGP4 through [SatelliteKit](https://github.com/gavineadie/SatelliteKit), with one correction. SatelliteKit 2.1.2 reads the exponent of the TLE drag term (B*) as a character code, so every satellite had its drag set to about 10⁻⁵², and low orbits ran late by roughly 0.6 s a day after epoch and 200 s after two weeks. That explained a few things. Overpass now reads the TLE columns itself and hands SatelliteKit the right value. The bug is reported upstream as [SatelliteKit #16](https://github.com/gavineadie/SatelliteKit/issues/16), with a one-line fix in [#17](https://github.com/gavineadie/SatelliteKit/pull/17).

I checked the results against two independent sources:

- The reference SGP4 (Vallado's code, as used by Skyfield): positions agree within 10 m for Vanguard 1 and for the ISS a week after its epoch.
- [transit-finder.com](https://transit-finder.com): fourteen ISS and Tiangong transits around Griffith Observatory over two weeks, from the same TLEs, agree within 0.13 s in time, 0.5 km in centreline position and 4% in band width.

Sun, Moon and planet positions follow Meeus's *Astronomical Algorithms* and are checked against his worked examples. None of this makes a TLE more accurate than it is; ISS reboosts move events by seconds, which is why watched conjunctions refresh their elements.

## Status

Tested on a HAZ46: the WiFi connection, Passive tracking of the Moon, Step tracking, USB Special Mode and Smooth tracking at about 2″. Not yet tested on hardware: the iOS build, the USB relay, camera guiding, the route around the cable stop, and the fix for the 5 second timing glitch, which I ran out of battery before trying.

## Building

The Xcode project is generated from `project.yml` and is not committed:

```sh
xcodegen
open Overpass.xcodeproj
```

The app is one multiplatform target (iOS 17+, macOS 14+), signed with team HG979YFABK as `com.djsincla.overpass`. The version is `MARKETING_VERSION` in `project.yml`, with the build number in `CURRENT_PROJECT_VERSION`, and it shows under Settings → About.

## Testing

```sh
swift test
```

126 tests covering the mount protocols, ephemerides, SGP4 against the reference, pass prediction, the mount planner and cable stop, alignment, and the conjunction geometry.

## Version history

**0.1.0**, 24 October 2026. First version: pass prediction and filtering, Passive, Step and Smooth tracking, the cable stop, star and mount alignment, the time bar, the pass calculator, conjunctions, camera guiding and night vision, tested on a HAZ46.

## Licence

Overpass is released under the [Apache License 2.0](LICENSE). It uses [SatelliteKit](https://github.com/gavineadie/SatelliteKit) by Gavin Eadie under the MIT License; see [NOTICE](NOTICE).

Nothing here is supported by iOptron, and a mount that slews into its own tripod is still your problem. Read the cable stop section of the settings before you trust it with your cabling.
