# Theme preview artwork

Extracted from the publicly distributed Codex desktop application 26.930.51102 (build 13100), asset general-settings-4f1402fc1fbd.js, SHA-256 91ef510e7631785df4c62c25f3b9018a0ca3c15ce3fa1b208f3cf8394abdf535. Original artwork belongs to OpenAI; the Codex Core Apache license is not asserted to cover these desktop assets.

The extraction procedure is script/extract_theme_card_reference.mjs. SVG currentColor is resolved using the active theme when rendered.

script/render_theme_previews.swift renders the original SVGs offline using WebKit into separate neutral base and accent-mask PNGs at 1×, 2× and 3×. Native AppKit SVG decoding omits some filter effects; the packaged raster representations preserve them without a live WebKit view in the picker. Regenerate SVGs first, then raster resources.

- dark.svg ($i): f107eeed8f5cc46311125c867493822445312db9e73e836e847b622e4d44e765
- light.svg (ta): 9086b2404bb937f458200ae77f8886be7dd96c7820996d7ac3b4949cc307ef7c
- system-light.svg (aa): 5c9c0a968222bacc7458fe219abbc5c36a3158dd8ba81e23dc45cd2d6c9ad677
- system-dark.svg (ra): 6f6055de0c1646c2e7ba27bce0d1623a96e35486f9926d91ab06785c47cec799
