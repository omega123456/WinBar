#!/bin/bash
# One-time creation of the self-signed "WinBar Local Signing" code-signing identity.
# Run in Terminal.app (needs a hidden password prompt and a system trust dialog).
set -euo pipefail

NAME="WinBar Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL=/usr/bin/openssl   # Apple's LibreSSL: Homebrew OpenSSL 3 .p12 files fail `security import`

ids=$(security find-identity -v -p codesigning)
if [[ $ids == *"\"$NAME\""* ]]; then
    echo "\"$NAME\" already exists:"
    echo "$ids"
    exit 0
fi
if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "error: a \"$NAME\" certificate exists but is not a valid signing identity (partial earlier run)." >&2
    echo "Delete the \"$NAME\" certificate and key in Keychain Access, then re-run this script." >&2
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

# 1. Key + certificate with the code-signing EKU.
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem"

# 2. Pack into a .p12 (throwaway transport password).
P12PW=$("$OPENSSL" rand -hex 16)
"$OPENSSL" pkcs12 -export -name "$NAME" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout "pass:$P12PW"

# 3. Import into the login keychain, allowing codesign to use the key.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$P12PW" -T /usr/bin/codesign

# 4. Partition list, so codesign never shows a keychain dialog.
read -r -s -p "Login keychain password (your macOS login password): " KCPW
echo
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPW" -l "$NAME" "$KEYCHAIN" >/dev/null
unset KCPW

# 5. Trust the certificate for code signing (user trust settings; shows an authorization dialog).
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

# 6. Show the result.
security find-identity -v -p codesigning
