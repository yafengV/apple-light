#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
cargo build --locked -p shipios-agent
mkdir -p .cache/swift-modules
swiftc -module-cache-path "$PWD/.cache/swift-modules" clients/swift/AgentProbe.swift -o .cache/AgentProbe
exec .cache/AgentProbe "$PWD/target/debug/shipios-agent" "$PWD/fixtures/HelloShipiOS" "$PWD/.shipios-local/swift-probe"
