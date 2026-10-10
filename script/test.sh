#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${SHIPIOS_STORAGE_GUARDED:-}" != "1" ]]; then
    exec python3 script/dev_storage.py run -- "$0" "$@"
fi
build_cache="${SHIPIOS_BUILD_CACHE_ROOT:-$PWD/.cache}"
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
# Native Core execution tests need the host's hidden exec-server helper modes.
cargo build --locked -p shipios-agent
export SHIPIOS_TEST_AGENT="${SHIPIOS_TEST_AGENT:-${CARGO_TARGET_DIR:-$PWD/target}/debug/shipios-agent}"
cargo test --workspace --locked
CLANG_MODULE_CACHE_PATH="$build_cache/clang-module-cache" xcrun swift test --build-system "${SHIPIOS_SWIFTPM_BUILD_SYSTEM:-native}" --package-path apps/macos --scratch-path "$build_cache/macos-build" --cache-path "$build_cache/swiftpm-cache" --disable-sandbox
python3 script/smoke_ipc.py
python3 script/test_ios_counter.py
