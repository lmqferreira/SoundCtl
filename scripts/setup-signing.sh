#!/usr/bin/env bash
# Create a local, stable self-signed code-signing identity ("SoundCtl
# Self-Signed") so the app's designated requirement is keyed on the certificate
# (not the per-build cdhash). This makes the Accessibility permission and
# Launch-at-Login survive rebuilds/reinstalls — without it, every ad-hoc rebuild
# invalidates the grant and you have to re-authorise.
#
# Run once: scripts/setup-signing.sh
# It is idempotent (does nothing if the identity already exists). The private key
# lives only in your login keychain; nothing secret is committed.
set -euo pipefail

IDENTITY="SoundCtl Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "==> '$IDENTITY' already exists — nothing to do."
    exit 0
fi

DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
cat > "$DIR/cfg.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = SoundCtl Self-Signed
[v3]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
EOF

echo "==> generating self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -keyout "$DIR/key.pem" -out "$DIR/cert.pem" \
    -days 3650 -nodes -config "$DIR/cfg.cnf" >/dev/null 2>&1

echo "==> importing into the login keychain"
security import "$DIR/cert.pem" -k "$KEYCHAIN" -A >/dev/null
security import "$DIR/key.pem"  -k "$KEYCHAIN" -A -T /usr/bin/codesign >/dev/null

if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "==> done. Rebuild/reinstall (scripts/install.sh); your Accessibility grant will now persist."
else
    echo "!! identity not found after import — falling back to ad-hoc signing." >&2
    exit 1
fi
