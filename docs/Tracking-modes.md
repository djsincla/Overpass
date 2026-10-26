# Passive and Step tracking

Overpass has three ways to follow something across the sky. Smooth needs the USB cable and Special Mode. Passive and Step use iOptron's normal command set, so they work over WiFi or over USB in Normal mode, and they are the two worth understanding before you pick one in the tracking card.

The short version: Passive hands the job to the mount, and Step does the job for the mount. Passive is for anything that moves with the stars. Step is for satellites, when the cable isn't an option.

## Passive

Passive is one goto, after which the mount tracks by itself at one of its built-in rates.

What Overpass sends:

1. An alt-az goto to where the target is now (`:Sa`, `:Sz`, `:MSS#`), at full speed. The mount picks the way round, and it never turns through north.
2. A right ascension and declination goto to the same place (`:SRA`, `:Sd`, `:MS1#`), which by then is only a small correction, followed by the tracking rate (`:RT0#` sidereal, `:RT1#` lunar, `:RT2#` solar).
3. Nothing else, apart from a status check (`:GLS#`) every few seconds. If the mount stops tracking, the tracking card says so and the mount log records it.

The right ascension and declination Overpass sends are topocentric and of date, so they describe the target as seen from your location. For a star that makes no difference. For the Moon it does: parallax moves it by up to about a degree depending on where you stand, and that shift changes as the Moon crosses the sky. So for the Moon only, Overpass sends a fresh RA/Dec goto every five minutes. Between those the mount runs at the lunar rate.

The mount converts RA/Dec into its own axis positions using its clock and location. Overpass sets both when it connects (`:SLO`, `:SLA`, `:SG`, `:SDS0#`, `:SUT`, in UTC with no daylight saving), so a mount that has been sitting in the shed with the wrong time is corrected before the first goto.

Which rate it uses:

| Target | Rate | Notes |
| --- | --- | --- |
| Stars | Sidereal | Exact apart from the mount's own alignment. |
| Planets | Sidereal | Planets drift against the stars by a few arcminutes an hour at most, Mercury and Venus the most. Overpass doesn't re-centre them; press Track again after a long session at high power. |
| Moon | Lunar | Re-centred every 5 minutes for parallax. |
| Sun | Solar | With a full-aperture filter, and Overpass asks before it slews. |
| Geostationary satellites | None | One alt-az goto. A geostationary satellite doesn't move in alt-az, so there is nothing to track. |
| Any other satellite | Not available | The mount has no rate for something that crosses the sky in ten minutes. The tracking card doesn't offer Passive for one. |

Fine tuning in Passive moves the mount itself: each nudge runs the axis at 16× sidereal (about 0.067° a second) for the right time, and the mount's own tracking carries on from the new position.

If WiFi drops, or the phone locks, the mount keeps tracking by itself. That is the main reason to use Passive for anything it can follow.

## Step

Step is a goto to where the target will be, repeated every couple of seconds. Overpass does all the prediction; the mount just goes where it is told. This is how I tracked amateur radio satellites for years, and it is fine for an antenna and jumpy in a telescope.

Before the pass:

1. Overpass works out where the satellite first reaches the start elevation (Settings, Start tracking at, 10° by default) and sends the mount there at full speed.
2. It waits there. The last ten seconds tick down WWV-style, with a tone a minute before, if those sounds are on.

During the pass, every interval (2 s by default, set beside the mode picker):

1. Overpass computes where the satellite will be half an interval plus half a second from now (1.5 s ahead at the default), so the mount arrives near the middle of the interval and the error is shared either side of the satellite.
2. It sends that as an alt-az goto (`:Sa`, `:Sz`, `:MSS#`).
3. It reads the position back once (`:GAC#`), for the sky view and the log, and waits for the next interval.

The result is a staircase. The mount jumps, stops, and waits while the satellite moves on, so the pointing error swings back and forth by roughly the distance the satellite covers in half an interval. Near the horizon, where a low orbit moves at a few tenths of a degree a second, that is a few tenths of a degree. At the top of an overhead pass, where it can move at a degree or more a second, it is a degree or more. An antenna with a beam tens of degrees wide doesn't notice. A telescope with a one-degree field does.

Shorter intervals make smaller steps. The shortest is the Normal mode updates setting (1 s by default), because commands more often than once a second have caused trouble on the HAZ46 in Normal mode.

Fine tuning in Step changes the aim: nudges add to an altitude and azimuth offset, and the time offset moves the aim along the track to make up for an old TLE. They apply from the next step.

When a pass crosses north, the next step would need the mount to turn through north, which it won't do. Overpass stops there and asks whether to go the long way round. If you agree, or have turned on Settings, Unwind at north without asking, it sends the mount the long way round to where the satellite will be when it gets there, about a minute's travel, and carries on stepping. You lose that part of the pass.

If WiFi drops, the mount stays where the last step left it.

## Side by side

| | Passive | Step |
| --- | --- | --- |
| Connection | WiFi or USB Normal mode | WiFi or USB Normal mode |
| Who predicts the target | The mount, from its clock, location and rate | Overpass, every step |
| Commands during tracking | A status check every few seconds; for the Moon, a goto every 5 minutes | An alt-az goto and a position read every interval |
| Motion | Continuous | A jump every interval, then still |
| Targets | Stars, planets, Moon, Sun, geostationary satellites | Anything, including low-orbit satellites |
| Typical error | The mount's alignment, plus slow drift for planets | Up to about half an interval of the target's motion, plus alignment |
| Crossing north | Not yet tested: whether the mount's own tracking turns through north is unknown | Stops and asks, then the long way round |
| If the connection drops | Keeps tracking | Stops at the last step |

Both depend on the mount's own alignment: Passive through its RA/Dec conversion, Step through its alt-az coordinates. If the mount points a degree off on a goto from the hand controller, both modes will be a degree off too. Centre a star or the Moon and press Sync in the tracking card to fix that.

## And Smooth

Smooth needs the USB cable with the mount in Special Mode. Overpass plans the whole pass as an axis trajectory, then sets both axis speeds about seven times a second (faster if you choose), correcting against the mount's own position readings. The motion is continuous and the settled error is a few arcseconds, which is the one to use for a telescope on a satellite. If the app stops talking to the mount, the mount carries on at the last speeds it was given, so Overpass stops it on quit, on disconnect and when an iPhone goes to the background.
