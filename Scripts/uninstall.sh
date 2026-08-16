#!/bin/bash
# Curtain uninstaller. Removes /Applications/Curtain.app. The login item,
# disconnect daemon, and crash-supervision agent are unregistered from inside
# the app (SMAppService) before you delete it; this script also defensively
# cleans up files left by older installs (LaunchAgent, /usr/local/bin helper,
# sudoers rule) — only prompting for admin if any of those legacy files
# actually exist.
set -uo pipefail

AGENT="$HOME/Library/LaunchAgents/io.acamarata.curtain.plist"
LEGACY_HELPER="/usr/local/bin/curtain-endsession"
LEGACY_SUDOERS="/etc/sudoers.d/curtain-endsession"

echo "==> Stopping Curtain…"
# Stop Curtain BEFORE any launchd unregistration below: pkill first means the
# app's own SMAppService.agent-registered KeepAlive(SuccessfulExit:false) never
# gets a chance to treat this deliberate stop as an abnormal exit needing a
# relaunch (T-P1-E08-03) — the process is already gone by the time uninstall
# touches SMAppService registrations, so there's nothing left for launchd to
# "relaunch" against.
pkill -x Curtain 2>/dev/null || true

# Legacy LaunchAgent (newer installs use SMAppService.mainApp instead).
if [ -f "$AGENT" ]; then
  echo "==> Removing legacy login agent…"
  launchctl unload "$AGENT" 2>/dev/null || true
  rm -f "$AGENT"
fi

# SMAppService.agent crash-supervision registration (T-P1-E08-03). Registered
# from inside the running app (AppSupervisor.register()); with the app already
# stopped above there's no in-app path left to call AppSupervisor.unregister(),
# so defensively bootout the user-domain service by label directly — idempotent
# and harmless if it was never registered.
launchctl bootout "gui/$(id -u)/io.acamarata.curtain.supervisor" 2>/dev/null || true

echo "==> Removing app + settings…"
rm -rf "/Applications/Curtain.app"
rm -rf "$HOME/Library/Application Support/Curtain"

# Legacy root helper + sudoers rule. Only escalate if something is actually
# there, so a clean uninstall never triggers an admin prompt.
if [ -e "$LEGACY_HELPER" ] || [ -e "$LEGACY_SUDOERS" ]; then
  echo "==> Removing legacy root helper (needs admin)…"
  osascript -e "do shell script \"rm -f '$LEGACY_HELPER' '$LEGACY_SUDOERS'\" with administrator privileges" || true
fi

echo "✅ Curtain uninstalled. You may also remove it from System Settings → Privacy & Security → Accessibility."
