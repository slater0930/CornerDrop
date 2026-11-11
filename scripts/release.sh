#!/bin/bash
# Publishes a new version that installed copies of Corner Drop will auto-update to.
#
#   scripts/release.sh 1.2.0 "What changed in this version"
#
# Steps: bump version in Info.plist → build & sign → zip → sign the zip with the
# Sparkle key in your keychain → write appcast.xml → commit + tag → upload the zip
# as a GitHub Release → push main (which makes the new appcast live).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> \"release notes\"}"
NOTES="${2:-Corner Drop $VERSION}"
REPO="slater0930/CornerDrop"
PLIST="Resources/Info.plist"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: commit or stash your changes first." >&2
  exit 1
fi
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
  echo "error: v$VERSION already exists." >&2
  exit 1
fi

./scripts/setup-sparkle-tools.sh

BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST") + 1 ))
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $BUILD" "$PLIST"

./build.sh

# Privacy check: refuse to publish if the app contains anything identifying this Mac.
LEAKS=$(find build/CornerDrop.app -type f -print0 | xargs -0 strings -a 2>/dev/null \
  | grep -F -i -e "$HOME" -e "/Users/$(whoami)" -e "$(scutil --get LocalHostName)" \
              -e "$(scutil --get ComputerName)" -e "$(git config user.email)" | head -5 || true)
if [[ -n "$LEAKS" ]]; then
  echo "error: the built app contains identifying text, not publishing:" >&2
  echo "$LEAKS" >&2
  git checkout -- "$PLIST"
  exit 1
fi

mkdir -p releases
ZIP="releases/CornerDrop-$VERSION.zip"
rm -f "$ZIP"
# No extended attributes / resource forks: they can carry download-origin metadata.
ditto -c -k --norsrc --noextattr --noqtn --keepParent build/CornerDrop.app "$ZIP"

# Prints: sparkle:edSignature="…" length="…"
SIGNATURE=$(./tools/sparkle/bin/sign_update "$ZIP")
URL="https://github.com/$REPO/releases/download/v$VERSION/CornerDrop-$VERSION.zip"
PUBDATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
NOTES_HTML=$(printf '%s' "$NOTES" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' | awk '{printf "<p>%s</p>", $0}')

cat > appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Corner Drop</title>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[$NOTES_HTML]]></description>
      <enclosure url="$URL" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF

git add "$PLIST" appcast.xml
git commit -q -m "Release $VERSION"
git tag "v$VERSION"

# Upload the zip before the appcast goes live, so updaters never see a missing file.
git push -q origin "v$VERSION"
gh release create "v$VERSION" "$ZIP" --repo "$REPO" --verify-tag \
  --title "Corner Drop $VERSION" --notes "$NOTES"
git push -q origin main

echo "Released $VERSION (build $BUILD). Installed copies will pick it up on their next update check."
