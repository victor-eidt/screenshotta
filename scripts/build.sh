#!/usr/bin/env bash
# Builds build/ScreenOtter.app. Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/ScreenOtter.app"

if [[ ! -f Resources/AppIcon.icns ]]; then
    swift scripts/make-icons.swift
fi

swift build -c "$CONFIG"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/ScreenOtter" "$APP/Contents/MacOS/ScreenOtter"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png Resources/OtterHero.jpg "$APP/Contents/Resources/"
# Text tool typefaces (SIL OFL) and their licenses, registered at launch.
cp -R Resources/Fonts "$APP/Contents/Resources/"

# Sign with a real identity when there is one: macOS keeps the Screen Recording
# permission across rebuilds only if the signature stays the same.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/"/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
    # The app used to be called Screenshotta: quit and replace that one too.
    for name in ScreenOtter Screenshotta; do
        pkill -x "$name" 2>/dev/null || true
        while pgrep -x "$name" >/dev/null; do sleep 0.2; done
    done
    rm -rf /Applications/Screenshotta.app /Applications/ScreenOtter.app
    cp -R "$APP" /Applications/ScreenOtter.app
    open /Applications/ScreenOtter.app
    echo "Installed to /Applications/ScreenOtter.app"
fi
