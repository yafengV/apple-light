#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

python3 script/audit_codex.py
if [[ -n "$(git -C .cache/codex-upstream status --porcelain)" ]]; then
  echo "Pinned Codex checkout has local changes; refusing to verify a modified API." >&2
  exit 1
fi
cp .cache/codex-upstream/codex-rs/Cargo.lock experiments/codex-core-embed/Cargo.lock
export CARGO_TARGET_DIR="$repo_root/.cache/codex-upstream-target"
cargo run --manifest-path experiments/codex-core-embed/Cargo.toml
