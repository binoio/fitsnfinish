## FITS n' Finish 0.3.0

- **Rig + site presets.** Save the current telemetry and engine settings
  under a name and apply them with one tap. Presets are managed in Settings
  (⌘, on the Mac; the gear button on iPhone and iPad).
- **Every fpack compression mode now opens.** Added subtractive-dither
  quantization, HCOMPRESS, and PLIO tiles — alongside the existing RICE and
  GZIP support, every standard tile-compressed FITS file now decodes,
  bit-for-bit identical to the reference decoder.
- **Multi-extension FITS.** Files that store the image in an extension
  behind an empty primary header now open normally.
- **Plate solutions survive export.** WCS and provenance headers (CTYPE,
  CRVAL, CRPIX, CD/PC matrices, OBJECT, DATE-OBS, and friends) are copied
  from the source file into exported FITS files.
