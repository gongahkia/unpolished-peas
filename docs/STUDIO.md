# Studio and external workflow

The browser studio is local-only. Its project repository stores the current project, ten bounded
pre-save recovery revisions, settings, and capability-scoped cartridge saves in IndexedDB. A
cartridge worker receives only a validated copy of its own integer save values; it never receives
the repository, another cartridge ID, or an IndexedDB handle.

The integrated shell and editors are under active construction. The current production diagnostic
build verifies the boot display, WebGL cartridge frame, Web Audio gesture path, IndexedDB recovery,
and save isolation. These diagnostics are development evidence, not substitutes for the final
interactive studio workflow.

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
