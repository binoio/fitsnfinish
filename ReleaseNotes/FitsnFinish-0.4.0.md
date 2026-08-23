## FITS n' Finish 0.4.0

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
