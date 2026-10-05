#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
# Native Core execution tests need the host's hidden exec-server helper modes.
cargo build --locked -p shipios-agent
export SHIPIOS_TEST_AGENT="${SHIPIOS_TEST_AGENT:-${CARGO_TARGET_DIR:-$PWD/target}/debug/shipios-agent}"
cargo test --workspace --locked
CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang-module-cache" swift test --package-path apps/macos --scratch-path "$PWD/.cache/macos-build" --cache-path "$PWD/.cache/swiftpm-cache" --disable-sandbox
python3 script/smoke_ipc.py
