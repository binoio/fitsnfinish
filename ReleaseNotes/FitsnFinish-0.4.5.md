## FITS n' Finish 0.4.5

- **Fixed: crash on launch.** 0.4.4 aborted immediately on open when
  installed anywhere but the machine that built it. The Metal shader was
  being located through an absolute build-directory path instead of the app
  bundle; the app now finds its resources relative to wherever the `.app`
  lives (`~/Applications`, `/Applications`, or elsewhere) and falls back to
  the CPU pipeline rather than crashing if they are ever missing.
