#!/bin/bash
# One-time setup on the release Mac. Creates the two keys every release is signed with:
#
#   1. "Briefing Self-Signed" — a free code-signing certificate in the login keychain.
#      macOS does not trust it (the first launch still needs "Open Anyway"), but it stays the same
#      from version to version, so macOS keeps Calendar and Reminders access across updates.
#   2. Sparkle's EdDSA key — proves to installed copies that an update really comes from you.
#      Its public half is written into Resources/Info.plist (SUPublicEDKey).
#
# Both are backed up to ~/Documents/Briefing-signing/. Keep that folder somewhere safe and private:
# losing it means users must re-grant Calendar access and cannot auto-update to the next version.
set -euo pipefail
cd "$(dirname "$0")/.."

CERT_NAME="Briefing Self-Signed"
ACCOUNT="io.github.vanodium.briefing"
BACKUP="$HOME/Documents/Briefing-signing"
TOOLS=".build/artifacts/sparkle/Sparkle/bin"   # comes with the Sparkle package
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

mkdir -p "$BACKUP"
chmod 700 "$BACKUP"

# MARK: 1. Certificate

if security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "✓ Certificate \"$CERT_NAME\" already exists"
else
    echo "→ Creating certificate \"$CERT_NAME\" (valid 20 years)"
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CERT_NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
        -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null

    echo "  Choose a password for the backup file (you need it only to restore the certificate):"
    read -r -s -p "  Password: " PASS; echo
    /usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
        -name "$CERT_NAME" -out "$BACKUP/briefing-certificate.p12" -passout "pass:$PASS"

    security import "$BACKUP/briefing-certificate.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
    echo "  macOS will ask for your password to trust the certificate for code signing."
    security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"
    echo "✓ Certificate created; backup: $BACKUP/briefing-certificate.p12"
fi

# MARK: 2. Sparkle key

[ -x "$TOOLS/generate_keys" ] || swift package resolve

# Creates the key on the first run, prints the existing one afterwards.
"$TOOLS/generate_keys" --account "$ACCOUNT" >/dev/null
PUBLIC_KEY="$("$TOOLS/generate_keys" --account "$ACCOUNT" -p)"
if [ ! -f "$BACKUP/sparkle-private-key.txt" ]; then
    "$TOOLS/generate_keys" --account "$ACCOUNT" -x "$BACKUP/sparkle-private-key.txt"
    chmod 600 "$BACKUP/sparkle-private-key.txt"
fi
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $PUBLIC_KEY" Resources/Info.plist
echo "✓ Sparkle key ready; public key written to Resources/Info.plist"
echo "  backup: $BACKUP/sparkle-private-key.txt"

echo
echo "Done. Store $BACKUP somewhere safe (a password manager or an encrypted drive)."
