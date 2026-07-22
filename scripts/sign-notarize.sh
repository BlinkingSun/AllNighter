#!/bin/bash
# Code-sign (Developer ID, hardened runtime, secure timestamp), notarize, and
# staple dist/AllNighter.app, then produce the release zip dist/AllNighter-<v>.zip.
#
# Requires: a "Developer ID Application" identity in the login keychain and a
# stored notarytool keychain profile (default name: gcs-notary).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.1.0}"
APP="dist/AllNighter.app"
SIGN_ID="${SIGN_ID:-Developer ID Application: Joshua Roberts (L3LP86Z6L4)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-gcs-notary}"

[ -d "$APP" ] || { echo "ERROR: $APP not found — run scripts/build-app.sh first"; exit 1; }

echo "Signing $APP with: $SIGN_ID"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "Zipping for notarization…"
rm -f "dist/AllNighter.zip" "dist/AllNighter-$VERSION.zip"
ditto -c -k --keepParent "$APP" "dist/AllNighter.zip"

echo "Submitting to Apple notary service (waits for result)…"
xcrun notarytool submit "dist/AllNighter.zip" --keychain-profile "$NOTARY_PROFILE" --wait

echo "Stapling ticket…"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "Building stapled release asset…"
rm -f "dist/AllNighter-$VERSION.zip"
ditto -c -k --keepParent "$APP" "dist/AllNighter-$VERSION.zip"
echo "Done → dist/AllNighter-$VERSION.zip"
