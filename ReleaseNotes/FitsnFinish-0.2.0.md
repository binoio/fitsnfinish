## FITS n' Finish 0.2.0

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
