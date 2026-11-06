# Authored-font measurement and prepared text

Use `font.measureText(text, options)` for allocation-free measurements and
`font.layoutText(allocator, text, options)` to prepare text once for repeated
drawing. These are additive methods on `assets.Font`. The
[call reference](../api/assets.md#assets-Font) includes signatures and defaults.

The original `graphics.layoutText` / `graphics.TextLayout` remain debug-font
helpers with their existing metrics. `Font.drawText` keeps its direct,
unwrapped rendering behavior. Neither old API is redirected to the new path.

## Reproduced mismatch

Before this change, Zig 0.15.2 on Intel macOS 15.7.7 measured:

| Source Sans 3, default 20-pixel load | Existing debug layout width | Actual glyph advances |
| --- | ---: | ---: |
| WWW | 12 | 36 |
| iii | 12 | 12 |

The old layout also reported height 7 against the authored font's line height
20. Equal-length debug-font measurements cannot position proportional text
correctly. The new measurements are 36×20 and 12×20 respectively.
These are logical advances/line boxes, not tight painted-pixel bounds.

## Small menu and dialogue

The [portable game](../../examples/font_layout_game.zig) loads one embedded
Source Sans face into an AssetCollection, prepares centered menu labels and
wrapped dialogue during init, and draws only prepared layouts. Up/down changes
the highlighted label; Space changes the prepared dialogue page.

```sh
zig build run-font-layout
zig build web-font-layout -Dwith_sdl=false
python3 -m http.server --directory zig-out/font-layout 8000
```

Open http://localhost:8000 for the browser example. The native
[entry point](../../examples/font_layout.zig) supplies only the SDL wrapper.
The web package includes the existing font's SourceSansOFL.txt notice.

The important lifecycle is: create the collection/font, prepare layouts, reuse
them, release layouts, then release the collection. A failed init must clean up
partially prepared layouts too. The complete example does that with errdefer.
It also has allocation-failure tests.

## What measurements mean

| Value | Meaning |
| --- | --- |
| metrics.width | Largest nonnegative final pen advance of any line; includes preserved trailing spaces |
| metrics.height | Line count × Font.line_height, plus line_spacing between lines |
| metrics.lines | Number of logical line boxes, including explicit empty lines |
| metrics.glyph_count | Resolved glyph placements, including zero-area spaces; missing glyphs without fallback have no placement |
| metrics.bounds | Union of positioned glyph rectangles, with bearings and baseline; null when none have area |
| metrics.diagnostics | Same invalid-UTF-8, missing-glyph and fallback counts as Font.textDiagnostics |
| layout.lines | Source byte ranges, glyph ranges, aligned line starts and signed advances |
| layout.glyphs | Cached resolved glyph metrics and local pen positions, before bearings/baseline |

Bounds may start at negative x/y, extend outside the logical line box, and
include transparent texels from the glyph rectangle. They are not a tight
alpha scan. Signed bitmap-font advances are retained; width clamps a negative
final line advance to zero, while bounds still report its painted rectangles.

Alignment uses final pen advances, not the ink outline. With max_width set,
center starts at integer division toward zero of `(max_width - advance) / 2`;
right starts at `max_width - advance`. Without max_width, all alignments start
at zero. A max_width is a wrapping/alignment container, not an automatic clip.
Use the Canvas clip when overhanging bearings must stay inside a panel.

## Wrapping, whitespace and empty text

- Default wrap is `.word` when max_width is present. Words are runs separated
  by ASCII space or LF. A word that does not fit starts a new line; a word
  wider than the container then breaks at decoded codepoints.
- `.glyph` breaks at each decoded codepoint. `.none` disables soft wrapping
  while still allowing max_width to control alignment.
- A single glyph with an advance wider than max_width occupies a line alone
  and is allowed to overflow. No glyph or UTF-8 sequence is partially consumed.
- All spaces are preserved, including leading/trailing spaces and spaces at
  soft boundaries. They count toward advance, may wrap onto their own line,
  and affect alignment. There is no implicit trimming or collapsing.
- Tabs, nonbreaking spaces and other characters use their actual glyph or
  fallback metrics. There are no invented tab stops or Unicode line-break rules.
- LF is a hard break. CR is ignored as in Font.drawText, so CRLF is one break.
  A trailing LF creates an empty final line; consecutive LF preserve empty lines.
- Empty or CR-only text has zero lines/width/height. Other input with no
  available glyphs still has a logical line box. Whitespace-only text retains
  its advances and line boxes even when it paints nothing.

Strict UTF-8 decoding and fallback selection use the existing Font helpers.
Unknown characters use the configured single fallback glyph; with no fallback,
they draw nothing and advance zero. Malformed sequences retain the existing
replacement progression. No text shaping, bidirectional ordering, kerning,
rich text, fallback-font stack or dynamic glyph streaming is added.

## Ownership, limits and errors

Measurement allocates nothing. Preparation analyzes twice and allocates exact
placement and line arrays; it has no temporary text buffer. Retained storage
is `glyph_count * @sizeOf(Font.TextLayout.GlyphPlacement)` plus
`lines * @sizeOf(Font.TextLayout.Line)` and the layout value itself.

Defaults bound input to 1 MiB, decoded codepoints to 65,536 and lines to 4096.
The codepoint budget includes controls and characters that have no glyph.
Options can lower or raise those budgets explicitly. Arithmetic is checked;
unrepresentable coordinates/extents fail instead of wrapping.

The prepared layout owns its arrays and must be deinitialized exactly once.
It does not borrow input text: the text can be freed after preparation.
It **does borrow an unchanged Font at a stable address**, including its atlas.
Destroy layouts before that Font or its AssetCollection. Do not move or
replace a standalone Font while layouts borrow it; collection-returned Font
pointers are stable. Rebuild layouts after text/options/font changes.
Moving a layout's sole owner is safe; copying it into two owners is not.

Prepared drawing performs no decoding, glyph lookup, layout work or allocator
operations. It reuses Font's existing glyph rasterization, tint, blend, clipping
and saturating draw coordinates. Existing opt-in CanvasTrace capture may
allocate its own observer storage; no trace is attached by this API.

| Error | Trigger |
| --- | --- |
| InvalidTextLayoutOptions | Nonpositive max_width, negative line_spacing, or zero codepoint/line budget |
| InvalidFontMetrics | Nonpositive Font.line_height |
| TextTooLong | Encoded bytes exceed max_input_bytes |
| TooManyCodepoints | Decoded input exceeds max_codepoints, including word look-ahead |
| TooManyTextLines | Hard/soft lines exceed max_lines |
| TextLayoutOverflow | Line step, placement, alignment or bounds cannot be represented |
| OutOfMemory | Preparation cannot allocate its retained arrays; partial allocations are released |

## Verification

```sh
zig build probe-font-layout -Dwith_sdl=false
zig build test-font-layout test-browser-font-layout web-font-layout \
  -Dwith_sdl=false -j2 --summary all
zig build docs-update-api -Dwith_sdl=false
zig build docs test-docs test-core-api -Dwith_sdl=false -j2 --summary all
script/test_browser_font_layout.sh
```

The [shared probe](../../examples/font_layout_probe.zig) checks hand-authored
proportional metrics, bearings and baseline; explicit expected wrapped lines;
all alignments; empty/whitespace/trailing-newline cases; strict UTF-8/fallback;
signed advances; invalid options/budgets and overflow; input lifetime; partial
allocation cleanup; and zero-allocator-operation measurement/drawing.
Rendered pixels compare exactly with the unchanged Font.drawText, including
negative origins, clipping, tint and both blend modes. Actual Source Sans OTF
and Basic TTF also exercise direct and wrapped drawing.

Native Debug/ReleaseFast run the suite; the Node-hosted Wasm check compares
explicit portable metadata and pixel hashes and repeats three lifecycles.
The menu/dialogue runs through the real headless GameProtocol too, including
selection/page changes, allocation-free normal drawing and failed-init cleanup.
This does not establish physical display behavior on every desktop/browser.

Recorded locally on Intel macOS 15.7.7, Zig 0.15.2 and Node 24.19.0:
327 exact pixel/metadata comparisons passed in Debug, ReleaseFast and Wasm.
The wider core/API/docs/replay/reference-game suite passed 404 tests across
98 build steps. Existing authored-font Wasm pixel goldens remain unchanged.
Headless Chromium 157.0.0.0 also displayed authored text, moved the menu
selection and changed dialogue through real keyboard events. Its screenshot
and browser metadata are retained under zig-out/diagnostics/font-layout.
That optional script requires the repository's Playwright/Chromium tooling.
It is included in the browser-rendering CI job.
