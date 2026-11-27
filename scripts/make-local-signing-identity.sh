#!/usr/bin/env bash
# Creates a self-signed code-signing identity "DiskCare Local" in the login keychain.
#
# Ad-hoc signed builds get a new identity on every build, so macOS forgets permissions such as
# Full Disk Access after each rebuild. Builds signed with this one identity keep them.
# Local use only: it is not trusted by Gatekeeper on other Macs (use a Developer ID for that).
set -euo pipefail

NAME="${1:-DiskCare Local}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "\"$NAME\" already exists in the login keychain."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
PASSWORD="$(openssl rand -hex 16)"
# macOS `security` only reads the classic PKCS#12 algorithms (OpenSSL 3 defaults to AES/SHA-256).
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -out "$WORK/identity.p12" -passout "pass:$PASSWORD" 2>/dev/null
# Only codesign may use the private key.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
echo "Created \"$NAME\". scripts/bundle-app.sh signs with it automatically."
