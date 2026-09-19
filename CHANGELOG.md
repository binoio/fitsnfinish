# Changelog

Release notes for each version. The HTML twins under `ReleaseNotes/` are
embedded into the Sparkle appcast by `Scripts/release.sh`, so this content is
what users see in the in-app update dialog.

## 0.4.5 — 2026-09-18

- **Fixed: crash on launch.** 0.4.4 aborted immediately on open when
  installed anywhere but the machine that built it. The Metal shader was
  being located through an absolute build-directory path instead of the app
  bundle; the app now finds its resources relative to wherever the `.app`
  lives (`~/Applications`, `/Applications`, or elsewhere) and falls back to
  the CPU pipeline rather than crashing if they are ever missing.

## 0.4.4 — 2026-08-23

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

## 0.4.3 — 2026-08-23

- **macOS Location prompt & entitlements.** Embedded location entitlements
  into the signed Developer ID app bundle, added all location description keys
  to Info.plist, and ignored transient location acquisition errors to allow
  the macOS system authorization dialog to display.

## 0.4.2 — 2026-08-23

- **macOS Location prompt trigger.** Fixed macOS CoreLocation flow to
  explicitly trigger the system authorization dialog and location updates
  via `startUpdatingLocation()`.

## 0.4.1 — 2026-08-23

- **CoreLocation authorization on macOS.** Fixed an issue where clicking
  "Use live telemetry" on macOS failed to request location permissions,
  leaving coordinates at zero. Added macOS CoreLocation authorization handling
  and location entitlements.

## 0.4.0 — 2026-08-23

- **The physics now reads the sky from your file.** Pointing, field of
  view, and field rotation come straight from the image header (WCS plate
  solutions, RA/Dec cards, capture time, optics) — no more manual
  altitude/azimuth entry when the file knows better. Toggleable in the
  telemetry panel.
- **Moonlight modeling.** Built-in solar and lunar ephemerides compute the
  moon's position and phase for the capture time and add a
  Krisciunas–Schaefer scattering term to the prior — the largest natural
  gradient source after airmass.
- **Directional light domes.** Point the model at your nearest city: a
  Garstang-style glow term on a chosen azimuth, saved with presets.
- **Long exposures are modeled across time.** With coordinates and an
  exposure duration, the prior averages the sky as the target and moon
  move during the integration.
- **Preset files from the File menu.** File ▸ Import Preset applies a
  preset file directly (and adds it to the library); File ▸ Export
  Settings as Preset writes the current setup — no library window needed.
- **File ▸ New Window is back**, and the Preset Library appears once in
  the Window menu.
- **Inspect what was subtracted.** A view picker switches between the
  Original, the Physical model, the fitted Surface, and the Result — the
  actual per-channel surfaces from the last run.
- **Sharper spectral modeling.** Optical depths are integrated across the
  filter passband, and the Ångström aerosol exponent is now a visible,
  preset-savable parameter.
- **XISF files open natively** (PixInsight/Siril format): integer and
  float samples, compressed blocks, embedded plate solutions honored.
  A Siril/PixInsight workflow guide ships with the docs.
- **`fnfin` command-line tool.** The same engine, headless:
  `fnfin process --preset site.json *.fit`. Install with
  `brew install mabino/tap/fnfin` or build from source.
- **iPhone and iPad**: open stacks straight from the Files app and share
  processed FITS files from the share sheet.
- **Project page** at https://mabino.github.io/fitsnfinish/.

## 0.3.1 — 2026-08-23

- **Preset Library.** Preset management moved out of Settings into its own
  Preset Library window (Window menu or ⇧⌘P on the Mac; the library button
  on iPhone and iPad), with inline renaming and JSON import/export for
  sharing presets between machines. Settings now holds app information
  only.
- **Standard undo.** The undo/redo buttons are gone; processing steps sit
  on the system undo stack — Edit ▸ Undo/Redo (⌘Z/⇧⌘Z) on the Mac, and the
  usual three-finger tap or shake gestures on iOS.

## 0.3.0 — 2026-08-23

- **Rig + site presets.** Save the current telemetry and engine settings
  under a name and apply them with one tap. Presets are managed in
  Settings (⌘, on the Mac; the gear button on iPhone and iPad).
- **Every fpack compression mode now opens.** Added subtractive-dither
  quantization, HCOMPRESS, and PLIO tiles — alongside the existing RICE
  and GZIP support, every standard tile-compressed FITS file now decodes,
  bit-for-bit identical to the reference decoder.
- **Multi-extension FITS.** Files that store the image in an extension
  behind an empty primary header now open normally.
- **Plate solutions survive export.** WCS and provenance headers (CTYPE,
  CRVAL, CRPIX, CD/PC matrices, OBJECT, DATE-OBS, and friends) are copied
  from the source file into exported FITS files.

## 0.2.0 — 2026-08-23

- **Bright-star masking and sigma-clipped fitting.** Pixels above a robust
  sigma threshold are excluded from background samples, star-dominated cells
  and a halo ring around them are dropped, and the surface fit iterates with
  sigma clipping — halos around saturated stars can no longer tilt the fit.
- **Per-channel atmospheric physics.** Color images now run the Rayleigh/Mie
  model per channel with R/G/B band wavelengths, so the blue channel's much
  steeper λ⁻⁴ skyglow curve is modeled instead of averaged away.
- **Undo and redo of processing runs.** Step back and forth through this
  session's results with ⌥⌘Z / ⌥⇧⌘Z or the panel buttons; the original frame
  is always preserved.
- **Whole pipeline on the GPU.** Prior render, background sampling, surface
  render, and the final blend all run as Metal compute kernels (verified
  identical to the CPU reference, roughly twice as fast); machines without
  Metal fall back to the CPU path automatically.
- **Compressed FITS support.** Tile-compressed (fpack) files open natively:
  RICE and GZIP tiles, integer and floating-point data, undithered
  quantization, and color cubes.

## 0.1.1 — 2026-08-23

- The app detects on launch when it is running outside the Applications
  folder (e.g. straight from Downloads, where updates cannot install) and
  offers to move itself to Applications and relaunch.

## 0.1.0 — 2026-08-23

- Initial release: hybrid physics + low-order-polynomial gradient removal,
  FITS reader/writer with color-cube support, Metal preview with MTF
  stretch, telemetry integration, and Sparkle auto-updates.
