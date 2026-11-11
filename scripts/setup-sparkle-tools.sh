#!/bin/bash
# Downloads Sparkle's command-line tools (generate_keys, sign_update) into tools/sparkle.
# Keep SPARKLE_VERSION in sync with the version pinned in Package.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
SPARKLE_VERSION="2.10.1"
DEST="tools/sparkle"
if [ -x "$DEST/bin/sign_update" ] && [ "$(cat "$DEST/VERSION" 2>/dev/null)" == "$SPARKLE_VERSION" ]; then
  exit 0
fi
rm -rf "$DEST"
mkdir -p "$DEST"
TMP=$(mktemp -d)
gh release download "$SPARKLE_VERSION" --repo sparkle-project/Sparkle \
  --pattern "Sparkle-$SPARKLE_VERSION.tar.xz" --dir "$TMP"
tar -xJf "$TMP/Sparkle-$SPARKLE_VERSION.tar.xz" -C "$DEST" ./bin
echo "$SPARKLE_VERSION" > "$DEST/VERSION"
rm -rf "$TMP"
echo "Sparkle tools ready in $DEST/bin"
