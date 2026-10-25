#!/bin/bash
# Removes the app. Data (principles, challenges, settings) is kept.
set -uo pipefail
APP="$HOME/Applications/Briefing.app"
# Remove the login item while the app can still answer for it.
if [ -x "$APP/Contents/MacOS/Briefing" ]; then
    "$APP/Contents/MacOS/Briefing" --remove-login-item
fi
launchctl bootout "gui/$(id -u)/local.morning.dashboard" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/local.morning.dashboard.plist"
pkill -x Briefing 2>/dev/null
pkill -x Morning 2>/dev/null
rm -rf "$APP" "$HOME/Applications/Morning.app"
echo "✓ Removed. Your data remains in ~/Library/Application Support/Briefing/"
