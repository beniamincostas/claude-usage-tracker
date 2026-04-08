#!/bin/bash
set -euo pipefail

APP_NAME="ClaudeUsageTracker"
BUNDLE_ID="com.fiskaly.claude-usage-tracker"
INSTALL_DIR="$HOME/Applications"
LAUNCH_AGENT_PLIST="$HOME/Library/LaunchAgents/${BUNDLE_ID}.plist"

echo "=== Uninstalling ${APP_NAME} ==="

# Stop the app
pkill -f "${APP_NAME}" 2>/dev/null || true

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

echo ""
echo "Done! ${APP_NAME} has been uninstalled."
