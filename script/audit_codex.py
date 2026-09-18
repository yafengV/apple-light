#!/usr/bin/env python3
"""Check the pinned upstream API surface without executing Codex or loading credentials."""
import json
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parent.parent
lock = json.loads((root / "upstream/codex.lock.json").read_text())
checkout = root / ".cache/codex-upstream"
if not checkout.exists():
    checkout.parent.mkdir(exist_ok=True)
    subprocess.run(["git", "init", str(checkout)], check=True)
    subprocess.run(["git", "-C", str(checkout), "remote", "add", "origin", lock["repository"]], check=True)
    subprocess.run(["git", "-C", str(checkout), "fetch", "--depth", "1", "origin", lock["revision"]], check=True)
    subprocess.run(["git", "-C", str(checkout), "checkout", "--detach", "FETCH_HEAD"], check=True)
actual = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
if actual != lock["revision"]:
    raise SystemExit("Cached Codex revision differs from lock; preserve it and use a fresh checkout.")
checks = {
    "coreFacade": ["pub use codex_core::ThreadManager;", "pub use codex_extension_api::ExtensionRegistryBuilder;"],
    "contributors": ["pub trait ToolContributor", "pub trait ApprovalReviewContributor"],
    "registry": ["pub fn tool_contributor", "pub fn build(self)"],
    "embeddingSample": ["ThreadManager::new", "ConfigLayerStack::default()", "start_thread"],
}
for key, symbols in checks.items():
    source = (checkout / lock["paths"][key]).read_text()
    for symbol in symbols:
        if symbol not in source:
            raise SystemExit(f"Missing symbol in {key}: {symbol}")
print(json.dumps({"revision": actual, "sourceChecks": "passed", "coreCompiled": False, "modelCalls": False}, indent=2))
