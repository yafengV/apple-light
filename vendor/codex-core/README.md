# ShipiOS pinned Codex Core component

Source: https://github.com/openai/codex/tree/50d77959bf927293c4b5ddcca81d05331ae582ea/codex-rs/core

This component is Apache-2.0; upstream LICENSE, NOTICE, README, assets and tests are retained. Other Codex crates remain pinned Git dependencies. This is a local Cargo patch of Core, not a copied personal Codex installation or configuration.

The reviewable source delta is `upstream/codex-core-approval-capture.patch` (four files). The standalone manifest resolves upstream workspace dependencies and features without changing versions; upstream relative component dependencies point to that same Git revision. The Core component is excluded from the ShipiOS workspace, and its upstream unit/integration tests and doctests are not implicitly part of `cargo test --workspace`. Real-Core regression tests for the public API live in `crates/shipios-codex/src/approval_capture_tests.rs`.

## Native approval capture

`CodexThread.claim_approval_for_turn(expected_turn_id, approval_id, started_at_ms)` atomically binds the original pending exec/patch approval to its active native turn. Claims are one-use and do not submit a later ID-routed Op. The request's monotonic Unix-millisecond timestamp distinguishes repeated call IDs, including requests in the same turn; bursts can advance it beyond the wall-clock millisecond. Existing event schemas and ordinary, unclaimed approval delivery remain unchanged.

`CapturedApproval` is not cloneable. Resolving checks the original turn and reply channel, delivers only to that waiter, and never looks up a replacement by call ID. Core retains shared cancellation ownership: cancellation, waiter clearing and overwrite close a captured reply. Dropping the host capability closes the original waiter. ID-only ordinary replies cannot fulfill a waiter claimed by the host. Explicit Abort interrupts only the expected native turn through Core's existing guarded abort path. Prefix amendments retain the native persistence/warning behavior; their persistence occurs under the expected active-turn guard. The host must expose and validate the request's native available decisions before invoking this trusted API.

This foundation does not itself add child approval buttons, MCP elicitation, request-user-input, permission requests or standalone child Stop controls. Those integrations and complete page pairing remain pending.

## Source audit

With Python 3.11+ and a clean checkout at the pinned revision:

```sh
python3 script/verify_codex_core_patch.py /path/to/codex
```

The verifier checks the revision, replays the four-file patch in a temporary directory, byte-compares every other upstream source/test/asset, reproduces the standalone manifest and checks legal attribution. `--write-patch` refreshes the source patch during intentional maintenance. Review and rerun native regressions when changing it; the verifier is not behavioral evidence.
