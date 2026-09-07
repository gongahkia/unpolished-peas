# Studio and external workflow

The browser studio is local-only. Its project repository stores the current project, ten bounded
pre-save recovery revisions, settings, and capability-scoped cartridge saves in IndexedDB. A
cartridge worker receives only a validated copy of its own integer save values; it never receives
the repository, another cartridge ID, or an IndexedDB handle.

The production app boots directly into the monitor shell. `new`, `dir`, `load`, `save`, `recover`,
`edit`, `run`, `pack`, `info`, `help`, and `reboot` operate on real project/compiler/runtime paths.
The source editor has live compiler diagnostics, canonical formatting, save, and run controls.
Running a project uses the Rust compiler WebAssembly bridge, a dedicated worker, indexed WebGL
output, four-port browser input, frame/work status, and isolated save flushing. Shift+Escape returns
from a cartridge to the shell.

The remaining asset editors and debugger surfaces are under active construction. Development query
routes separately verify the WebGL fixture, Web Audio gesture path, IndexedDB recovery, and sandbox
fault handling.

## Native commands

From the repository, use `cargo run --package px240c-cli --` in place of an installed `px240c`:

```sh
px240c new my-game --title "MY GAME"
px240c check my-game
px240c build my-game
px240c watch my-game
px240c pack my-game
px240c info my-game/dist/my-game.pxc
px240c lsp
```

`watch --once` performs the same initial deterministic build and exits for CI checks. Otherwise it
polls project content every 250 ms and repacks only when bytes change. `fmt --check` reports source
that differs from canonical two-space formatting.

The browser production build runs `scripts/build-wasm.sh`, which builds the Rust compiler for
`wasm32-unknown-unknown` and generates pinned web bindings before Vite bundles it. Cartridge
compilation therefore does not depend on a backend or a second TypeScript compiler implementation.

## Language-server clients

The stdio server supports full-document synchronization, diagnostics, completion, hover,
go-to-definition, same-document references, and same-document rename. PXCL/1 is ASCII-only, so LSP
UTF-16 columns and compiler byte columns coincide for valid files.

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
`px240c lsp`. Project-wide symbol navigation and incremental text edits are not implemented yet;
clients must send full document changes.
