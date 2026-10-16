#!/bin/bash
# Creates the self-signed code-signing certificate "Tacet Beta" in the login
# keychain (free, no Apple account). Every beta must be signed with the SAME
# certificate: macOS ties the file grant (security-scoped bookmark) and any
# other grants to the signing identity, so a different one makes testers
# grant access again.
#
# Back up the exported .p12 (KEEP IT PRIVATE): it is the only way to sign
# future betas with the same identity, e.g. on another Mac. Its password is
# stored in the login keychain as "<NAME> signing backup".
#   scripts/make-beta-cert.sh            # create and import
#   NAME="Tacet Beta" DAYS=3650 OUT=~/tacet-beta.p12 scripts/make-beta-cert.sh
set -euo pipefail
NAME="${NAME:-Tacet Beta}"
DAYS="${DAYS:-3650}"
# Not ~/Documents: it may sync to iCloud Drive (review 3.3). Copy the backup
# to offline storage (an encrypted USB drive or a password manager).
OUT="${OUT:-$HOME/Library/Application Support/Tacet/signing/$NAME signing.p12}"

if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "\"$NAME\" already exists in the keychain; nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days "$DAYS" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
PASS="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/cert.p12" -passout "pass:$PASS"
# -T: let codesign use the key without a keychain prompt every build.
security import "$TMP/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$PASS" -T /usr/bin/codesign
mkdir -p "$(dirname "$OUT")"
chmod 700 "$(dirname "$OUT")"
cp "$TMP/cert.p12" "$OUT"
chmod 600 "$OUT"
# The backup's password goes into the login keychain (Keychain Access →
# "<NAME> signing backup"), never to the terminal or a file.
security add-generic-password -U -s "$NAME signing backup" -a "$(basename "$OUT")" -w "$PASS" \
    -j "Password of the .p12 backup made by Tacet's make-beta-cert.sh"
echo "Created \"$NAME\" (valid $DAYS days)."
echo "Backup: $OUT"
echo "Its password is in Keychain Access, item \"$NAME signing backup\"."
echo "Copy the .p12 to offline storage and keep it private; don't put it in a synced folder."
