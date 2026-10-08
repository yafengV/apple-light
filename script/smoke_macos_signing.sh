#!/bin/bash
# Real certificate + two different Mach-O builds; no app is launched and no
# privacy database or keychain permissions are modified.
set -euo pipefail
cd "$(dirname "$0")/.."
source script/macos_signing.sh
if (unset SHIPIOS_CODESIGN_IDENTITY
    shipios_list_codesign_identities() { :; }
    shipios_resolve_codesign_identity) > /dev/null 2>&1; then
    printf '%s\n' 'An unavailable certificate must fail instead of silently downgrading signing.' >&2
    exit 1
fi
(SHIPIOS_CODESIGN_IDENTITY=-
    shipios_resolve_codesign_identity
    test "$shipios_codesign_identity" = "-") > /dev/null 2>&1
shipios_resolve_codesign_identity
if [ "$shipios_codesign_identity" = "-" ]; then
    printf '%s\n' 'A certificate identity is required for the stable-signature smoke test.' >&2
    exit 2
fi
signing_fixture="$(mktemp -d "${TMPDIR:-/tmp}/shipios-signing.XXXXXX")"
trap 'rm -rf "$signing_fixture"' EXIT
signing_app="$signing_fixture/ShipiOS.app"
mkdir -p "$signing_app/Contents/MacOS" "$signing_app/Contents/Helpers"
cat > "$signing_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.shipios.desktop</string>
<key>CFBundleExecutable</key><string>ShipiOS</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
build_fixture() {
    printf '#include <stdio.h>\nint main(void) { puts("build %s"); return 0; }\n' "$1" > "$signing_fixture/main.c"
    /usr/bin/xcrun clang "$signing_fixture/main.c" -o "$signing_app/Contents/MacOS/ShipiOS"
    cp "$signing_app/Contents/MacOS/ShipiOS" "$signing_app/Contents/Helpers/shipios-agent"
    shipios_sign_macos_app "$signing_app"
}
requirement() { /usr/bin/codesign -d -r- "$1" 2>&1 | /usr/bin/sed -n 's/^designated => //p'; }
code_hash() { /usr/bin/codesign -dvvv "$1" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p'; }
build_fixture first
app_requirement="$(requirement "$signing_app")"
helper_requirement="$(requirement "$signing_app/Contents/Helpers/shipios-agent")"
app_hash="$(code_hash "$signing_app")"
helper_hash="$(code_hash "$signing_app/Contents/Helpers/shipios-agent")"
test -n "$app_requirement"
test -n "$helper_requirement"
test -n "$app_hash"
test -n "$helper_hash"
build_fixture second
test "$app_hash" != "$(code_hash "$signing_app")"
test "$helper_hash" != "$(code_hash "$signing_app/Contents/Helpers/shipios-agent")"
test "$app_requirement" = "$(requirement "$signing_app")"
test "$helper_requirement" = "$(requirement "$signing_app/Contents/Helpers/shipios-agent")"
/usr/bin/codesign --verify --strict -R "=$app_requirement" "$signing_app"
/usr/bin/codesign --verify --strict -R "=$helper_requirement" "$signing_app/Contents/Helpers/shipios-agent"
if (SHIPIOS_CODESIGN_IDENTITY=shipios-nonexistent-test-identity
    shipios_resolve_codesign_identity
    shipios_sign_macos_app "$signing_app") > "$signing_fixture/invalid.log" 2>&1; then
    printf '%s\n' 'An invalid requested identity must fail instead of falling back to ad-hoc.' >&2
    exit 1
fi
printf '%s\n' 'PASS: changed app/helper code hashes, stable requirements, strict verification, unavailable/invalid identity fails, explicit ad-hoc opt-in.'
