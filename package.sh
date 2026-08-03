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
# One source of truth, shared with make-app.sh. This used to read the version back out
# of the built plist with a hardcoded "0.1" fallback, so a build failure silently
# produced correctly-named artifacts of the wrong version.
VERSION="$(tr -d '[:space:]' < VERSION)"
ID="com.rushilluthra.isaaccompanion"

# The Rust crate carries its own version, and the Windows updater compares against it.
# Left to drift, the .exe would offer itself an update forever.
WIN_VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' win/Cargo.toml | head -1)"
if [ "$WIN_VERSION" != "$VERSION" ]; then
  echo "win/Cargo.toml says $WIN_VERSION but VERSION says $VERSION" >&2
  exit 1
fi

./make-app.sh release --universal

# Signing the installers is separate from signing the app: an unsigned pkg is refused by
# Gatekeeper even when the .app inside it is fine. Both are skipped cleanly without a
# Developer ID, which is the normal case for a local build.
#   export ISAAC_INSTALLER_SIGN_ID="Developer ID Installer: Your Name (TEAMID)"
#   export ISAAC_SIGN_ID="Developer ID Application: Your Name (TEAMID)"
#   export ISAAC_NOTARY_PROFILE="isaac"   # xcrun notarytool store-credentials isaac
INSTALLER_ID="${ISAAC_INSTALLER_SIGN_ID:-}"
NOTARY_PROFILE="${ISAAC_NOTARY_PROFILE:-}"

notarise() {
  [ -n "$NOTARY_PROFILE" ] || return 0
  echo "notarising $(basename "$1")..."
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
  # Stapling is what makes the artifact work offline; without it Gatekeeper has to
  # reach Apple on first launch and a plane or a firewall turns into "damaged app".
  xcrun stapler staple "$1"
}

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
if [ -n "${ISAAC_SIGN_ID:-}" ]; then
  codesign --force --timestamp --sign "$ISAAC_SIGN_ID" "$BASE.dmg"
fi
notarise "$BASE.dmg"

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

# A pkg needs a Developer ID *Installer* certificate, which is a different certificate
# from the Application one that signs the .app.
if [ -n "$INSTALLER_ID" ]; then
  productsign --sign "$INSTALLER_ID" "$BASE.pkg" "$BASE.signed.pkg"
  mv "$BASE.signed.pkg" "$BASE.pkg"
fi
notarise "$BASE.pkg"

# ---- windows -----------------------------------------------------------------
# A real PE32+ x86-64 binary, cross-compiled from here. It is a different program
# from the Mac app -- see win/src/main.rs -- but it runs the same log parser and the
# same Afterbirth+ stat model, which is the part that matters. Skipped rather than
# failed if the toolchain is absent, so a plain Mac checkout still packages.
if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1 \
   && rustup target list --installed 2>/dev/null | grep -q x86_64-pc-windows-gnu; then
  # bake-data.py regenerates win/src/*.tsv from the built data bundle in Application
  # Support, so it only works on a machine that has the game. The TSVs are committed
  # exactly so a build does not need it -- re-bake when we can, carry on when we cannot.
  ( cd win \
      && { python3 bake-data.py >/dev/null 2>&1 \
           || echo "note: keeping the committed item tables (no data bundle to re-bake from)" >&2; } \
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

# ---- checksums ----------------------------------------------------------------
# The auto-updater refuses to install anything whose hash is not in this file, so it
# ships as a release asset alongside the binaries. Paths are stripped to bare filenames
# so `shasum -c SHA256SUMS` works from whatever directory the assets were downloaded to.
( cd "$DIST" && shasum -a 256 ./* | sed 's# \./# #' > SHA256SUMS )

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
