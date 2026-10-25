# iOptron Mount Special Mode Command Language (2023-05-08)

Transcribed from https://www.ioptron.com/v/ASCOM/iOptronSpecialRS232Language.pdf

## Axes
- **Primary axis**: RA axis (equatorial) / **azimuth** axis (alt-az).
- **Secondary axis**: Dec axis (equatorial) / **altitude** axis (alt-az).
- Position resolution: 0.01 arcsecond (real accuracy limited by the mount).
- Values are real-time. One send/receive round trip takes about **30 ms**.

## Supported mounts (per document)
| Mount | Regular `:MountInfo#` | Special `:MountInfo#` |
|---|---|---|
| AZ Mount Pro | 5035 | 9035 |
| HAZ31 | 0035 | 8035 |
| HAZ46 | 0052 | 8052 |
| HAE29 (AA mode, limited support) | 0033 / 0034 | 8033 / 8034 |
| HAE43 (AA mode, limited support) | 0050 / 0051 | 8050 / 8051 |

Not listed: HAZ71, HAE16, HAE69, any EQ-mode use. Test these before relying on them.

## Serial
- Baud rate for all models: **115200**

## Switch modes
- `:ZZZ#` toggles between regular and special mode. **The mode is remembered across power cycles.**
- After switching, send `:MountInfo#` to confirm the switch (see table: special mode = leading `8`/`9`).
- All commands below work **only in special mode**.

## Position
Units: 0.01 arcsec. Range: -64,799,799 to 64,800,000 (±180°).

| Command | Response | Meaning |
|---|---|---|
| `:P0#` / `:P1#` | `+nnnnnnnnn#` | Current position of primary / secondary axis. |
| `:P2#` | `+nnnnnnnnn+nnnnnnnnn#` | P0 then P1 combined. **Not supported on HAE in AA mode.** |
| `:S0+nnnnnnnnn#` | `1` | Sync primary axis to value. Use only when axis is stationary. |
| `:S1+nnnnnnnnn#` | `1` | Sync secondary axis to value. Use only when axis is stationary. |

## Motion
Speed units: 0.01 arcsec/second, sign + 7 digits.

| Command | Response | Meaning |
|---|---|---|
| `:M0+nnnnnnn#` | `1` | Set primary axis speed; takes effect immediately. Max for AZ Mount Pro: 8°/s. |
| `:M1+nnnnnnn#` | `1` | Set secondary axis speed; takes effect immediately. Max for AZ Mount Pro: 6°/s. |
| `:M2+nnnnnnn+nnnnnnn#` | `1` | M0 and M1 combined. A char other than `+`/`-` at position 4 or 12 skips that half. **Not supported on HAE in AA mode.** |
| `:Q0#` / `:Q1#` | `+nnnnnnn#` | Current *actual* speed of the axis (it may still be accelerating toward the requested speed). |
| `:T0+nnnnnnnnn#` | `1` | Slew primary axis to position at max speed. |
| `:T1+nnnnnnnnn#` | `1` | Slew secondary axis to position at max speed. |

Examples:
- 5°/s negative on primary: `:M0-1800000#` (5 × 3600 × 100 = 1,800,000).
- `:M2*1234567-0012345#` behaves the same as `:M1-0012345#`.

## Implementation notes (ours, not from the document)
- Stop: there is no separate stop command, so send `:M0+0000000#` and `:M1+0000000#`.
- Sign and 7 digits allow up to 9,999,999 → about 27.7°/s; the real limit is set by the mount.
- The `1` response has **no** trailing `#`, so read exactly one byte.
- With P0+P1+M0+M1 at about 30 ms each, the HAE (no P2/M2) gets about an 8 Hz control loop; the HAZ (with P2/M2) gets about 16 Hz.

## HAZ46 quirks, measured

Everything here was measured on one HAZ46 (MountInfo 0052 / 8052) over USB, with Overpass's mount log, slew test and traces, between 24 and 25 October 2026. None of it is in iOptron's documents. The HAE is untested; run Overpass's "Test the mount's slew" and "Test mode switching" on one before trusting any of this there.

**Axes in Special mode**
- **P0 = azimuth − 180°**: zero faces south, and it increases clockwise like azimuth. Measured on the Moon at az 121.9°, alt 51.5°, reading P0 −58.77°, P1 +39.04°.
- **P1 = zenith distance**: zero with the tube vertical, +90° at the horizon, so it counts down as the tube rises.
- The P0 reading wraps at ±180°, which on a HAZ is due north.

**Switching modes (`:ZZZ#`)**
- The mode survives power cycles, and WiFi doesn't answer while the mount is in Special mode.
- After `:ZZZ#` the mount is silent for about a second; ask `:MountInfo#` again until it answers in the new mode, and never toggle twice.
- The mount keeps its position through a switch, in both directions. Entering Special mode, P0/P1 match the Normal-mode position exactly.
- Leaving Special mode, Normal mode (`:GAC#`) reports a **placeholder** for several seconds: az 0, alt 0 one time, az 180°, alt 90° another. Then it reports the real position again. In one case it was back within 12 s; Overpass waits up to 20 s.
- Normal mode can be tracking sidereal by itself. Stop it (`:ST0#`, `:Q#`) and wait until the readings settle before switching, or the position carried across is already stale.

**Syncing**
- A Normal-mode alt-az sync (`:Sas`/`:Sz` + `:CM#`) sent during the placeholder is **added** to the position the mount kept. Leaving Special mode at az 201.95°, alt 19.21° and syncing to that same position left the mount reading az 43.91°, alt 38.44°, exactly double. So never sync after a switch; there is nothing to fix.
- Whether `:CM#` sets or adds once the real position is back is not yet measured. Overpass reads the position back after every sync and reports a mismatch.
- `:S0#`/`:S1#` (Special-mode axis sync) has not been measured. Overpass's Special-mode sync moves its own alignment zeros instead, and "Set position" reads the axes back to check the mount took the values as positions.

**`:T0#` slews on the azimuth axis**
- The target is in the same frame as the `:P0#` reading: a slew from −177.77° to −172.77° moved +4.9°.
- It treats +180° and −180° as two separate ends. A slew from −172.77° to +177°, 10° the short way across north, set off the long way round, nearly a full turn, and would have wound the cables.
- It accepts a slew to within a few degrees of ±180° (reply `1`) and then doesn't move: −172.8° to −177° moved 0.0° in 15 s. Slewing away from ±180° from inside that zone works.
- Under rate control (`:M0#`/`:M2#`) the axis crosses ±180° without trouble, and the reading wraps.
- So Overpass keeps `:T0#` targets at least 8° short of ±180°, crosses north under rate control at full speed, and finishes any goal inside that zone under rate control. Any native slew that starts heading away from its target is stopped within about a second.

**Timing and tracking**
- One Smooth-tracking update (`:P2#` plus `:M2…#`) takes about 45 ms at 115,200 baud, nearly all of it waiting for the mount to answer, so 0.05 s is about as fast as updates can go.
- Every 5 s or so, one position reply comes about 15 ms late. Timestamping positions at a typical exchange delay, and holding the planned speed through a lone outlier, removed the 10–20″ spikes this caused.
- Settled Smooth tracking has a median error of about 2–3″, which is the mount's own reading noise.
- On the Mac, the USB adapter is a Prolific PL2303G and appears as `/dev/cu.PL2303G-USBtoUART210`.

