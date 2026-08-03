#!/bin/bash
# Assembles IsaacCompanion.app from the SPM build.
#
# A real bundle (not a bare binary) because the app needs a bundle identifier for
# UserDefaults and for the Screen Recording permission the room advisor will use.
#
#   ./make-app.sh                      debug, this machine's architecture -- dev loop
#   ./make-app.sh release              release, this machine's architecture
#   ./make-app.sh release --universal  release, arm64 + x86_64 in ONE binary
#
# The universal build is what ships: a single download that runs natively on Apple
# Silicon and on Intel Macs, with no Rosetta and nothing for the user to choose
# between. It costs about twice the build time and about 1 MB of download.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-debug}"
ARCHS=()
for arg in "$@"; do
  [ "$arg" = "--universal" ] && ARCHS=(--arch arm64 --arch x86_64)
done

swift build -c "$CONFIG" "${ARCHS[@]+"${ARCHS[@]}"}" --product IsaacCompanionApp

BIN_DIR="$(swift build -c "$CONFIG" "${ARCHS[@]+"${ARCHS[@]}"}" --show-bin-path)"
APP="build/IsaacCompanion.app"

# One version, read from one file. It used to be a literal in the heredoc below with a
# second copy in package.sh, which is how they drifted.
VERSION="$(tr -d '[:space:]' < VERSION)"
# Monotonic build number. A tarball with no .git still builds; it just gets 1.
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/IsaacCompanionApp" "$APP/Contents/MacOS/IsaacCompanion"
# SPM emits resources as a .bundle next to the binary; carry it along.
if [ -d "$BIN_DIR/IsaacCompanion_IsaacCompanionApp.bundle" ]; then
  cp -R "$BIN_DIR/IsaacCompanion_IsaacCompanionApp.bundle" "$APP/Contents/Resources/"
fi
# The icon. Regenerate it with `python3 dev/make-icon.py`.
cp Resources/IsaacCompanion.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Isaac Companion</string>
  <key>CFBundleDisplayName</key><string>Isaac Companion</string>
  <key>CFBundleIdentifier</key><string>com.rushilluthra.isaaccompanion</string>
  <key>CFBundleExecutable</key><string>IsaacCompanion</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <!-- Both keys: CFBundleIconFile is what the Finder and Dock read from a plain
       bundle, CFBundleIconName is what the newer APIs look for. -->
  <key>CFBundleIconFile</key><string>IsaacCompanion</string>
  <key>CFBundleIconName</key><string>IsaacCompanion</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <!-- Without this, force-quitting leaves a "reopen windows?" dialog that blocks the
       next launch before any view appears. -->
  <key>NSQuitAlwaysKeepsWindows</key><false/>
  <key>NSScreenCaptureUsageDescription</key>
  <string>Isaac Companion reads the item on a pedestal from the game window. It never modifies the game.</string>
</dict>
</plist>
PLIST

# --- signing -----------------------------------------------------------------------
#
# This matters more than it looks. macOS ties the Screen Recording grant to the signing
# identity, and an ad-hoc signature (`--sign -`) is DIFFERENT on every build -- so every
# rebuild silently revoked the permission and the pedestal scanner stopped working until
# it was granted again by hand. (An earlier version of this comment claimed ad-hoc kept
# the identity stable. It does not.)
#
# Order of preference:
#   1. $ISAAC_SIGN_ID          -- set this to a "Developer ID Application: ..." identity
#   2. the local self-signed identity from scripts/make-signing-cert.sh
#   3. ad-hoc, with a warning, so a fresh clone still builds
SIGN_KC="$HOME/Library/Keychains/isaac-signing.keychain-db"
SIGN_ID="${ISAAC_SIGN_ID:-}"
SIGN_KIND="ad-hoc"
if [ -n "$SIGN_ID" ]; then
  SIGN_KIND="Developer ID"
elif [ -f "$SIGN_KC" ]; then
  SIGN_ID="$(security find-certificate -c "Isaac Companion Self-Signed" -Z "$SIGN_KC" 2>/dev/null |
    awk '/^SHA-1 hash:/ {print $3; exit}')"
  [ -n "$SIGN_ID" ] && SIGN_KIND="self-signed (stable)"
fi

SIGN_ARGS=(--force --timestamp=none --entitlements Resources/IsaacCompanion.entitlements)
if [ "$SIGN_KIND" = "Developer ID" ]; then
  # Hardened runtime and a trusted timestamp are both required for notarisation, and
  # both are wrong for a self-signed build -- the hardened runtime refuses to load an
  # untrusted signature at all.
  SIGN_ARGS=(--force --timestamp --options runtime
             --entitlements Resources/IsaacCompanion.entitlements)
fi

if [ -z "$SIGN_ID" ]; then
  echo "warning: no signing identity; falling back to ad-hoc." >&2
  echo "         Screen Recording permission will reset on every rebuild." >&2
  echo "         Fix it once with: ./scripts/make-signing-cert.sh" >&2
  SIGN_ID="-"
fi

# No `|| true` here. A signing failure used to be swallowed, which meant a broken
# signature looked exactly like a working one until the app misbehaved at runtime.
codesign "${SIGN_ARGS[@]}" --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP"

echo "built $APP  (v$VERSION build $BUILD, $SIGN_KIND)"
lipo -archs "$APP/Contents/MacOS/IsaacCompanion" 2>/dev/null | sed 's/^/  arch: /' || true
