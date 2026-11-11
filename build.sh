#!/bin/bash
# Builds Corner Drop into a .app bundle.
#   ./build.sh            build into ./build/CornerDrop.app
#   ./build.sh --install  also copy to ~/Applications and (re)launch it
#
# Signing: uses the "Corner Drop Signing" certificate from your login keychain if it
# exists (keeps macOS permissions across updates), otherwise an ad-hoc signature.
set -euo pipefail
cd "$(dirname "$0")"

# -file-prefix-map keeps this Mac's folder paths out of the compiled app.
swift build -c release -Xswiftc -file-prefix-map -Xswiftc "$PWD/=./"

APP="build/CornerDrop.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp .build/release/CornerDrop "$APP/Contents/MacOS/CornerDrop"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Embed Sparkle (ditto keeps the framework's symlinks intact).
SPARKLE=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"

# Drop debug symbols (smaller app, no local paths).
strip -x "$APP/Contents/MacOS/CornerDrop"

IDENTITY="Corner Drop Signing"
if ! security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  echo "warning: '$IDENTITY' certificate not found; using ad-hoc signature" >&2
  IDENTITY="-"
fi

# Sign inside-out: Sparkle's helpers, the framework, then the app.
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force --sign "$IDENTITY" "$FW/XPCServices/Installer.xpc"
codesign --force --sign "$IDENTITY" --preserve-metadata=entitlements "$FW/XPCServices/Downloader.xpc"
codesign --force --sign "$IDENTITY" "$FW/Autoupdate"
codesign --force --sign "$IDENTITY" "$FW/Updater.app"
codesign --force --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP (signed with: $IDENTITY)"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x CornerDrop 2>/dev/null || true
  sleep 1
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/CornerDrop.app"
  ditto "$APP" "$HOME/Applications/CornerDrop.app"
  open "$HOME/Applications/CornerDrop.app"
  echo "Installed to ~/Applications/CornerDrop.app and launched"
fi
