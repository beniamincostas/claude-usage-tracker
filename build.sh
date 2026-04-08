#!/bin/bash
set -euo pipefail

APP_NAME="ClaudeUsageTracker"
BUNDLE_ID="com.fiskaly.claude-usage-tracker"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/.build/release"
APP_DIR="${SCRIPT_DIR}/${APP_NAME}.app"
INSTALL_DIR="$HOME/Applications"
LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT_PLIST="${LAUNCH_AGENT_DIR}/${BUNDLE_ID}.plist"

# Use Command Line Tools to avoid Xcode license requirement
export DEVELOPER_DIR=/Library/Developer/CommandLineTools

echo "=== Building ${APP_NAME} ==="
cd "$SCRIPT_DIR"
swift build -c release 2>&1

echo ""
echo "=== Creating .app bundle ==="
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

cat > "${APP_DIR}/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>ClaudeUsageTracker</string>
    <key>CFBundleIdentifier</key>
    <string>com.fiskaly.claude-usage-tracker</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleExecutable</key>
    <string>ClaudeUsageTracker</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Built by Beniamin Costas — linkedin.com/in/beniamincostas — Finance Engineering @ fiskaly GmbH</string>
</dict>
</plist>
PLIST

echo "   Bundle created: ${APP_DIR}"

echo ""
echo "=== Signing .app bundle (ad-hoc) ==="
codesign --force --deep --sign - "${APP_DIR}"
echo "   Signed."

echo ""
echo "=== Installing to ${INSTALL_DIR} ==="
mkdir -p "${INSTALL_DIR}"
rm -rf "${INSTALL_DIR}/${APP_NAME}.app"
cp -R "${APP_DIR}" "${INSTALL_DIR}/"
echo "   Installed."

echo ""
echo "=== Setting up autostart (LaunchAgent) ==="
mkdir -p "${LAUNCH_AGENT_DIR}"

# Use plistlib for safe XML escaping (handles spaces and special chars in paths)
python3 -c "
import plistlib, sys
plist = {
    'Label': sys.argv[1],
    'ProgramArguments': [sys.argv[2]],
    'RunAtLoad': True,
    'KeepAlive': False,
}
with open(sys.argv[3], 'wb') as f:
    plistlib.dump(plist, f)
" "${BUNDLE_ID}" "${INSTALL_DIR}/${APP_NAME}.app/Contents/MacOS/${APP_NAME}" "${LAUNCH_AGENT_PLIST}"

echo "   LaunchAgent created (autostart at login)."

echo ""
echo "=== Starting ${APP_NAME} ==="
# Kill any existing instance first, then launch exactly one
pkill -f "${APP_NAME}" 2>/dev/null || true
sleep 0.5
open "${INSTALL_DIR}/${APP_NAME}.app"

echo ""
echo "Done! Look for the bar in your menu bar."
echo ""
echo "To uninstall, run: ./uninstall.sh"
