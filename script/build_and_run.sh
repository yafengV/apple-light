#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:---app}"
case "$mode" in
    --app|--verify|--build-app) if [ "$#" -gt 0 ]; then shift; fi ;;
    *) cargo build --locked -p shipios-agent
       exec ./target/debug/shipios-agent --data-dir "$PWD/.shipios-local" "$@" ;;
esac
if [ "$mode" != "--build-app" ]; then
    # Exact executable name; the helper sees EOF and cancels any active child command.
    pkill -TERM -x ShipiOS 2>/dev/null || true
fi
cargo build --locked -p shipios-agent
mkdir -p "$PWD/.cache/clang-module-cache" "$PWD/.cache/swiftpm-cache"
export CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang-module-cache"
swift build --package-path apps/macos --scratch-path "$PWD/.cache/macos-build" --cache-path "$PWD/.cache/swiftpm-cache" --disable-sandbox
app="$PWD/dist/ShipiOS.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp .cache/macos-build/debug/ShipiOS "$app/Contents/MacOS/ShipiOS"
cp target/debug/shipios-agent "$app/Contents/Helpers/shipios-agent"
ditto .cache/macos-build/debug/SwiftTerm_SwiftTerm.bundle "$app/Contents/Resources/SwiftTerm_SwiftTerm.bundle"
install -m 644 .cache/macos-build/checkouts/SwiftTerm/LICENSE "$app/Contents/Resources/SwiftTerm-LICENSE.txt"
ditto fixtures/HelloShipiOS "$app/Contents/Resources/HelloShipiOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleExecutable</key><string>ShipiOS</string>
<key>CFBundleIdentifier</key><string>dev.shipios.desktop</string>
<key>CFBundleName</key><string>ShipiOS</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleURLTypes</key><array><dict>
<key>CFBundleURLName</key><string>dev.shipios.desktop</string>
<key>CFBundleURLSchemes</key><array><string>shipios</string></array>
</dict></array>
</dict></plist>
PLIST
codesign --force --sign - "$app/Contents/Helpers/shipios-agent"
codesign --force --sign - "$app"
if [ "$mode" == "--build-app" ]; then exit 0; fi
/usr/bin/open -n "$app" --args "$@"
if [ "$mode" == "--verify" ]; then
    sleep 2
    pgrep -x ShipiOS
fi
