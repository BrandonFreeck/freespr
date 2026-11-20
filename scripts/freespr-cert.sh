#!/bin/sh
# Create a stable, self-signed CODE-SIGNING identity for freespr — entirely from the CLI, no
# Keychain Access GUI. Signing freespr.app with this (instead of ad-hoc) gives it a constant
# designated requirement, so macOS TCC keeps the Accessibility and Microphone grants across
# rebuilds (ad-hoc's cdhash changes every build and the grants reset). One-time; idempotent.
#
# Not Developer ID, not notarized — neither is needed for TCC (that's Gatekeeper/distribution).
set -eu

CERT_NAME="freespr-codesign"
KEYCHAIN="$(security login-keychain | tr -d ' "\n')"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Idempotent: reuse an existing identity.
if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CERT_NAME"; then
  echo "  code-signing identity '$CERT_NAME' already present — reusing."
  exit 0
fi

# A run whose trust dialog was cancelled left the cert and key imported but untrusted. Finish that
# one instead of importing a second '$CERT_NAME', which would make the name ambiguous to codesign.
if security find-certificate -c "$CERT_NAME" -p "$KEYCHAIN" > "$WORK/cert.pem" 2>/dev/null \
   && [ -s "$WORK/cert.pem" ]; then
  if ! security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "  ERROR: found a '$CERT_NAME' certificate without its private key (an earlier run failed)."
    echo "  Remove it with: security delete-certificate -c $CERT_NAME \"$KEYCHAIN\", then re-run 'make cert'."
    exit 1
  fi
  echo "  found an untrusted '$CERT_NAME' from an earlier run — finishing its trust setup…"
else
echo "  creating self-signed code-signing identity '$CERT_NAME'…"

# 1. Self-signed cert + key with the codeSigning extended key usage (mandatory for codesign).
cat > "$WORK/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[ dn ]
CN = $CERT_NAME
[ v3 ]
basicConstraints = critical,CA:false
keyUsage         = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/openssl.cnf" >/dev/null 2>&1

# 2. Import the cert + private key directly as PEM (NOT PKCS#12). openssl 3.x writes a PKCS#12 MAC
#    the macOS Security framework can't verify ("MAC verification failed"), so we skip the bundle and
#    import the two PEMs separately — Security forms the identity from the matching public key.
#    -T /usr/bin/codesign lets codesign, and only codesign, use the private key. Never add -A: it
#    lets any app use the key directly. (Any program can still run codesign itself; the README's
#    `make cert` section explains that trade-off.)
security import "$WORK/cert.pem" -k "$KEYCHAIN" >/dev/null 2>&1 || true
if ! security import "$WORK/key.pem" -k "$KEYCHAIN" -T /usr/bin/codesign >/dev/null 2>&1; then
  # No '$CERT_NAME' existed before this run (the check above), so this removes only what it added.
  security delete-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1 || true
  echo "  ERROR: importing the private key failed, so the certificate this run added was removed."
  echo "  Check that the login keychain is unlocked ('security unlock-keychain'), then re-run 'make cert'."
  exit 1
fi
fi

# 3. Trust the self-signed cert as a code-signing root in the USER login keychain (no sudo). This is
#    REQUIRED for `find-identity -v` to list it and for macOS to honor the signature. It pops a
#    one-time login-password dialog — enter your Mac password when asked.
echo "  → macOS will ask for your login password to trust the cert (one time)…"
trusted=yes
security add-trusted-cert -p codeSign -r trustRoot -k "$KEYCHAIN" "$WORK/cert.pem" || trusted=no

# (No key-partition-list reset here — that needs the keychain password non-interactively. Instead,
#  codesign asks for key access once on the first `make install`; click "Always Allow" → silent after.)

if [ "$trusted" = yes ] && security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CERT_NAME"; then
  echo "  done — '$CERT_NAME' is trusted and ready. Next: make reinstall  (codesign → 'Always Allow')."
else
  [ "$trusted" = yes ] || echo "  The trust step failed or was cancelled."
  echo "  WARNING: '$CERT_NAME' not listed as valid by find-identity. If the trust dialog was"
  echo "  cancelled, re-run 'make cert' and approve it; or check 'security unlock-keychain'. To start"
  echo "  over: security delete-identity -c $CERT_NAME -t \"$KEYCHAIN\", then re-run 'make cert'."
  exit 1
fi
