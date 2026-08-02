#!/bin/bash
# Builds the universal .app and wraps it in every format a Mac user might want.
#
#   ./package.sh            -> dist/IsaacCompanion-{version}-{zip,dmg,pkg}
#
# Three formats because they are genuinely different installs, not the same thing
# three times:
#   .zip  smallest, no ceremony, unarchives to a bundle you drag where you like.
#   .dmg  the familiar drag-to-Applications window.
#   .pkg  a double-click installer that puts it in /Applications for you; the one
#         that works when someone does not want to think about where apps live.
#
# All three carry the SAME universal binary (arm64 + x86_64), so there is no
# "which Mac do I have" question to answer.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/IsaacCompanion.app"
DIST="dist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$APP/Contents/Info.plist" 2>/dev/null || echo 0.1)"
ID="local.isaaccompanion"

./make-app.sh release --universal

rm -rf "$DIST"
mkdir -p "$DIST"
BASE="$DIST/IsaacCompanion-$VERSION"

# ---- zip --------------------------------------------------------------------
# ditto, not zip(1): it preserves the resource forks and the code signature, and a
# plain zip of a .app can arrive on the far side unsigned and refusing to launch.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$BASE.zip"

# ---- dmg --------------------------------------------------------------------
# Staged in a temp folder with a symlink to /Applications, which is what makes the
# window a drag-to-install rather than a folder with one thing in it.
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -fs HFS+ -srcfolder "$STAGE" \
  -volname "Isaac Companion" -format UDZO -ov "$BASE.dmg"
rm -rf "$STAGE"

# ---- pkg --------------------------------------------------------------------
# --install-location /Applications, so the payload lands where the user expects
# without them choosing anything.
PKGROOT="$(mktemp -d)"
mkdir -p "$PKGROOT/Applications"
cp -R "$APP" "$PKGROOT/Applications/"
# pkgbuild writes a complete package and STILL prints "write: Permission denied"
# a few times -- it is failing to set some extended attribute on the staging copy,
# not failing to package. Left unfiltered it reads exactly like a broken build, so
# that one line is dropped and everything else it says is passed through.
PKGERR="$(pkgbuild --quiet --root "$PKGROOT" --identifier "$ID" --version "$VERSION" \
  --install-location / "$BASE.pkg" 2>&1 >/dev/null)" || { echo "$PKGERR" >&2; exit 1; }
printf '%s\n' "$PKGERR" | grep -v '^write: Permission denied$' | grep . >&2 || true
rm -rf "$PKGROOT"

# Trust nothing: prove the binary actually made it into the payload rather than
# assuming, given the above.
pkgutil --payload-files "$BASE.pkg" \
  | grep -q 'IsaacCompanion.app/Contents/MacOS/IsaacCompanion$' \
  || { echo "pkg payload is missing the executable" >&2; exit 1; }

# ---- windows -----------------------------------------------------------------
# A real PE32+ x86-64 binary, cross-compiled from here. It is a different program
# from the Mac app -- see win/src/main.rs -- but it runs the same log parser and the
# same Afterbirth+ stat model, which is the part that matters. Skipped rather than
# failed if the toolchain is absent, so a plain Mac checkout still packages.
if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1 \
   && rustup target list --installed 2>/dev/null | grep -q x86_64-pc-windows-gnu; then
  ( cd win && python3 bake-data.py >/dev/null \
      && cargo build --release --target x86_64-pc-windows-gnu >/dev/null 2>&1 )
  EXE="win/target/x86_64-pc-windows-gnu/release/isaac-companion.exe"
  if [ -f "$EXE" ]; then
    cp "$EXE" "$BASE-windows-x64.exe"
    # Zipped as well: browsers and SmartScreen treat a bare .exe download harshly,
    # and some corporate setups refuse it outright.
    ditto -c -k "$EXE" "$BASE-windows-x64.zip"
  fi
else
  echo "note: skipping the Windows build (needs mingw-w64 + the "\
    "x86_64-pc-windows-gnu Rust target)" >&2
fi

echo
echo "dist:"
# "$DIST"/*, not "$BASE".* -- the Windows files are named "$BASE-windows-x64.exe",
# so a dot-glob silently listed only the Mac three while the exe sat right there.
for f in "$DIST"/*; do
  printf '  %-42s %s\n' "$(basename "$f")" \
    "$(du -h "$f" | cut -f1 | tr -d ' ')"
done
echo
echo "architectures: $(lipo -archs "$APP/Contents/MacOS/IsaacCompanion")"
