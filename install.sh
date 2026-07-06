#!/bin/bash
# Build AllNighter and install it as a login-item menu-bar agent.
set -euo pipefail
cd "$(dirname "$0")"

./scripts/build-app.sh

APP_SRC="dist/AllNighter.app"
APP_DST="$HOME/Applications/AllNighter.app"
mkdir -p "$HOME/Applications"
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

LABEL="com.allnighter.mac"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__EXEC__|$APP_DST/Contents/MacOS/AllNighter|g" \
    packaging/com.allnighter.mac.plist > "$PLIST"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "✅ AllNighter installed and running — look for the pill in your menu bar."
echo "   App:   $APP_DST"
echo "   Agent: $PLIST"
echo
echo "Left-click the pill to keep the display awake; right-click for the"
echo "\"Keep awake with lid closed\" option."
