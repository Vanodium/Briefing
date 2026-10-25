#!/bin/bash
# Builds Briefing.app into ./build. Only Swift is needed (Xcode or Command Line Tools).
#   SIGN_IDENTITY="Briefing Self-Signed" ./build.sh   — sign with the release certificate (see tools/setup-signing.sh)
#   UNIVERSAL=1 ./build.sh                            — Apple silicon + Intel in one app (releases); otherwise this Mac's only
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Briefing.app"
BUNDLE_ID="io.github.vanodium.briefing"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # "-" = local ad-hoc signature

UNIVERSAL="${UNIVERSAL:-0}"

if [ "$UNIVERSAL" = 1 ]; then
    BINS=()
    for ARCH in arm64 x86_64; do
        echo "→ Building (release, $ARCH)…"
        swift build -c release --triple "$ARCH-apple-macosx14.0"
        BINS+=("$(swift build -c release --triple "$ARCH-apple-macosx14.0" --show-bin-path)/Briefing")
    done
    BIN="$(mktemp -d)/Briefing"
    lipo -create "${BINS[@]}" -output "$BIN"
else
    echo "→ Building (release)…"
    swift build -c release
    BIN="$(swift build -c release --show-bin-path)/Briefing"
fi
FRAMEWORK="$(find .build/artifacts -path '*macos-arm64_x86_64/Sparkle.framework' -maxdepth 6 -type d | head -1)"
[ -d "$FRAMEWORK" ] || { echo "Sparkle.framework not found — run: swift package resolve"; exit 1; }

echo "→ Packaging $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Briefing"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
ditto "$FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$APP/Contents/Resources/Sparkle-LICENSE.txt"

echo "→ Signing ($SIGN_IDENTITY)"
# Inside out: Sparkle's helpers, the framework, then the app (as Sparkle's documentation describes).
S="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign -f -s "$SIGN_IDENTITY" -o runtime "$S/XPCServices/Installer.xpc"
codesign -f -s "$SIGN_IDENTITY" -o runtime --preserve-metadata=entitlements "$S/XPCServices/Downloader.xpc"
codesign -f -s "$SIGN_IDENTITY" -o runtime "$S/Autoupdate"
codesign -f -s "$SIGN_IDENTITY" -o runtime "$S/Updater.app"
codesign -f -s "$SIGN_IDENTITY" -o runtime "$APP/Contents/Frameworks/Sparkle.framework"
codesign -f -s "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict "$APP"

echo "✓ Done: $APP"
