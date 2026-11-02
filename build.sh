#!/bin/zsh
set -e
cd "$(dirname "$0")"
rm -rf build/InstantShot.app
mkdir -p build/InstantShot.app/Contents/MacOS
swiftc -module-cache-path "${TMPDIR:-/tmp}/instantshot-mc" -O -target arm64-apple-macos14.0 Sources/main.swift -o build/InstantShot.app/Contents/MacOS/InstantShot
cp Info.plist build/InstantShot.app/Contents/Info.plist
mkdir -p build/InstantShot.app/Contents/Resources
cp Resources/AppIcon.icns build/InstantShot.app/Contents/Resources/
codesign --force --sign - build/InstantShot.app
echo built build/InstantShot.app
