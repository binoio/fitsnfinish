#!/usr/bin/env zsh
# Test → build → sign → notarize → staple, entirely from the CLI.
#
# Signing/notarization environment (all optional; steps degrade gracefully):
#   FF_SIGN_IDENTITY      codesign identity, default "Developer ID Application"
#   FF_KEYCHAIN_PROFILE   notarytool keychain profile, default FF_NOTARY_PROFILE
#                         (create once with: xcrun notarytool store-credentials)
#
# If an Xcode project (FitsnFinish.xcodeproj) is present, the classic
# xcodebuild archive/export path from the spec is used instead; see
# Scripts/ExportOptions.plist.
set -eo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

SCHEME="FitsnFinish"
BUNDLE_ID="io.bino.fitsnfinish"
SIGN_IDENTITY="${FF_SIGN_IDENTITY:-Developer ID Application}"
KEYCHAIN_PROFILE="${FF_KEYCHAIN_PROFILE:-FF_NOTARY_PROFILE}"
ARCHIVE_PATH="./build/FitsnFinish.xcarchive"
EXPORT_PATH="./build/export"
APP="./build/FITS n' Finish.app"

# 1. Run unit tests via CLI.
if command -v xcbeautify >/dev/null 2>&1; then
  swift test 2>&1 | xcbeautify
else
  swift test
fi

if [[ -d "FitsnFinish.xcodeproj" ]]; then
  # 2a. Archive + export through xcodebuild.
  xcodebuild archive \
    -scheme "$SCHEME" \
    -archivePath "$ARCHIVE_PATH" \
    -destination 'generic/platform=macOS'
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist ./Scripts/ExportOptions.plist \
    -exportPath "$EXPORT_PATH"
  APP="$EXPORT_PATH/FITS n' Finish.app"
else
  # 2b. SwiftPM path: release build + manual bundle assembly.
  ./Scripts/build.sh
fi

# 3. Codesign (hardened runtime, required for notarization). Falls back to
#    ad-hoc signing when no Developer ID identity is available.
if security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
  codesign --force --deep --options runtime \
    --sign "$SIGN_IDENTITY" \
    --identifier "$BUNDLE_ID" \
    "$APP"
else
  echo "warning: no '$SIGN_IDENTITY' identity found — ad-hoc signing (notarization will be skipped)"
  codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP"
  echo "Built and ad-hoc signed: $APP"
  exit 0
fi

# 4. Notarize via xcrun notarytool.
if ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1; then
  echo "warning: keychain profile '$KEYCHAIN_PROFILE' not configured — skipping notarization"
  echo "  configure once with: xcrun notarytool store-credentials $KEYCHAIN_PROFILE"
  exit 0
fi

ZIP="./build/FitsnFinish.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" \
  --keychain-profile "$KEYCHAIN_PROFILE" \
  --wait

# 5. Staple the notarization ticket.
xcrun stapler staple "$APP"
echo "Notarized and stapled: $APP"
