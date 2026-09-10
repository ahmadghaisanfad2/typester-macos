#!/bin/bash
# Import the stable Typester signing identity into an ephemeral CI keychain
# so release builds keep the same designated requirement as local builds.
# Without this, GitHub Actions falls back to ad-hoc signing and macOS drops
# Accessibility / Microphone on every update.
#
# Required repository secrets:
#   TYPESTER_SIGNING_P12_BASE64  — base64 of dist/signing/TypesterDeveloper.p12
#   TYPESTER_SIGNING_P12_PASSWORD — passphrase from dist/signing/TypesterDeveloper.p12.pass
#
# Optional:
#   TYPESTER_SIGNING_KEYCHAIN_PASSWORD — password for the ephemeral keychain
set -euo pipefail

IDENTITY="Typester Developer"
KEYCHAIN="typester-signing.keychain-db"
KEYCHAIN_PATH="${RUNNER_TEMP:-/tmp}/${KEYCHAIN}"

if [[ -z "${TYPESTER_SIGNING_P12_BASE64:-}" ]]; then
    echo "==> TYPESTER_SIGNING_P12_BASE64 not set — builds will ad-hoc sign."
    echo "    Add the stable identity secrets so TCC permissions survive updates."
    exit 0
fi

P12_PASS="${TYPESTER_SIGNING_P12_PASSWORD:-}"
if [[ -z "$P12_PASS" ]]; then
    echo "ERROR: TYPESTER_SIGNING_P12_PASSWORD is required when the P12 secret is set." >&2
    exit 1
fi

KEYCHAIN_PASS="${TYPESTER_SIGNING_KEYCHAIN_PASSWORD:-typester-ci-$(date +%s)}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Importing stable signing identity for CI..."
printf '%s' "$TYPESTER_SIGNING_P12_BASE64" | base64 --decode > "$WORK/TypesterDeveloper.p12"

security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN_PATH" >/dev/null
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN_PATH"

security import "$WORK/TypesterDeveloper.p12" \
    -k "$KEYCHAIN_PATH" -P "$P12_PASS" -T /usr/bin/codesign

security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN_PATH" >/dev/null

# Put the ephemeral keychain first so codesign finds "Typester Developer".
security list-keychains -d user -s "$KEYCHAIN_PATH"
security list-keychains -d user

if security find-identity -v -p codesigning "$KEYCHAIN_PATH" | grep -q "\"$IDENTITY\""; then
    echo "==> CI signing identity ready: $IDENTITY"
    echo "TYPESTER_CI_SIGNING_KEYCHAIN=$KEYCHAIN_PATH" >> "${GITHUB_ENV:-/dev/null}"
else
    echo "ERROR: imported P12 does not contain \"$IDENTITY\"" >&2
    exit 1
fi
