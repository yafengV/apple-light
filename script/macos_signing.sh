#!/bin/bash
# Sourced by build_and_run.sh. Keep developer identities in the local keychain,
# never in repository configuration.
shipios_resolve_codesign_identity() {
    if [ -n "${SHIPIOS_CODESIGN_IDENTITY:-}" ]; then
        shipios_codesign_identity="$SHIPIOS_CODESIGN_IDENTITY"
    else
        local identities
        identities="$(/usr/bin/security find-identity -v -p codesigning)" || return
        shipios_codesign_identity="$(printf '%s\n' "$identities" |
            /usr/bin/sed -nE 's/^[[:space:]]*[0-9]+\) ([[:xdigit:]]{40}) "Apple Development:.*"$/\1/p' |
            /usr/bin/head -n 1)"
        shipios_codesign_identity="${shipios_codesign_identity:--}"
    fi
    if [ "$shipios_codesign_identity" = "-" ]; then
        printf '%s\n' 'Warning: ad-hoc signing; macOS folder permissions may be requested again after code changes.' >&2
        printf '%s\n' 'Install an Apple Development identity or set SHIPIOS_CODESIGN_IDENTITY to a local signing identity.' >&2
    else
        printf '%s\n' 'Using a local certificate for stable macOS development signing.'
    fi
}

shipios_sign_macos_app() {
    local app_path="$1"
    /usr/bin/codesign --force --sign "$shipios_codesign_identity" --timestamp=none \
        --identifier dev.shipios.agent "$app_path/Contents/Helpers/shipios-agent" || return
    /usr/bin/codesign --force --sign "$shipios_codesign_identity" --timestamp=none \
        --identifier dev.shipios.desktop "$app_path" || return
    /usr/bin/codesign --verify --deep --strict "$app_path"
}
