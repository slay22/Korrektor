#!/bin/bash
# Builds Korrektor.app from the SwiftPM executable.
set -euo pipefail

cd "$(dirname "$0")/.."

# SwiftUI's macros need the full Xcode toolchain, not just the Command Line Tools.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

CONFIGURATION=${1:-release}
swift build -c "$CONFIGURATION" --product KorrektorApp
BIN_PATH=$(swift build -c "$CONFIGURATION" --product KorrektorApp --show-bin-path)

APP="build/Korrektor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/KorrektorApp" "$APP/Contents/MacOS/Korrektor"

VERSION="1.1.0"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Korrektor</string>
    <key>CFBundleDisplayName</key>
    <string>Korrektor</string>
    <key>CFBundleExecutable</key>
    <string>Korrektor</string>
    <key>CFBundleIdentifier</key>
    <string>de.arte.korrektor</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>27.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signing means the app's designated requirement is a bare cdhash, so
# every rebuild is a different app to TCC and an Accessibility grant stops
# applying. Set SIGN_IDENTITY to a (self-signed) code-signing certificate to get
# a requirement that survives rebuilds, e.g.:
#   SIGN_IDENTITY="Korrektor Dev" ./Scripts/build-app.sh
SIGN_IDENTITY=${SIGN_IDENTITY:--}
if ! codesign --force --sign "$SIGN_IDENTITY" "$APP" >/dev/null 2>&1; then
    echo "Warning: signing with '$SIGN_IDENTITY' failed – the app still runs locally."
fi
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "Signed ad-hoc: macOS may forget the Accessibility grant on the next rebuild."
fi

echo "Gebaut: $PWD/$APP"
