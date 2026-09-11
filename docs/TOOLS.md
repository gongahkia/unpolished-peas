# PX-240C tools

The `px240c` executable is the external workflow over the same Rust compiler used by Studio:

```sh
px240c new my-cart --title "MY CART"
px240c fmt my-cart
px240c check my-cart
px240c build my-cart --debug
px240c test my-cart
px240c watch my-cart
px240c run my-cart
px240c run my-cart --headless --frames 120 --input tests/path.json
px240c pack my-cart
px240c info my-cart/dist/my-cart.pxc
px240c export html my-cart
px240c export png my-cart --output my-cart.pxc.png
px240c lsp
```

`fmt` and `check` default to the current project and accept files or project directories. Project
builds resolve namespaced imports and perform deterministic restart; they do not pretend to migrate
live game state. `watch --once` is the noninteractive deterministic pack used by CI. The long-running
form serves a loopback-only standalone player, hashes project content, rebuilds after bytes change,
and reloads only after a successful revision. A failed edit reports diagnostics and leaves the last
good player intact.

## Cartridge tests

`px240c test PROJECT` discovers a sorted `tests/` tree:

- ordinary `.pxl` entries compile in debug mode and run for one deterministic frame; `on start`
  assertions are the compact pure-test convention;
- `*.fail.pxl` must begin with `// expect PX....` and pass only for that compiler diagnostic;
- `*.pxrun.json` revision 1 drives the main cartridge with a frame count, seed, compact `input`
  trace, optional raw `save` fixture path, and an `expect` object matched against the headless
  summary. Framebuffer/state/audio/save hashes are ordinary expected fields.

Test entries are selected only by the test runner and are never used as a release entry point.
Runtime assertion failures include the stable PX fault and source span. The runner never uses host
evaluation; it invokes compiler-produced code in the bounded production headless host.

## Language server

`px240c lsp` uses full-document synchronization and incrementally republishes the edited module and
its direct importers. It supplies project completion, hover, signature help, cross-file definition,
references and rename, diagnostics, formatting, and document/workspace symbols. Renaming an imported
member edits its declaration and qualified member references, not the import alias or comments.
PXCL/1 is ASCII-only, so valid source has identical byte and LSP UTF-16 columns.

`export html` writes the source-inspectable single-file player. `export png` writes the deterministic
physical cartridge image with the same complete canonical bytes in its validated PNG chunk. `info`
accepts raw or PNG cartridges and reports the inner archive rather than trusting presentation
metadata.

Studio commands, project persistence, editor recovery, runtime launch, and browser fallbacks remain
documented in [STUDIO.md](STUDIO.md). Headless traces and cartridge layout are documented in
[CARTRIDGE_FORMAT.md](CARTRIDGE_FORMAT.md).
