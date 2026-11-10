#!/bin/bash
# Compila BeyondClone e crea il bundle .app (non serve Xcode, bastano i Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")"

# I file intermedi stanno fuori dal Desktop: con la sincronizzazione iCloud
# il database di build di SwiftPM dà "disk I/O error".
SCRATCH="$HOME/Library/Caches/BeyondClone-build"
swift build -c release --scratch-path "$SCRATCH"

APP="BeyondClone.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SCRATCH/release/BeyondClone" "$APP/Contents/MacOS/BeyondClone"
cp Support/Info.plist "$APP/Contents/Info.plist"
if [ -f Support/AppIcon.icns ]; then
    cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Creato $APP"
