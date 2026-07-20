#!/bin/bash
set -euo pipefail

APP_NAME="ClaudeUsageTracker"
BUNDLE_ID="com.fiskaly.claude-usage-tracker"
INSTALL_DIR="$HOME/Applications"
LAUNCH_AGENT_PLIST="$HOME/Library/LaunchAgents/${BUNDLE_ID}.plist"

echo "=== Uninstalling ${APP_NAME} ==="

# Stop the app (match the install path precisely — never Beta/PREVIEW bundles or editors)
pkill -f "Applications/${APP_NAME}.app" 2>/dev/null || true

# Unload LaunchAgent
if [ -f "${LAUNCH_AGENT_PLIST}" ]; then
    launchctl unload "${LAUNCH_AGENT_PLIST}" 2>/dev/null || true
    rm -f "${LAUNCH_AGENT_PLIST}"
    echo "   LaunchAgent removed."
fi

# Remove app bundle
if [ -d "${INSTALL_DIR}/${APP_NAME}.app" ]; then
    rm -rf "${INSTALL_DIR}/${APP_NAME}.app"
    echo "   App removed from ${INSTALL_DIR}."
fi

# Remove statusline artifacts installed by the DMG installer (asymmetric before:
# the installer added these but uninstall left them, so Claude Code kept running
# a statusLine command pointing at a possibly-deleted script).
CLAUDE_DIR="$HOME/.claude"
STATUSLINE="${CLAUDE_DIR}/statusline.sh"
SETTINGS="${CLAUDE_DIR}/settings.json"

# 1. Strip the statusLine block from settings.json (preserve all other keys).
#    Abort the edit on a corrupt/unreadable file rather than risk clobbering it.
if [ -f "$SETTINGS" ] && command -v python3 >/dev/null 2>&1; then
    if python3 -c "
import json, os, sys, tempfile
path = sys.argv[1]
try:
    with open(path) as f:
        settings = json.load(f)
except FileNotFoundError:
    sys.exit(0)
except json.JSONDecodeError:
    sys.stderr.write('settings.json is not valid JSON — left untouched\n')
    sys.exit(1)
settings.pop('statusLine', None)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(settings, f, indent=2)
os.replace(tmp, path)
" "$SETTINGS" 2>/dev/null; then
        echo "   statusLine removed from settings.json."
    else
        echo "   NOTE: could not edit settings.json — remove the 'statusLine' block manually."
    fi
fi

# 2. Remove the statusline script (and any backups it left).
if [ -f "$STATUSLINE" ]; then
    rm -f "$STATUSLINE"
    echo "   statusline.sh removed."
fi
rm -f "${CLAUDE_DIR}"/statusline.sh.bak-* 2>/dev/null || true

# 3. Remove the usage data + lock (comment out to keep your history).
rm -f "${CLAUDE_DIR}/monthly_usage.json" 2>/dev/null || true
rm -rf "${CLAUDE_DIR}/.monthly_usage.lock" 2>/dev/null || true

echo ""
echo "Done! ${APP_NAME} has been uninstalled."
