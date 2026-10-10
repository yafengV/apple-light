#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
agent_target="${CARGO_TARGET_DIR:-$PWD/target}"
mode="${1:---app}"
case "$mode" in
    --app|--verify|--build-app) if [ "$#" -gt 0 ]; then shift; fi ;;
    *) cargo build --locked -p shipios-agent
       exec "$agent_target/debug/shipios-agent" --data-dir "$PWD/.shipios-local" "$@" ;;
esac
source script/macos_signing.sh
shipios_resolve_codesign_identity
if [ "$mode" != "--build-app" ]; then
    # Exact executable name; the helper sees EOF and cancels any active child command.
    pkill -TERM -x ShipiOS 2>/dev/null || true
fi
cargo build --locked -p shipios-agent
# Allow an isolated native build while another test runner owns the default cache.
build_cache="${SHIPIOS_BUILD_CACHE_ROOT:-$PWD/.cache}"
mkdir -p "$build_cache/clang-module-cache" "$build_cache/swiftpm-cache"
export CLANG_MODULE_CACHE_PATH="$build_cache/clang-module-cache"
# Use the selected Xcode toolchain, independent of a user's standalone Swift.
# The native builder preserves this package's existing SwiftTerm resource flow.
xcrun swift build --build-system "${SHIPIOS_SWIFTPM_BUILD_SYSTEM:-native}" --package-path apps/macos --scratch-path "$build_cache/macos-build" --cache-path "$build_cache/swiftpm-cache" --disable-sandbox
app="$PWD/dist/ShipiOS.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp "$build_cache/macos-build/debug/ShipiOS" "$app/Contents/MacOS/ShipiOS"
cp "$agent_target/debug/shipios-agent" "$app/Contents/Helpers/shipios-agent"
ditto "$build_cache/macos-build/debug/SwiftTerm_SwiftTerm.bundle" "$app/Contents/Resources/SwiftTerm_SwiftTerm.bundle"
ditto "$build_cache/macos-build/debug/ShipiOS_ShipiOS.bundle" "$app/Contents/Resources/ShipiOS_ShipiOS.bundle"
install -m 644 "$build_cache/macos-build/checkouts/SwiftTerm/LICENSE" "$app/Contents/Resources/SwiftTerm-LICENSE.txt"
ditto licenses "$app/Contents/Resources/Licenses"
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
<key>NSMicrophoneUsageDescription</key><string>在你启动听写或语音聊天时使用麦克风。</string>
<key>NSAudioCaptureUsageDescription</key><string>在你开启音频可视化时读取系统播放声音，仅在本机计算导航轨道动画。</string>
<key>NSSpeechRecognitionUsageDescription</key><string>使用设备端语音识别将讲话内容加入任务草稿。</string>
<key>CFBundleURLTypes</key><array><dict>
<key>CFBundleURLName</key><string>dev.shipios.desktop</string>
<key>CFBundleURLSchemes</key><array><string>shipios</string></array>
</dict></array>
</dict></plist>
PLIST
shipios_sign_macos_app "$app"
if [ "$mode" == "--build-app" ]; then exit 0; fi
/usr/bin/open -n "$app" --args "$@"
if [ "$mode" == "--verify" ]; then
    sleep 2
    pgrep -x ShipiOS
fi
