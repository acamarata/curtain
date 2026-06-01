#!/bin/bash
# Curtain uninstaller — removes the app, login agent, and root helper.
set -uo pipefail

AGENT="$HOME/Library/LaunchAgents/io.acamarata.curtain.plist"

echo "==> Stopping agent…"
launchctl unload "$AGENT" 2>/dev/null || true
rm -f "$AGENT"
pkill -x Curtain 2>/dev/null || true

echo "==> Removing app + settings…"
rm -rf "/Applications/Curtain.app"
rm -rf "$HOME/Library/Application Support/Curtain"

echo "==> Removing root helper (needs admin)…"
osascript -e "do shell script \"rm -f /usr/local/bin/curtain-endsession /etc/sudoers.d/curtain-endsession\" with administrator privileges" || true

echo "✅ Curtain uninstalled. You may also remove it from System Settings → Privacy → Accessibility."
