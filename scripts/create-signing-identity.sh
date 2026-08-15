#!/bin/bash
#
# Creates the self-signed identity that scripts/build-local-app.sh signs with.
#
# Why this exists: an ad-hoc signature has no stable designated requirement, so
# macOS keys the Accessibility and Input Monitoring grants to the code hash.
# That hash changes on every build. The result is an app that sits in the
# permission list with its checkbox on while AXIsProcessTrusted() returns
# false, and a dictation key that stops working after every rebuild with no
# indication why. Signing with a certificate that stays the same across builds
# makes the grant stick.
#
# This is for local development only. It signs nothing anyone else can verify,
# and it is not a substitute for a Developer ID when Talkify is distributed.
#
# Run once. Re-running replaces the identity, which costs one re-grant.
set -euo pipefail

NAME="${TALKIFY_SIGN_IDENTITY:-Talkify Local Signing}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

log() { printf '\033[1m==>\033[0m %s\n' "$1"; }

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  log "\"$NAME\" already exists — nothing to do."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log "Generating a code signing certificate"
openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 7300 -nodes -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# OpenSSL 3 defaults to AES-256 and a SHA-256 MAC, neither of which Apple's
# keychain importer reads. The legacy algorithms are the ones it accepts.
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout pass:talkify -name "$NAME" \
  -legacy -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

log "Importing into the login keychain"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P talkify -T /usr/bin/codesign -A

# Without a trust setting for code signing the certificate imports fine and
# then reports zero valid identities. macOS asks for the login password here.
log "Trusting it for code signing (macOS will ask for your password)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

log "Done:"
security find-identity -v -p codesigning | grep "$NAME"

cat <<'EOF'

Next: rebuild and reinstall, then grant Accessibility and Input Monitoring one
more time. Remove any existing Talkify row with "−" before re-adding it — a row
left over from an ad-hoc build looks granted and is not.

From then on, rebuilds keep the grant.
EOF
