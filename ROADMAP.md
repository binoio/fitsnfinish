# Roadmap

Where FITS n' Finish is headed, roughly in priority order. Items are scoped
so each can land independently; none change the core promise — deterministic
physics first, low-order statistics second, faint flux preserved always.

## Shipped

- **Star masking in the surface fitter** *(0.2.0)* — bright pixels above a
  robust sigma threshold are excluded from cell medians, star-dominated
  cells and a dilated halo ring around them are dropped, and the fit
  iterates with sigma clipping so saturated-star halos cannot tilt it.
- **Per-channel telemetry wavelengths** *(0.2.0)* — the Rayleigh/Mie model
  runs per channel with R/G/B band wavelengths (0.64/0.53/0.47 µm,
  configurable), so the blue channel gets its physically steeper λ⁻⁴ curve.
- **Session-scoped undo/redo** *(0.2.0)* — processing runs are kept as
  copy-on-write history entries (capped, original always preserved) with
  ⌥⌘Z / ⌥⇧⌘Z and panel buttons.
- **Metal end-to-end** *(0.2.0)* — prior render, masked cell-median
  sampling, surface render, and the final blend all run as compute kernels;
  the CPU keeps only the tiny least-squares solves. Verified bit-identical
  to the CPU reference path.
- **Compressed FITS** *(0.2.0)* — tile-compressed (fpack) files decode
  natively: RICE_1 and GZIP_1/GZIP_2 tiles, 16/32-bit integer and float
  data, undithered quantization, color cubes; validated against
  astropy-generated references.
- **Parameter presets and Settings** *(0.3.0)* — named rig + site presets
  (telemetry plus engine settings) managed in the macOS Settings window /
  iOS settings sheet, with one-tap apply from the controls panel.
- **Complete FITS coverage** *(0.3.0)* — subtractive dithering
  (SUBTRACTIVE_DITHER_1/2 via CFITSIO's portable random sequence),
  HCOMPRESS_1 and PLIO_1 tile decoders ported from the reference sources,
  multi-HDU files (image extensions after an empty primary), and WCS/
  provenance header passthrough on export. All fixture-validated against
  astropy's decoder.

The 1.x core list is complete.

- **Smarter physics** *(0.4.0, the 2.x list)* —
  - *Pointing from the image:* the plate solve the file already carries
    (WCS solution, RA/Dec cards, DATE-OBS, pixel scale from the CD matrix
    or optics cards) populates pointing, field of view, and field rotation
    (north angle + parallactic angle) automatically on open.
  - *Moonlight model:* built-in low-precision solar and lunar ephemerides
    (truncated Meeus series) drive a Krisciunas–Schaefer scattering term
    for the moon's position and phase.
  - *Directional light domes:* a Garstang-style azimuth-dependent glow
    term, set per site and saved in presets. (Bundling the Falchi world
    atlas raster is not redistributable; per-site presets carry the same
    information where it matters.)
  - *Time-resolved gradients:* with equatorial coordinates and an exposure
    duration the prior is averaged over the exposure as the target and
    moon move.

The 2.x smarter-physics list is complete.

## 3.x — Reach

- **iPad and iPhone polish.** Files-app document browser entry point, share
  sheet export, and camera-connect import for smart telescopes.
- **Batch mode.** Headless CLI target (`fitsnfinish process *.fit`) reusing
  the same Core, for integration into stacking pipelines.
- **PixInsight / Siril interop.** XISF read support and a documented
  process-icon workflow comparing results against ABE/DBE.
- **App Store distribution.** Sandboxing, WeatherKit entitlement, TestFlight
  via Xcode Cloud, and the App Store Connect metadata already drafted in
  [fitsnfinish.md](fitsnfinish.md).

## Engineering debt

- Migrate `dgels_` to the ACCELERATE_NEW_LAPACK interface.
- Property-based tests for the FITS parser (fuzz headers and payload sizes).
- Investigate the first-launch Files-picker flash seen once on iOS 26
  simulator.
