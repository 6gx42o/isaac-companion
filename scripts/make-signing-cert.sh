#!/bin/bash
# Create a stable self-signed code-signing identity for local builds.
#
# WHY: `codesign --sign -` (ad-hoc) produces a DIFFERENT signature every build. macOS ties
# the Screen Recording grant to the signing identity, so every rebuild silently revoked the
# permission and the pedestal scanner stopped working until it was granted again by hand.
# A stable identity fixes that permanently.
#
# WHAT IT DOES NOT FIX: Gatekeeper. A self-signed certificate is not a Developer ID, so a
# downloaded build still warns. Only Apple Developer Program enrolment fixes that; see the
# ISAAC_SIGN_ID / notarisation notes in make-app.sh and package.sh.
#
# The key lands in its own keychain, not your login keychain. That is deliberate: codesign
# needs the key's partition list opened, which requires the keychain's password, and asking
# for your login password in a build script is not on. This script creates a keychain whose
# password it already knows.
#
# On that password: it is a fixed string, stored below in plain sight. It guards a key whose
# only power is to make signatures macOS does not trust anyway -- the point is that the
# signature stays the SAME between builds, not that it proves anything about who made it.
# Treat it as a build artifact, not a secret. Delete the keychain any time with:
#   security delete-keychain ~/Library/Keychains/isaac-signing.keychain-db
#
# Idempotent: run it as often as you like.
set -euo pipefail

CN="${ISAAC_CERT_NAME:-Isaac Companion Self-Signed}"
KC_NAME="isaac-signing.keychain"
KC="$HOME/Library/Keychains/${KC_NAME}-db"
KC_PASS="isaac-companion-local-signing"
DAYS="${ISAAC_CERT_DAYS:-3650}"

find_hash() {
  security find-certificate -c "$CN" -Z "$KC" 2>/dev/null |
    awk '/^SHA-1 hash:/ {print $3; exit}'
}

if [ -f "$KC" ] && [ -n "$(find_hash)" ]; then
  security unlock-keychain -p "$KC_PASS" "$KC"
  echo "Already present: $(find_hash)  \"$CN\""
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# codeSigning EKU is the part that matters -- without it codesign will not use the key.
cat > "$TMP/openssl.cnf" <<CONF
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[ dn ]
CN = $CN
[ ext ]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
subjectKeyIdentifier = hash
CONF

openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days "$DAYS" \
  -config "$TMP/openssl.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null

# -keypbe/-certpbe/-macalg pin the legacy PKCS#12 encryption. OpenSSL 3 defaults to
# AES-256-CBC + PBKDF2, which macOS's importer cannot read -- and it reports that as
# "the passphrase you entered is not correct", which sends you looking in the wrong place.
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg SHA1 \
  -passout pass:isaac -out "$TMP/identity.p12" 2>/dev/null

[ -f "$KC" ] || security create-keychain -p "$KC_PASS" "$KC_NAME"
security set-keychain-settings "$KC"          # no lock timeout, no lock on sleep
security unlock-keychain -p "$KC_PASS" "$KC"
security import "$TMP/identity.p12" -k "$KC" -f pkcs12 -P isaac \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# The step that stops codesign hanging on a GUI prompt. `security import -A` alone is not
# enough on modern macOS: the key also carries a partition list, and opening that needs the
# keychain password -- which is exactly why this keychain is ours rather than the login one.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$KC_PASS" "$KC" >/dev/null 2>&1

# codesign only searches the keychains on the user's search list.
if ! security list-keychains -d user | grep -qF "$KC_NAME"; then
  EXISTING="$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//')"
  # shellcheck disable=SC2086
  security list-keychains -d user -s $(printf '%s\n' "$EXISTING" | tr '\n' ' ') "$KC"
fi

HASH="$(find_hash)"
echo "Created a code-signing identity: $HASH  \"$CN\""
echo "Keychain: $KC"
echo
echo "make-app.sh picks this up automatically. To override:  export ISAAC_SIGN_ID='...'"
