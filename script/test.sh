#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
cargo build --locked -p shipios-agent
CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang-module-cache" swift test --package-path apps/macos --scratch-path "$PWD/.cache/macos-build" --cache-path "$PWD/.cache/swiftpm-cache" --disable-sandbox
python3 script/smoke_ipc.py
