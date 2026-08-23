# Using FITS n' Finish with Siril and PixInsight

FITS n' Finish slots into a linear-data workflow: run it on your stacked,
uncalibrated-background image *before* stretching, then continue in your
usual tool.

## Round trip

1. **Stack** in Siril, PixInsight (WBPP), or your capture software.
2. **Open the stack** in FITS n' Finish — FITS (including fpack-compressed)
   and monolithic **XISF** both open directly; pointing, capture time, and
   pixel scale are read from the header/plate solution.
3. **Remove gradients** (⌘↩). Inspect what each stage subtracted with the
   Physical / Surface view modes.
4. **Export** (⌘E) — a 16-bit FITS with the WCS and provenance cards
   preserved, so plate-solve-dependent steps downstream keep working.

Scripted alternative: `fnfin process --preset mysite.json stack.fits`.

## Compared with ABE / DBE / Siril background extraction

- **ABE (PixInsight)** fits a polynomial to automatically placed samples.
  At degree 4+ it can follow — and remove — broad nebulosity. FITS n'
  Finish never exceeds degree 2, because the atmospheric model has already
  taken out the non-linear part that forces high degrees.
- **DBE (PixInsight)** interpolates between hand-placed samples; excellent
  control, but labor-intensive and sensitive to sample placement over
  faint structure. FITS n' Finish needs no samples: the physics fixes the
  baseline's shape, the median-cell fit handles the leftovers.
- **Siril background extraction** (polynomial or RBF) is fast and good;
  the RBF mode in particular can conform to large structures. The same
  degree-2 argument applies.

A fair comparison: run your usual tool and FITS n' Finish on the same
stack, then blink the results over the faintest extended feature you care
about (IFN, outer halo, faint Hα). The difference shows up there, not in
the background flatness — both will be flat.

## Notes

- XISF: monolithic files, UInt8/16/32 and Float32/64 samples, Gray/RGB,
  planar or interleaved, zlib (optionally byte-shuffled) blocks. Embedded
  `FITSKeyword` metadata (plate solutions included) is honored.
- Export is always FITS. PixInsight and Siril both read it back directly.
