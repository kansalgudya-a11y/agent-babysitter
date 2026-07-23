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

# Preflight: fail fast with an actionable message instead of dying mid-build.
# xcodegen produces the project; xcodebuild compiles it. `xcodebuild` is on
# PATH even with only the Command Line Tools, but it errors at run time when
# no full Xcode is selected — so probe `xcodebuild -version` rather than mere
# presence.
command -v xcodegen >/dev/null 2>&1 || {
    echo "error: 'xcodegen' not found. Install it (brew install xcodegen)." >&2
    exit 1
}
if ! xcodebuild -version >/dev/null 2>&1; then
    echo "error: a full Xcode.app is required to build (Command Line Tools alone" >&2
    echo "       cannot compile this project). Install Xcode.app, then run:" >&2
    echo "       sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 1
fi

NOTARY_PROFILE="${NOTARY_PROFILE:-agent-babysitter-notary}"
# `|| true`: grep exits 1 when no identity exists, which set -e would
# otherwise turn into a silent death before the first echo.
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)}"

xcodegen generate --quiet

# Release artifacts must never ship stale objects: incremental builds have
# been observed reusing old .o files despite newer sources (three times).
rm -rf build/Build

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
if [ -z "$SIGN_IDENTITY" ]; then
    # Unsigned beta: downloaded copies get quarantined and macOS blocks the
    # first launch — ship the workaround with the DMG.
    cat > "$STAGING/How to install (read me).txt" <<'TXT'
Agent Babysitter beta — unsigned build

1. Drag AgentBabysitter.app into the Applications folder.
2. Open it once. macOS will say it "could not verify" the app — close that.
3. Go to System Settings > Privacy & Security, scroll down, and click
   "Open Anyway" next to AgentBabysitter, then confirm.

You only have to do this once. Signed builds will remove this step.
TXT
fi
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
# The x86_64 slice of this universal binary is never exercised by the Apple
# Silicon machine that builds it. Smoke-launch the finished DMG (ideally on
# both arches) before shipping — the artifact you distribute is not the Debug
# build you dogfood.
lipo -archs "$APP/Contents/MacOS/AgentBabysitter"

# Guard: an unsigned DMG is a local artifact, not a shippable one. Do not
# fabricate an identity to silence this — the only real fix is enrolling in
# the Apple Developer Program and signing + notarizing (the path above runs
# automatically once a Developer ID identity is in the keychain).
if [ -z "$SIGN_IDENTITY" ]; then
    cat >&2 <<WARN

============================== WARNING ==============================
This DMG is UNSIGNED and NOT notarized — LOCAL USE ONLY.
Do not distribute or sell it: on any machine that downloads it,
macOS Gatekeeper will reject it ("cannot verify … free of malware"),
and there is no signature for Apple to revoke if the binary is ever
compromised.

Before shipping to users you MUST:
  1. Enroll in the Apple Developer Program and create a
     "Developer ID Application" certificate.
  2. Re-run this script with that identity in the keychain (picked up
     automatically) so the .app and .dmg are signed --options=runtime.
  3. Store notarytool credentials under profile "$NOTARY_PROFILE" so
     this script submits, staples, and validates the ticket.
Then confirm with:  spctl -a -t install -vv "$DMG"
====================================================================
WARN
fi
