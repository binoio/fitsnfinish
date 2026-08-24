## FITS n' Finish 0.4.4

- **Get Info window (⌘I).** A new inspector shows the loaded image's
  geometry, bit depth, astrometric pointing, pixel scale and field of view,
  instrument details, and the complete raw header with keyword search — plus
  a one-click copyable summary.
- **Reorganized control panel.** Telemetry and tuning controls are grouped
  into collapsible sections — Site & Pointing, Atmosphere & Sky Glow,
  Gradient Engine, and Display Preview — with draggable angle dials for
  altitude, azimuth, rotation, and light-dome heading.
- **Operations menu.** Remove/Recompute Gradients is now available from the
  menu bar (⌘↩) as well as the panel button.
- **64-bit integer FITS.** BITPIX 64 images now decode, completing coverage
  of every bit depth in the FITS standard (8/16/32/64-bit integer,
  32/64-bit float).
