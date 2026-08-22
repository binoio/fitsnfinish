# Roadmap

Where FITS n' Finish is headed, roughly in priority order. Items are scoped
so each can land independently; none change the core promise — deterministic
physics first, low-order statistics second, faint flux preserved always.

## 1.x — Solidify the core

- **Star masking in the surface fitter.** Cell medians already resist point
  sources; add sigma-clipped iteration and an explicit bright-star mask so
  large halos near saturated stars cannot tilt the low-order fit.
- **Per-channel telemetry wavelengths.** Color cubes currently share one
  effective wavelength; drive the Rayleigh/Mie model with per-channel bands
  (R/G/B or narrowband presets) for a physically correct color gradient.
- **Undo history and parameter presets.** Session-scoped undo of processing
  runs; named presets for rig + site combinations.
- **Metal end-to-end.** The prior render and cell-median sampling still run
  on CPU; move both into compute kernels so megapixel-class frames process
  entirely on GPU.
- **Broader FITS coverage.** Compressed FITS (RICE/GZIP tiles), multi-HDU
  files, and WCS header passthrough on export.

## 2.x — Smarter physics

- **Plate solving for automatic pointing.** Replace manual altitude/azimuth
  entry with an on-device plate solve (or ASTAP/astrometry.net integration),
  so field orientation and per-pixel altitude come from the image itself.
- **Moonlight model.** Add lunar position and phase to the scattering prior —
  the largest natural gradient source after airmass.
- **Light-pollution atlas prior.** Blend a world atlas of artificial sky
  brightness into the model so urban light domes get directional treatment
  instead of relying on the polynomial stage.
- **Time-resolved gradients.** For live-stacking workflows, evolve the prior
  across a session as the target's altitude changes.

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
