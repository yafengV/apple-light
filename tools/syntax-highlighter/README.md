# ShipiOS offline syntax highlighting

PR Code, local review diffs, last-turn review and native file previews use an application-owned Shiki engine in a nonpersistent, windowless WKWebView. The engine is bundled with the macOS app; it requires no Node installation, network access, user browser profile or installed Codex at runtime. SwiftUI renders returned tokens as selectable native text.

## Rebuild

From this directory, with Node and npm available:

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm run build
npm test
```

Dependencies are pinned in `package.json` and `package-lock.json`: Shiki 4.4.3, @pierre/diffs 1.5.1 and esbuild 0.28.2. The JavaScript regex engine is selected explicitly. The build rejects external imports and writes the standalone engine, SHA-256/size manifest, dependency licenses and any emitted legal comments into `apps/macos/Sources/ShipiOS/Resources/SyntaxHighlighting`. The generated JavaScript is marked opaque and exempt from Git newline conversion because template-string whitespace is significant. These deployable resources are tracked; node_modules and caches are ignored. `script/build_and_run.sh --build-app` copies the resource bundle into the application.

## Appearance and reference evidence

`themes/light.json` and `themes/dark.json` contain declarative scope/color/font-style facts recorded from the public distribution resources of Codex 26.911.61220 (build 9647), using ShipiOS theme names. No Codex executable JavaScript or grammar resource is redistributed. ShipiOS uses independently installed upstream packages and includes their license notices.

The test fixture contains authored code samples and expected tokens produced by the current reference worker: 19 examples, 49 lines, eight languages, both light and dark variants. A further 1,380 filename/path cases compare language recognition with that worker. The bundled upstream catalogue has 242 canonical languages; availability does not establish complete grammar or UI parity. The reference and upstream Swift, Go and CSS registrations differ, although these fixed examples match. See `docs/399-pull-request-code-syntax-highlighting.md` for the verification scope.

Full source preserves continuous grammar state and every line ending. Partial diff hunks reset grammar state; each old/new side carries state independently within a hunk. Lines over the reference 1,000-character tokenization limit and unknown file types remain readable as plain text. Token output must preserve exact source text and row identities. Failure falls back to plain native text; theme switching selects an already computed variant.

The normal 500 ms per-line budget remains in force. Interrupted tokenization receives one bounded retry; persistent interruption fails to the native plain-text fallback instead of caching incomplete colors. Tests deterministically exercise both recovery and exhaustion. The engine returns a recovery count for diagnostics; it is not shown in product flows.
