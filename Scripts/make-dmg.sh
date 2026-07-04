#!/bin/bash
# Build a Release universal binary and package it into a DMG.
# Signing/notarization: once a Developer ID cert is installed, set
# CODE_SIGN_IDENTITY below and add a notarytool submit step.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet
xcodebuild -project AgentBabysitter.xcodeproj -scheme AgentBabysitter \
    -configuration Release -derivedDataPath build \
    -destination "generic/platform=macOS" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build

APP="build/Build/Products/Release/AgentBabysitter.app"
VERSION=$(defaults read "$(pwd)/$APP/Contents/Info" CFBundleShortVersionString)
DMG="build/AgentBabysitter-$VERSION.dmg"

STAGING=$(mktemp -d)
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Agent Babysitter" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

echo "Created $DMG"
lipo -archs "$APP/Contents/MacOS/AgentBabysitter"
