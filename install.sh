#!/bin/bash
# For development: build, install into ~/Applications and relaunch.
# Opening at login is a login item the app registers itself (onboarding or Settings → General).
set -euo pipefail
cd "$(dirname "$0")"

DEST="$HOME/Applications/Briefing.app"

./build.sh

echo "→ Stopping the running copy"
# Earlier builds were called Morning and started from a LaunchAgent. The agent's file is left
# in place for one more launch: the app turns it into a login item and removes it.
launchctl bootout "gui/$(id -u)/local.morning.dashboard" 2>/dev/null || true
pkill -x Briefing 2>/dev/null || true
pkill -x Morning 2>/dev/null || true
sleep 1

echo "→ Installing to $DEST"
mkdir -p "$HOME/Applications"
rm -rf "$DEST" "$HOME/Applications/Morning.app"
cp -R build/Briefing.app "$DEST"
touch "$DEST"   # refresh the icon in Finder

echo "→ Starting"
open "$DEST"

echo
echo "✓ Briefing is installed and running (a small grid icon in the menu bar)."
echo "  Data:  ~/Library/Application Support/Briefing/"
echo "  Log:   ~/Library/Logs/Briefing.log"
