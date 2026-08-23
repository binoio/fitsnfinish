# App Store distribution

The App Store build differs from the Developer ID build in three ways:
sandboxed, no Sparkle (the store handles updates), and signed with an Apple
Distribution certificate. Everything needed that can live in the repo does:

- `Support/FitsnFinish-AppStore.entitlements` — sandbox, user-selected
  read/write files, network client, WeatherKit.
- `Support/Info.plist` — usage descriptions and document types already
  present; the WeatherKit capability must also be enabled for the
  `io.bino.fitsnfinish` App ID in the developer portal.
- `ci_scripts/ci_post_clone.sh` — Xcode Cloud hook, already in place.
- App Store Connect metadata — drafted in `fitsnfinish.md`.

Remaining steps are interactive (developer portal / ASC):

1. Register the App ID with the WeatherKit capability; create an Apple
   Distribution certificate and an App Store provisioning profile.
2. Create the app record in App Store Connect with the drafted metadata.
3. Build a Sparkle-free variant (compile out the `Sparkle` product and
   `SUFeedURL`/`SUPublicEDKey` keys), sign with the entitlements above,
   and upload via Xcode Cloud or `xcrun altool`/Transporter.
4. TestFlight, then submit.
