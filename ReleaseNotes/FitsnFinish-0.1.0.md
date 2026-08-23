## FITS n' Finish 0.1.0

Initial release.

- Hybrid two-stage gradient removal: a deterministic Rayleigh/Mie atmospheric
  prior driven by telemetry removes the non-linear airmass baseline, then a
  low-order (1st/2nd degree) LAPACK polynomial surface cleans residual light
  domes — without scooping faint extended targets.
- FITS reader/writer: 8/16/32/−32/−64-bit, big-endian, BZERO/BSCALE, and
  NAXIS=3 color cubes (smart-telescope RGB stacks) processed per channel.
- Metal preview with per-channel MTF stretch; GPU subtraction kernel with CPU
  reference fallback.
- Telemetry from CoreLocation and WeatherKit with manual entry fallback.
- 16-bit FITS export of the processed frame.
- Sparkle auto-updates.
