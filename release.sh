#!/bin/bash
# Builds a release into ./dist, ready to attach to a GitHub release:
#   Briefing-X.Y.Z.dmg   — what people download from the release page
#   Briefing-X.Y.Z.zip   — what installed copies update from (Sparkle)
#   appcast.xml          — the update feed (Info.plist → SUFeedURL points at the latest release's copy)
#
#   ./release.sh 1.0.0
#
# Needs tools/setup-signing.sh to have run once on this Mac. Publishing is left to you (printed at the end).
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Usage: ./release.sh X.Y.Z"; exit 1; }

CERT_NAME="Briefing Self-Signed"
ACCOUNT="io.github.vanodium.briefing"
REPO="Vanodium/Briefing"
PLIST="Resources/Info.plist"
TOOLS=".build/artifacts/sparkle/Sparkle/bin"
DIST="dist"
TAG="v$VERSION"

# MARK: Checks

security find-certificate -c "$CERT_NAME" >/dev/null 2>&1 \
    || { echo "No \"$CERT_NAME\" certificate — run tools/setup-signing.sh first"; exit 1; }
[ -x "$TOOLS/sign_update" ] || swift package resolve
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")"
[ -n "$PUBLIC_KEY" ] || { echo "SUPublicEDKey is empty — run tools/setup-signing.sh first"; exit 1; }
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"

# MARK: Version

# The build number only ever goes up: Sparkle compares it to decide what is newer.
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
BUILD=$((BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
echo "→ Briefing $VERSION (build $BUILD)"

# MARK: Build

SIGN_IDENTITY="$CERT_NAME" UNIVERSAL=1 ./build.sh

rm -rf "$DIST"
mkdir -p "$DIST"
ZIP="$DIST/Briefing-$VERSION.zip"
DMG="$DIST/Briefing-$VERSION.dmg"

echo "→ Archiving $ZIP"
ditto -c -k --sequesterRsrc --keepParent build/Briefing.app "$ZIP"

echo "→ Disk image $DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto build/Briefing.app "$STAGE/Briefing.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Briefing $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"

# MARK: Appcast

echo "→ Signing the update"
SIGNATURE="$("$TOOLS/sign_update" --account "$ACCOUNT" "$ZIP")"   # sparkle:edSignature="…" length="…"
DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

cat > "$DIST/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Briefing</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>Briefing $VERSION</title>
      <pubDate>$DATE</pubDate>
      <link>https://github.com/$REPO/releases/tag/$TAG</link>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:fullReleaseNotesLink>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/Briefing-$VERSION.zip"
                 type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
EOF

SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"

echo
echo "✓ Release $VERSION is in $DIST/"
echo "  Architectures: $(lipo -archs build/Briefing.app/Contents/MacOS/Briefing)"
echo "  SHA-256 of the disk image: $SHA"
echo
echo "To publish (commit the version bump in $PLIST first):"
echo "  gh release create $TAG $DMG $ZIP $DIST/appcast.xml --repo $REPO --title \"Briefing $VERSION\" --notes \"…\""
