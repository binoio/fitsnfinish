# FITS n' Finish

Hybrid atmospheric gradient subtraction for astrophotography, for macOS and
iOS (the same SwiftUI app layer runs on both; file dialogs, layout, and the
Metal preview adapt per platform).
Instead of chasing skyglow with hundreds of sample boxes or high-order
polynomials, FITS n' Finish removes the background in two stages:

1. **Physics** — a deterministic Rayleigh/Mie scattering model computes the
   non-linear airmass baseline from telemetry (location, target altitude and
   azimuth, humidity, aerosol optical depth) and subtracts it first.
2. **Math** — a low-order (1st/2nd degree) polynomial surface, solved with
   LAPACK least squares over median-sampled cells, cleans up the remaining
   localized light domes and flat-field residuals. Low-order surfaces lack the
   freedom to conform to — and erase — faint extended targets like IFN or
   outer galaxy halos.

The full specification lives in [fitsnfinish.md](fitsnfinish.md); the
future development plan is in [ROADMAP.md](ROADMAP.md).

Color FITS cubes (NAXIS=3, e.g. smart-telescope RGB stacks) are processed
per channel, since skyglow is strongly color-dependent.

## Layout

| Path | Contents |
| --- | --- |
| `App/` | SwiftUI app: document model, Metal preview (`Views/MetalView.swift`), control panel (`Views/ControlsView.swift`), GPU blend engine |
| `Core/FITS/` | FITS header parsing, big-endian 8/16/32/−32/−64-bit decoding, 16-bit writer |
| `Core/Telemetry/` | CoreLocation / CoreMotion / WeatherKit providers behind test-injectable protocols |
| `Core/Physics/` | Kasten–Young airmass, Rayleigh/Mie optical depths, skyglow prior surface |
| `Core/Math/` | LAPACK `dgels_` least squares (portable fallback included), 2-D polynomial fitter |
| `Core/Pipeline/` | The hybrid two-stage engine (CPU reference implementation) |
| `Metal/SubtractEngine.metal` | GPU kernels: gradient subtraction blend, MTF preview stretch |
| `Tests/` | `FITSTests` + `SolverTests` (20 tests, including the 100×100 flat-residual acceptance test) |
| `Scripts/` | zsh build / run / test / notarize scripts, `ExportOptions.plist` |
| `Support/Info.plist` | Bundle metadata, usage descriptions, FITS document type |

## Building and running

```sh
./Scripts/build.sh      # release build → build/FITS n' Finish.app
./Scripts/run.sh        # debug build and launch
./Scripts/run_simulator.sh   # build for iOS Simulator, install, and launch
./Scripts/test.sh       # native test suite
./Scripts/test.sh --docker   # portable core suite in a Linux container
./Scripts/build_and_notarize.sh  # test → build → sign → notarize → staple
```

Notarization needs a Developer ID identity in the keychain and a one-time
`xcrun notarytool store-credentials FF_NOTARY_PROFILE`. Without them the
script stops after ad-hoc signing and says so.

Live telemetry (WeatherKit, CoreLocation) requires the WeatherKit capability
and a provisioned bundle identifier (`io.bino.fitsnfinish`); unsigned dev
builds fall back to manual telemetry entry in the controls panel.

## CI

`.github/workflows/ci.yml` runs the portable core suite in a Linux Swift
container (no macOS runners). Apple-framework code paths (Metal, WeatherKit,
CoreLocation, Accelerate) are guarded by `canImport`/`os` checks and covered
by the native `swift test` run instead. For signed app builds and TestFlight
distribution, connect the repo to Xcode Cloud — `ci_scripts/ci_post_clone.sh`
is already in place.
