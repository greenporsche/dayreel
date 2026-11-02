#!/bin/zsh
set -e
cd "$(dirname "$0")"
rm -rf build/InstantShot.app
mkdir -p build/InstantShot.app/Contents/MacOS
swiftc -module-cache-path "${TMPDIR:-/tmp}/instantshot-mc" -O -target arm64-apple-macos14.0 Sources/main.swift -o build/InstantShot.app/Contents/MacOS/InstantShot
cp Info.plist build/InstantShot.app/Contents/Info.plist
mkdir -p build/InstantShot.app/Contents/Resources
cp Resources/AppIcon.icns build/InstantShot.app/Contents/Resources/
# Signing identity: $INSTANTSHOT_SIGN_IDENTITY, else the git-ignored local file .signing-identity.
# A configured identity gives the app a stable designated requirement across rebuilds.
# If one is configured but missing from the keychain, fail instead of silently signing ad-hoc.
IDENTITY="${INSTANTSHOT_SIGN_IDENTITY:-$(cat .signing-identity 2>/dev/null || true)}"
if [[ -n "$IDENTITY" ]]; then
  if ! security find-identity -p codesigning | grep -qF "\"$IDENTITY\""; then
    echo "error: signing identity \"$IDENTITY\" not found in the keychain" >&2
    exit 1
  fi
  codesign --force --sign "$IDENTITY" build/InstantShot.app
  echo "signed with $IDENTITY"
else
  codesign --force --sign - build/InstantShot.app
  echo "signed ad-hoc (no signing identity configured)"
fi
echo built build/InstantShot.app
