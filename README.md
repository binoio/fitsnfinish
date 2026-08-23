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

## The math

Pixel values are normalized to $[0,1]$ from the FITS storage range before any
processing; all fitting below happens in that linear space.

### Stage 1 — the physical prior

**Airmass.** For apparent altitude $h$ (zenith angle $z = 90^\circ - h$), the
relative airmass uses the Kasten–Young (1989) formula, finite all the way to
the horizon ($X(0^\circ)\approx 38$):

$$X(h) = \frac{1}{\cos z + 0.50572\,(96.07995 - z)^{-1.6364}}$$

**Rayleigh scattering.** Molecular optical depth at sea level follows the
Hansen & Travis (1974) approximation, with $\lambda$ in micrometers:

$$\tau_R(\lambda) = \frac{0.008569}{\lambda^4}\left(1 + \frac{0.0113}{\lambda^2} + \frac{0.00013}{\lambda^4}\right)$$

**Aerosol (Mie) scattering.** The Ångström turbidity law with exponent
$\alpha = 1.3$ (continental aerosols), where $\beta$ is the aerosol optical
depth at $1\,\mu m$ taken from telemetry:

$$\tau_M(\lambda) = \beta_{RH}\,\lambda^{-\alpha}$$

Aerosols swell hygroscopically as relative humidity rises, so $\beta$ is
scaled by a Hänel-type growth factor (capped at $RH = 0.97$ so saturated air
stays finite), with $\gamma = 0.25$:

$$\beta_{RH} = \beta\,(1 - RH)^{-\gamma}$$

**Skyglow.** Along a line of sight of airmass $X$ through total optical depth
$\tau = \tau_R + \tau_M$, the single-scattering fraction of ambient light
redirected into the beam is

$$I(h) \propto 1 - e^{-\tau\,X(h)}$$

which grows steeply — and non-linearly — toward the horizon. This is the
curve that forces high-order polynomials in purely statistical tools. The
prior surface assigns each pixel row an altitude from the pointing telemetry
and the field of view, $h(y) = h_0 + \left(\tfrac{y}{H-1} - \tfrac12\right)\mathrm{FOV}_y$,
and evaluates $I$ there.

**Matching the prior to the frame.** The prior is in relative units, so its
amplitude is fitted, not assumed: least-squares fit $a + bP$ against the image
$I$ over all $n$ pixels gives the gain in closed form,

$$b = \frac{n\sum P I - \sum P \sum I}{n\sum P^2 - \left(\sum P\right)^2}$$

and only the mean-centered component $b\,(P - \bar P)$ is subtracted (clamped
at 0), which removes the gradient while preserving the frame's pedestal.
A flat prior yields $b = 0$ — nothing to remove. Sums are accumulated in
double precision; Float32 accumulation measurably biases $b$ on
megapixel frames.

### Stage 2 — the low-order surface

The residual is sampled on a coarse grid using **per-cell medians**, which are
robust to stars and small structures. With coordinates normalized to
$[-1,1]$, the design matrix rows are the monomials

$$\{1,\,x,\,y\} \quad\text{or}\quad \{1,\,x,\,y,\,x^2,\,xy,\,y^2\}$$

and the coefficient vector $c$ solves $\min_c \lVert Ac - m\rVert_2$ via
LAPACK `dgels` (QR factorization; a partially pivoted normal-equations
fallback covers non-Apple platforms). The rendered surface is subtracted
mean-centered and clamped, like the prior.

Degree is deliberately capped at 2: a bivariate polynomial of degree $d$ has
only $\tfrac{(d+1)(d+2)}{2}$ coefficients — 3 or 6 degrees of freedom —
which is mathematically insufficient to conform to structured extended
targets. That is the preservation guarantee: the surface *cannot* scoop out
IFN or galaxy halos because it lacks the freedom to describe them.

Color cubes run both stages per channel, since $\tau(\lambda)$ makes skyglow
color-dependent.

### Display stretch

The preview applies the standard midtone transfer function with midtone
balance $m$ in the fragment shader only — the linear data is never modified:

$$y = \frac{(m-1)\,x}{(2m-1)\,x - m}$$

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

`Scripts/release.sh` cuts a full release: tests, bundle, inside-out Developer
ID codesigning, notarization, EdDSA-signed Sparkle appcast (published to
`docs/appcast.xml`, served by GitHub Pages), git tag, and GitHub Release.
The app checks the appcast for updates via Sparkle.

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
