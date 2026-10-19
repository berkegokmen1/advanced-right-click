#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ARCH="${ARCH:-$(uname -m)}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
APP="$PWD/build/release/Advanced Right Click.app"
EXT="$APP/Contents/PlugIns/AdvancedFinder.appex"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$EXT/Contents/MacOS" build/ModuleCache build/tmp
COMMON=(-swift-version 5 -module-cache-path "$PWD/build/ModuleCache" -target "$ARCH-apple-macos13.0")
FRAMEWORKS=(-framework AppKit -framework SwiftUI -framework ImageIO -framework PDFKit -framework Vision -framework AVKit -framework AVFoundation -framework CoreText -framework ServiceManagement -framework ApplicationServices)
xcrun swiftc "${COMMON[@]}" -import-objc-header Config/Bridging.h -O Sources/*.swift -o build/tmp/AdvancedRightClick "${FRAMEWORKS[@]}"
xcrun swiftc "${COMMON[@]}" -import-objc-header Config/Bridging.h -O -application-extension -module-name AdvancedFinder Sources/Actions.swift Sources/MenuPreferences.swift Sources/ActionMenu.swift FinderExtension/*.swift -o build/tmp/AdvancedFinder -framework FinderSync -framework AppKit
mv build/tmp/AdvancedRightClick "$APP/Contents/MacOS/AdvancedRightClick"
mv build/tmp/AdvancedFinder "$EXT/Contents/MacOS/AdvancedFinder"
cp Config/AppInfo.plist "$APP/Contents/Info.plist"
cp Config/FinderInfo.plist "$EXT/Contents/Info.plist"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp NOTICE "$APP/Contents/Resources/NOTICE.txt"
xcrun swift "${COMMON[@]}" scripts/icon.swift "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "$SIGNING_IDENTITY" --entitlements Config/Finder.entitlements "$EXT"
codesign --force --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
pkgbuild --component "$APP" --install-location /Applications --identifier com.berkegokmen.advancedrightclick --version 0.1.4 "$PWD/build/AdvancedRightClick-0.1.4.pkg"
printf '\nApp: %s\nInstaller: %s\n' "$APP" "$PWD/build/AdvancedRightClick-0.1.4.pkg"
