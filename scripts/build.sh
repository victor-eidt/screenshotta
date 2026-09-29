#!/usr/bin/env bash
# Builds build/Screenshotta.app. Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/Screenshotta.app"

if [[ ! -f Resources/AppIcon.icns ]]; then
    iconset=$(swift scripts/make-icon.swift .)
    iconutil -c icns "$iconset" -o Resources/AppIcon.icns
fi

swift build -c "$CONFIG"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/Screenshotta" "$APP/Contents/MacOS/Screenshotta"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with a real identity when there is one: macOS keeps the Screen Recording
# permission across rebuilds only if the signature stays the same.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/"/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Screenshotta 2>/dev/null || true
    while pgrep -x Screenshotta >/dev/null; do sleep 0.2; done
    rm -rf /Applications/Screenshotta.app
    cp -R "$APP" /Applications/Screenshotta.app
    open /Applications/Screenshotta.app
    echo "Installed to /Applications/Screenshotta.app"
fi
