#!/bin/bash
# Build a Release universal binary and package it into a DMG.
#
# Signing is automatic when a "Developer ID Application" identity exists in
# the keychain; otherwise the build is ad-hoc signed (local use only).
# Notarization runs when notarytool credentials are stored under the profile
# in $NOTARY_PROFILE (one-time setup:
#   xcrun notarytool store-credentials agent-babysitter-notary \
#     --apple-id <apple-id-email> --team-id <TEAMID> --password <app-specific-pw>).
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARY_PROFILE="${NOTARY_PROFILE:-agent-babysitter-notary}"
# `|| true`: grep exits 1 when no identity exists, which set -e would
# otherwise turn into a silent death before the first echo.
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)}"

xcodegen generate --quiet

if [ -n "$SIGN_IDENTITY" ]; then
    echo "Signing with: $SIGN_IDENTITY"
    xcodebuild -project AgentBabysitter.xcodeproj -scheme AgentBabysitter \
        -configuration Release -derivedDataPath build \
        -destination "generic/platform=macOS" \
        ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
        OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" build
else
    echo "No Developer ID Application identity found — ad-hoc signing (local use only)."
    xcodebuild -project AgentBabysitter.xcodeproj -scheme AgentBabysitter \
        -configuration Release -derivedDataPath build \
        -destination "generic/platform=macOS" \
        ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build
fi

APP="build/Build/Products/Release/AgentBabysitter.app"
VERSION=$(defaults read "$(pwd)/$APP/Contents/Info" CFBundleShortVersionString)
DMG="build/AgentBabysitter-$VERSION.dmg"

codesign --verify --deep --strict "$APP"

STAGING=$(mktemp -d)
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Agent Babysitter" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

if [ -n "$SIGN_IDENTITY" ]; then
    codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        echo "Notarizing (this can take a few minutes)..."
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
        xcrun stapler validate "$DMG"
        echo "Notarized and stapled."
    else
        echo "WARNING: no notarytool credentials under profile '$NOTARY_PROFILE'."
        echo "Signed but NOT notarized — Gatekeeper will warn on download."
    fi
fi

echo "Created $DMG"
lipo -archs "$APP/Contents/MacOS/AgentBabysitter"
