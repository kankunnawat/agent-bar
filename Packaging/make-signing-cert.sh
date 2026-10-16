#!/bin/bash
# Creates a self-signed code-signing certificate "AgentBar Dev" in the login
# keychain so AgentBar's signature is stable across rebuilds (keychain ACLs
# survive `make install`). Run once per machine; prompts for admin password
# when marking the cert trusted.
set -euo pipefail

NAME="AgentBar Dev"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "signing identity '$NAME' already exists — nothing to do"
    exit 0
fi

# A previous failed run may have left an untrusted (hence invalid, so not
# caught by the guard above) copy of the identity — remove it before importing.
security delete-identity -c "$NAME" "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null || true

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = AgentBar Dev
[ ext ]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF

openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.conf" 2>/dev/null
# OpenSSL 3.x defaults to AES/SHA-256 PKCS12 that `security import` cannot
# parse (fails as "MAC verification failed"); request legacy encryption when
# the flag exists. LibreSSL has no -legacy flag but its default already works.
LEGACY_FLAG=""
if openssl pkcs12 -export -help 2>&1 | grep -q -- -legacy; then
    LEGACY_FLAG="-legacy"
fi
# -name labels the imported key so the partition-list step can target it.
openssl pkcs12 -export $LEGACY_FLAG -name "$NAME" -inkey "$TMP/key.pem" \
    -in "$TMP/cert.pem" -out "$TMP/cert.p12" -passout pass:agentbar

security import "$TMP/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P agentbar -T /usr/bin/codesign

# Best-effort: SecKeychainItemSetAccessWithPassword is deprecated and fails on
# recent macOS even with the correct password. When it fails, the first codesign
# use of the key triggers the keychain dialog instead — "Always Allow" there
# grants the same access permanently.
echo "Authorizing codesign to use the key (login keychain password prompt)…"
if ! security set-key-partition-list -S apple-tool:,apple: -s -l "$NAME" \
    "$HOME/Library/Keychains/login.keychain-db" >/dev/null; then
    echo "warning: partition-list update failed (flaky legacy API on recent macOS)."
    echo "         On the first 'make app', a keychain dialog for 'codesign' will"
    echo "         appear: enter your login password and click 'Always Allow' (once)."
fi

echo "Marking the certificate trusted for code signing (admin password prompt)…"
sudo security add-trusted-cert -d -r trustRoot -p codeSign \
    -k /Library/Keychains/System.keychain "$TMP/cert.pem"

echo "Done. 'make app' will now sign with '$NAME'."
