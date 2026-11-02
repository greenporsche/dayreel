#!/bin/zsh
set -e
cd "$(dirname "$0")"
rm -rf build/InstantShot.app
mkdir -p build/InstantShot.app/Contents/MacOS
swiftc -module-cache-path "${TMPDIR:-/tmp}/instantshot-mc" -O -target arm64-apple-macos14.0 Sources/main.swift -o build/InstantShot.app/Contents/MacOS/InstantShot
cp Info.plist build/InstantShot.app/Contents/Info.plist
mkdir -p build/InstantShot.app/Contents/Resources
cp Resources/AppIcon.icns build/InstantShot.app/Contents/Resources/
# Sign with the local "InstantShot Signing" certificate when present (stable identity across rebuilds,
# so macOS keeps the Screen Recording grant); otherwise fall back to ad-hoc.
IDENTITY="InstantShot Signing"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" build/InstantShot.app
  echo "signed with $IDENTITY"
else
  codesign --force --sign - build/InstantShot.app
  echo "signed ad-hoc (no \"$IDENTITY\" certificate found)"
fi
echo built build/InstantShot.app
