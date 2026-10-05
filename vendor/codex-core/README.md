# ShipiOS pinned Codex Core component

Source: https://github.com/openai/codex/tree/50d77959bf927293c4b5ddcca81d05331ae582ea/codex-rs/core

This component is Apache-2.0; upstream LICENSE, NOTICE, README, assets and tests are retained. Other Codex crates remain pinned Git dependencies. This is a local Cargo patch of Core, not a copied personal Codex installation or configuration.

The reviewable source delta is `upstream/codex-core-approval-capture.patch` (five files). The standalone manifest resolves upstream workspace dependencies and features without changing versions; upstream relative component dependencies point to that same Git revision. Core and the separately audited local MCP component are excluded from the ShipiOS workspace, and their upstream unit/integration tests and doctests are not implicitly part of `cargo test --workspace`. Real-Core regression tests for the public APIs live in `crates/shipios-codex/src/approval_capture_tests.rs`.

## Native approval capture

`CodexThread.claim_approval_for_turn(expected_turn_id, approval_id, started_at_ms)` atomically binds the original pending exec/patch approval to its active native turn. Claims are one-use and do not submit a later ID-routed Op. The request's monotonic Unix-millisecond timestamp distinguishes repeated call IDs, including requests in the same turn; bursts can advance it beyond the wall-clock millisecond. Existing event schemas and ordinary, unclaimed approval delivery remain unchanged.

`CapturedApproval` is not cloneable. Resolving checks the original turn and reply channel, delivers only to that waiter, and never looks up a replacement by call ID. Core retains shared cancellation ownership: cancellation, waiter clearing and overwrite close a captured reply. Dropping the host capability closes the original waiter. ID-only ordinary replies cannot fulfill a waiter claimed by the host. Explicit Abort interrupts only the expected native turn through Core's existing guarded abort path. Prefix amendments retain the native persistence/warning behavior; their persistence occurs under the expected active-turn guard. The host must expose and validate the request's native available decisions before invoking this trusted API.

The ShipiOS host now connects exec/patch claims to child approval cards and one-use RPC tokens. MCP elicitation, request-user-input and permission requests are separate capabilities; this API does not add them or prove complete page pairing.

## Guarded child interruption

`CodexThread.interrupt_turn_if_active(expected_turn_id)` exposes Core's existing guarded abort path. It interrupts only the matching active turn and returns false after completion or replacement; it never queues an unscoped interrupt that could stop a later turn. ShipiOS validates the task, root and actual loaded child subtree before calling it. Idle/cold children are not loaded by this operation. It does not promise recursive descendant or standalone Node executor interruption.

## Native child MCP replies

`CodexThread.claim_elicitation_for_turn(expected_turn_id, server, request_id, generation)` claims either a turn-bound tool approval (`Some(generation)`) or an actual MCP runtime callback (`None`). Tool approvals carry a Core-generated receipt in request metadata; ordinary server forms and URLs retain the upstream events with no turn ID and globally unique router IDs. The host must supply the turn it actually observed for that loaded child; it must not invent a turn ID in the server event.

The non-cloneable capability owns the original callback, validates the selected active turn atomically, and checks its cancellation token. Stop, turn replacement and callback cancellation prevent a late response. Invalid identity/generation does not consume a request; ordinary queued ID-only replies cannot fulfill a claimed waiter. This foundation does not yet connect child MCP RPC tokens or UI forms. Idle/server-initiated requests outside an active child turn and full permission workflows remain separate work.

## Source audit

With Python 3.11+ and a clean checkout at the pinned revision:

```sh
python3 script/verify_codex_core_patch.py /path/to/codex
```

The verifier checks the revision, replays the five-file patch in a temporary directory, byte-compares every other upstream source/test/asset, reproduces the standalone manifest and checks legal attribution. Pass `--component codex-mcp` to audit the MCP component separately. `--write-patch` refreshes the source patch during intentional maintenance. Review and rerun native regressions when changing it; the verifier is not behavioral evidence.
