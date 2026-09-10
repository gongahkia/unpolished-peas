# Studio and external workflow

The browser studio is local-only. Its project repository stores the current project, ten bounded
pre-save recovery revisions, settings, and capability-scoped cartridge saves in IndexedDB. A
cartridge worker receives only a validated copy of its own integer save values; it never receives
the repository, another cartridge ID, or an IndexedDB handle.

The production app boots directly into the monitor shell. `new`, `dir`, `load`, `save`, `recover`,
`import`, `edit`, `run`, `debug`, `pack`, `export`, `inspect`, `info`, `help`, and `reboot` operate on
real project/compiler/runtime paths. `import` validates an untrusted `.pxc`, reconstructs its
editable project, and preserves the previous same-ID revision for recovery. `inspect` displays the
canonical packed metadata and all original source modules. `export` downloads one offline HTML
player with its own visible source inspector.
The source editor has PXCL highlighting, live compiler diagnostics, completion, symbol navigation,
canonical formatting, explicit save, run, and external-revision reload controls.
Edits debounce to a 750 ms autosave and pass through a revision check before writing; an externally
newer revision stops the save and surfaces F6 reload instead of knowingly overwriting it. Explicit
F3 save and leaving the editor flush the same serialized path. Every successful write retains the
previous revision in the ten-entry recovery ring.
Running a project uses the Rust compiler WebAssembly bridge, a dedicated worker, indexed WebGL
output, four-port browser input, frame/work status, and isolated save flushing. Shift+Escape returns
from a cartridge to the shell.

`project`, `sprite`, `map`, `palette`, `sfx`, and `music` open cartridge settings and source-visible
asset editors in the same 240x144 display. The sprite tool provides frames, onion skinning,
selection transforms, palette painting, undo/redo, and capacity feedback. The map tool provides
layers, tile flags, painting, undo/redo, and shared-capacity feedback. Palette/raster defaults feed
the runtime without changing the fixed master palette. Sound patches and eight-channel tracker
patterns can be previewed after a browser audio gesture. The tracker edits named patterns and an
ordered playback sequence, preserves existing patch references, loops on request, and provides
bounded note/pattern undo/redo. The shell, editors, controls, and cartridges use the same original
PX-240C glyph design; the Studio font is generated locally from the runtime's glyph matrix.
`manual` searches built-in help and
`explore` exposes tokens, AST, symbols, typed IR, JavaScript, source maps, diagnostics, and size
accounting. `debug` opens source breakpoints and trace stepping, state/task/watch inspection,
synthetic-work profiling, hardware inspectors, and deterministic frame rewind. Its precise
frame-boundary semantics and limitations are documented in [DEBUGGER.md](DEBUGGER.md). Escape
returns from a creation tool; F3 saves asset changes.

## Native commands

From the repository, use `cargo run --package px240c-cli --` in place of an installed `px240c`:

```sh
px240c new my-game --title "MY GAME"
px240c check my-game
px240c build my-game
px240c test my-game
px240c watch my-game
px240c pack my-game
px240c export html my-game
px240c run my-game
px240c run my-game --headless --frames 120 --input tests/replays/my-game.json
px240c info my-game/dist/my-game.pxc
px240c lsp
```

`watch --once` performs the same initial deterministic pack and exits for CI checks. Otherwise it
serves a loopback-only offline player, rebuilds only when project bytes change, and reloads after a
successful revision. A compiler failure stays in the terminal without replacing the last good
player. `fmt --check` reports source
that differs from canonical two-space formatting. `run` writes the same standalone HTML artifact to
`dist/` and opens it with `xdg-open`; `--no-open` performs only the validated export for CI or a
headless environment. `run --headless` instead drives the production console core under Node and
emits revisioned JSON framebuffer/state/audio/PCM/save hashes. It accepts a project directory or
`.pxc`, an explicit seed/frame count, compact controller trace and optional raw save image.

The browser production build runs `scripts/build-wasm.sh`, which builds the Rust compiler for
`wasm32-unknown-unknown` and generates pinned web bindings before Vite bundles it. Cartridge
compilation therefore does not depend on a backend or a second TypeScript compiler implementation.
The production build also emits a generated same-origin service worker containing the exact hashed
build inventory. After its first successful load, the Studio boots and operates offline. The web
app manifest and maskable icon are static repository assets.

## Language-server clients

The stdio server supports full-document synchronization, dependency-aware diagnostics, project
completion, hover/signature help, cross-file definition/references/rename, formatting, and document
and workspace symbols. PXCL/1 is ASCII-only, so LSP UTF-16 columns and compiler byte columns
coincide for valid files.

Generic Neovim setup:

```lua
vim.api.nvim_create_autocmd('FileType', {
  pattern = 'pxcl',
  callback = function()
    vim.lsp.start({ name = 'px240c', cmd = { 'px240c', 'lsp' }, root_dir = vim.fn.getcwd() })
  end,
})
```

For another LSP-capable editor, register `.pxl` as PXCL and configure the server command as
`px240c lsp`. Clients send full-document changes; the server invalidates the edited module and its
direct importers without reanalyzing unrelated open modules.
