#!/bin/bash
# Creates a self-signed "Deckmian Local Signing" code-signing identity in the login keychain.
#
# A stable signing identity keeps macOS privacy permissions (Accessibility, Screen Recording,
# Calendar...) across rebuilds. Ad-hoc signed builds lose them every time the binary changes.
#
# After running this script, mark the certificate as trusted for code signing (macOS asks for
# your password):
#
#   security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db "<printed cert path>"

set -euo pipefail

NAME="Deckmian Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK_DIR="${1:-$(mktemp -d)}"
OPENSSL="${OPENSSL:-openssl}"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "\"$NAME\" already exists in the login keychain."
    exit 0
fi

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

cat > cert.cnf <<EOF
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

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf 2>/dev/null

# macOS only imports PKCS#12 files that use the legacy encryption algorithms.
P12_PASSWORD="$(uuidgen)"
"$OPENSSL" pkcs12 -export -legacy -inkey key.pem -in cert.pem -out identity.p12 \
    -passout "pass:$P12_PASSWORD" -name "$NAME" 2>/dev/null \
    || /usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -out identity.p12 \
        -passout "pass:$P12_PASSWORD" -name "$NAME"

security import identity.p12 -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null

# The private key now lives only in the keychain.
rm -f key.pem identity.p12 cert.cnf

echo "Imported \"$NAME\" into the login keychain."
echo "Certificate: $WORK_DIR/cert.pem"
