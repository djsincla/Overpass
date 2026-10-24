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
- What the axis zero points mean (azimuth 0 = north? altitude 0 = horizon?) is **not** stated. Check on hardware, or sync explicitly with S0/S1 after the mount is aligned.
