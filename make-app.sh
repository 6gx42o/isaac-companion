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

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/IsaacCompanionApp" "$APP/Contents/MacOS/IsaacCompanion"
# SPM emits resources as a .bundle next to the binary; carry it along.
if [ -d "$BIN_DIR/IsaacCompanion_IsaacCompanionApp.bundle" ]; then
  cp -R "$BIN_DIR/IsaacCompanion_IsaacCompanionApp.bundle" "$APP/Contents/Resources/"
fi
# The icon. Regenerate it with `python3 dev/make-icon.py`.
cp Resources/IsaacCompanion.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Isaac Companion</string>
  <key>CFBundleDisplayName</key><string>Isaac Companion</string>
  <key>CFBundleIdentifier</key><string>local.isaaccompanion</string>
  <key>CFBundleExecutable</key><string>IsaacCompanion</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
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

# Ad-hoc signature: enough for local use, and keeps the bundle identity stable so
# permissions and defaults survive rebuilds.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "built $APP"
lipo -archs "$APP/Contents/MacOS/IsaacCompanion" 2>/dev/null | sed 's/^/  arch: /' || true
