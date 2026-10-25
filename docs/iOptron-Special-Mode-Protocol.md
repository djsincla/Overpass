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
- What the axis zero points mean is **not** stated by iOptron. Measured on a HAZ46 (24 Oct 2026, pointed at the Moon at az 121.9°, alt 51.5°, reading P0 −58.77°, P1 +39.04°):
  - **P0 = azimuth − 180°** (zero facing south), increasing clockwise like azimuth.
  - **P1 = zenith distance** (zero with the tube vertical; +90° at the horizon), so it counts *down* as the tube rises.
- After the mount has been in Special mode, the Normal-mode position (`:GAC#`) reads az 0, alt 0 until it's aligned again, so it can't be used to calibrate the Special-mode axes.
- Switching modes loses the position in both directions (seen 25 Oct 2026): leaving Special mode, Normal mode reads az 0, alt 0, and entering Special mode again starts the axes from that. Overpass keeps its own record of where the tube points and, after each switch, syncs the mount to it: `:S0`/`:S1` entering Special mode, `:Sas`/`:Sz` + `:CM#` leaving it.
- `:T0#` on a HAZ46 (measured 25 Oct 2026 with the app's slew test):
  - The target is in the same frame as the `:P0#` reading: a slew from −177.77° to −172.77° moved +4.9°.
  - It treats ±180° as two ends, not one point. A slew from −172.77° to +177° (10° the short way, across north on a HAZ) set off the long way round, nearly a full turn.
  - It accepts a slew to within a few degrees of ±180° (reply `1`) and then doesn't move: −172.8° to −177° moved 0.0° in 15 s. Slewing away from ±180° from inside that zone works.
  - Under rate control (`:M0#`/`:M2#`) the axis crosses ±180° without trouble and the reading simply wraps.
  - So: keep `:T0#` targets at least 8° short of ±180°, and cross or finish inside that zone under rate control.

# Normal mode (RS-232 Command Language V3.10, 2021-01-04): relevant parts

Source: https://www.ioptron.com/v/ASCOM/RS-232_Command_Language2014V310.pdf. The document lists CEM/GEM mounts only; HAZ/HAE behaviour still needs confirming. Normal mode is available over WiFi and USB.

- Position: `:GAC#` → `sTTTTTTTTTTTTTTTTT#` (altitude, sign + 8 digits; then azimuth, 9 digits; 0.01″). `:GEP#` gives RA/Dec.
- Alt-az goto: `:SasTTTTTTTT#` (altitude), `:SzTTTTTTTTT#` (azimuth), then `:MSS#` → `1` accepted / `0` below the altitude limit or past mechanical limits. **Tracking stops after an `:MSS#` slew.**
- RA/Dec goto: `:SRATTTTTTTTT#`, `:SdsTTTTTTTT#`, `:MS1#`. **Sidereal tracking starts automatically after `:MS1#`.**
- Tracking rate: `:RT0#` sidereal, `:RT1#` lunar, `:RT2#` solar, `:RT3#` King, `:RT4#` custom (`:RRnnnnn#`, 0.1000–1.9000× sidereal, **RA axis only**). `:ST0#`/`:ST1#` turn tracking off/on.
- Variable speed: `:SRn#` sets **one** arrow-button speed for both axes (1=1×, 2=2×, 3=8×, 4=16×, 5=64×, 6=128×, 7=256×, 8=512×, 9=max sidereal). Move with `:mn#`/`:ms#` (Dec/alt) and `:me#`/`:mw#` (RA/az) until `:qD#`/`:qR#`/`:Q#`.
- Sync: `:CM#` to the last `:Sas`/`:Sz` (alt-az) or `:SRA`/`:Sd` coordinates.
- Time/site: `:SUT…#` (ms since J2000), `:SGsMMM#`, `:SDS0#`/`:SDS1#`, `:SLOsTTTTTTTT#`, `:SLAsTTTTTTTT#`.
- **No commands read, add to or select from the hand controller's object database.**
