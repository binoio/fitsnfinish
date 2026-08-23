## FITS n' Finish 0.4.1

- **CoreLocation authorization on macOS.** Fixed an issue where clicking
  "Use live telemetry" on macOS failed to request location permissions,
  leaving coordinates at zero. Added macOS CoreLocation authorization handling
  and location entitlements.
