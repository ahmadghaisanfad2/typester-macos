#!/bin/bash
set -euo pipefail

# Sets up a persistent self-signing identity named "Typester Developer" inside
# a DEDICATED keychain (not the login keychain), so `codesign` can use it
# non-interactively during release builds.
#
# Why a stable identity: ad-hoc signatures get a new cdhash on every build, so
# macOS TCC treats each rebuild as a different app and drops the Accessibility
# grant after every update. Signing every release with the SAME certificate
# keeps the designated requirement identical, so permissions survive updates.
#
# Files created (all under dist/signing/, which is gitignored — never commit):
#   TypesterDeveloper.p12        certificate + key backup (10-year validity)
#   TypesterDeveloper.p12.pass   p12 export passphrase
#   keychain.passphrase          password of the dedicated keychain
# The keychain itself: ~/Library/Keychains/typester-signing.keychain-db
#
# Restore on a new machine: keep the three files above, then run this script.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$PROJECT_DIR/dist/signing"
IDENTITY="Typester Developer"
KEYCHAIN="$HOME/Library/Keychains/typester-signing.keychain-db"

command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl is required." >&2; exit 1; }
mkdir -p "$BACKUP_DIR"

# 1) Certificate + p12 backup (generate once, keep for future machines)
if [[ ! -f "$BACKUP_DIR/TypesterDeveloper.p12" ]]; then
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    P12_PASS="$(head -c 18 /dev/urandom | base64 | tr +/ Aa)"

    echo "==> Generating self-signed code-signing certificate (10 years)..."
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
        -subj "/CN=$IDENTITY/O=Typester/C=US" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=codeSigning" \
        -addext "basicConstraints=critical,CA:FALSE" \
        2>/dev/null

    # macOS's pkcs12 importer predates OpenSSL 3 defaults; use the legacy
    # 3DES + SHA1 MAC scheme it can parse.
    openssl pkcs12 -export \
        -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
        -name "$IDENTITY" -passout pass:"$P12_PASS" \
        -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
        -out "$BACKUP_DIR/TypesterDeveloper.p12" 2>/dev/null

    echo "$P12_PASS" > "$BACKUP_DIR/TypesterDeveloper.p12.pass"
    chmod 600 "$BACKUP_DIR/TypesterDeveloper.p12" "$BACKUP_DIR/TypesterDeveloper.p12.pass"
else
    P12_PASS="$(cat "$BACKUP_DIR/TypesterDeveloper.p12.pass")"
    echo "==> Reusing existing certificate backup."
fi

# 2) Dedicated keychain the build script can unlock without any GUI prompt
if [[ ! -f "$KEYCHAIN" ]]; then
    KEYCHAIN_PASS="$(head -c 18 /dev/urandom | base64 | tr +/ Aa)"
    echo "==> Creating dedicated keychain $KEYCHAIN ..."
    security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
    echo "$KEYCHAIN_PASS" > "$BACKUP_DIR/keychain.passphrase"
    chmod 600 "$BACKUP_DIR/keychain.passphrase"
else
    KEYCHAIN_PASS="$(cat "$BACKUP_DIR/keychain.passphrase")"
    if ! security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN" 2>/dev/null; then
        echo "ERROR: could not unlock $KEYCHAIN with dist/signing/keychain.passphrase." >&2
        echo "       Delete the keychain and dist/signing/ to start fresh (a new identity" >&2
        echo "       means one final Accessibility re-grant)." >&2
        exit 1
    fi
fi

# 3) Import and pre-approve codesign access (no keychain prompts during builds)
if ! security find-identity "$KEYCHAIN" 2>/dev/null | grep -q "\"$IDENTITY\""; then
    echo "==> Importing identity into the signing keychain..."
    security import "$BACKUP_DIR/TypesterDeveloper.p12" \
        -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign
fi
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null

# 4) Make the identity discoverable (locked by default; unlocked during builds)
if ! security list-keychains -d user | grep -q "typester-signing"; then
    echo "==> Adding the signing keychain to the keychain search list..."
    LIST=()
    while IFS= read -r kc; do
        [[ -n "$kc" ]] && LIST+=("$kc")
    done < <(security list-keychains -d user | sed -n 's/^[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p')
    security list-keychains -d user -s "${LIST[@]}" "$KEYCHAIN"
fi

security lock-keychain "$KEYCHAIN" 2>/dev/null || true

echo "==> Done. Release builds will now sign with \"$IDENTITY\" without prompts."
echo "    Backups (keep private): $BACKUP_DIR"
