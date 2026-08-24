#!/bin/bash
set -euo pipefail

# Build a local DMG and publish it as a GitHub Release.
# Does not use GitHub Actions (useful when Actions minutes are exhausted).
# Uses githubOwner/githubRepo from Models.swift so origin+upstream remotes don't confuse `gh`.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

eval "$(python3 - <<'PY'
import re
from pathlib import Path
text = Path("Sources/TypesterLogic/Models.swift").read_text()
version = re.search(r'appVersion\s*=\s*"([^"]+)"', text)
owner = re.search(r'githubOwner\s*=\s*"([^"]+)"', text)
repo = re.search(r'githubRepo\s*=\s*"([^"]+)"', text)
if not version:
    raise SystemExit("Could not find appVersion in Models.swift")
if not owner or not repo:
    raise SystemExit("Could not find githubOwner/githubRepo in Models.swift")
print(f'VERSION="{version.group(1)}"')
print(f'GH_REPO="{owner.group(1)}/{repo.group(1)}"')
PY
)"

TAG="v${VERSION}"
DMG_PATH="$PROJECT_DIR/dist/Typester-${VERSION}.dmg"
NOTES_FILE="$(mktemp)"

cleanup() {
    rm -f "$NOTES_FILE"
}
trap cleanup EXIT

echo "==> Publishing Typester ${VERSION} (${TAG}) to ${GH_REPO}"

# Keep build-release.sh VERSION in sync
if grep -q '^VERSION=' "$SCRIPT_DIR/build-release.sh"; then
    sed -i.bak "s/^VERSION=.*/VERSION=\"${VERSION}\"/" "$SCRIPT_DIR/build-release.sh"
    rm -f "$SCRIPT_DIR/build-release.sh.bak"
fi

echo "==> Building release DMG..."
"$SCRIPT_DIR/build-release.sh"

if [[ ! -f "$DMG_PATH" ]]; then
    echo "ERROR: Expected DMG not found at $DMG_PATH" >&2
    exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: gh CLI is required. Install from https://cli.github.com/" >&2
    exit 1
fi

cat > "$NOTES_FILE" <<EOF
## Typester ${VERSION}

Local release built with \`scripts/build-release.sh\` and published with \`scripts/publish-release.sh\`.

### Install
1. Download \`Typester-${VERSION}.dmg\`
2. Open the DMG and drag Typester to Applications
3. If Gatekeeper blocks an unsigned build: Right-click → Open

### Updating
Already running Typester 1.15.0 or newer? Update from the app itself — menu bar
icon → Check for Updates… (or Settings → Check for Updates). The update installs
in place and relaunches.

When upgrading from 1.15.2 or earlier, the old authorization does not transfer
automatically. Complete both one-time steps:

1. In the Keychain prompt, enter your Mac login password and click **Always
   Allow** (not Allow Once) for the existing API key.
2. In System Settings → Privacy & Security → Accessibility, remove the old
   Typester entry, add /Applications/Typester.app, enable it, and relaunch.

Future releases signed with the same stable identity keep these grants.
EOF

if gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
    echo "==> Release ${TAG} already exists — uploading/replacing DMG asset..."
    gh release upload "$TAG" "$DMG_PATH" --repo "$GH_REPO" --clobber
else
    echo "==> Creating GitHub release ${TAG}..."
    gh release create "$TAG" "$DMG_PATH" \
        --repo "$GH_REPO" \
        --title "Typester ${VERSION}" \
        --notes-file "$NOTES_FILE"
fi

echo ""
echo "==> Published ${TAG}"
echo "    Release page: $(gh release view "$TAG" --repo "$GH_REPO" --json url -q .url)"
echo "    Asset: $DMG_PATH"
echo ""
echo "Logged-in users can download from the release page. Check for Updates needs a public repo (or auth)."
