# Local Codex sandboxing patch

Source: https://github.com/openai/codex, revision `50d77959bf927293c4b5ddcca81d05331ae582ea`, directory `codex-rs/sandboxing/src`. Apache-2.0; original LICENSE and NOTICE are retained here and included in the application distribution under `licenses/`.

ShipiOS carries this one component as a Cargo patch because the fixed upstream revision emits invalid Seatbelt regex literals when a project path contains double quotes. The source changes are limited to `seatbelt.rs` and `seatbelt_tests.rs`; all other source files are unchanged. The local manifest keeps the original package name/version and fixed upstream dependencies while allowing this component to build and test in the ShipiOS workspace.

Patterns containing double quotes or line breaks are passed as named `sandbox-exec -D` argv parameters and evaluated with `(regex (param ...))`. Ordinary patterns retain the upstream serialization. Protected metadata, deny globs and protected ancestor unlink rules use the same patterns, without widening sandbox permissions. Three redundant formatting borrows in the retained tests are also removed to satisfy the current toolchain’s Clippy checks.

Review the exact source delta in `upstream/codex-sandboxing-seatbelt.patch` (zero-context unified diff; apply with `git apply --unidiff-zero`). To update, copy the new pinned component source, reapply or retire this delta, update the manifest revisions, and run the complete component tests plus the quoted-project Core transport regression before changing the production dependency.

Validation:

```sh
cargo test --locked -p codex-sandboxing
cargo tree --locked -p shipios-agent -i codex-sandboxing
script/build_and_run.sh --build-app
```

The custom runtime regression verifies ordinary writes succeed while first-time `.git`, `.codex`, `.agents` creation and protected `.env` reads/writes fail for quote, backslash, Unicode and newline paths. It supplements the retained upstream tests.
