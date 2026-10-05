# ShipiOS pinned Codex MCP component

Source: https://github.com/openai/codex/tree/50d77959bf927293c4b5ddcca81d05331ae582ea/codex-rs/codex-mcp

Apache-2.0 component with original source, tests, LICENSE and NOTICE retained. The standalone manifest preserves pinned dependency versions. This component is excluded from the ShipiOS workspace; workspace tests do not implicitly run the upstream test suite.

`upstream/codex-mcp-elicitation-capture.patch` changes `src/elicitation.rs`, `src/lib.rs`, `src/runtime.rs` and the shared responder insertion in `src/user_verification_elicitation.rs`. `McpRuntime.claim_elicitation` binds one original server callback behind Core's existing globally unique public request ID. The non-cloneable receipt answers once; dropping it, native callback cancellation or router removal closes that original future. Ordinary ID-routed responses cannot fulfill a claimed request. The public IDs already distinguish repeated raw MCP request IDs and different connection generations; this patch preserves that scheme and protocol events.

Core separately validates the selected active turn and cancellation token before forwarding a child answer. This low-level capability does not implement forms, URL navigation, RPC tokens, standalone idle requests, permission requests or complete UI pairing.

With Python 3.11+ and the pinned clean Codex checkout:

```sh
python3 script/verify_codex_core_patch.py /path/to/codex --component codex-mcp
```

The verifier replays the declared patch, byte-compares every other upstream source, test and asset, checks normalized dependencies and preserves legal attribution. It is source evidence, not behavior verification.
