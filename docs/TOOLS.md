# MOD-01 tools

The `mod01` executable is the external workflow over the same Rust compiler used by Studio:

```sh
mod01 new my-cart --title "MY CART"
mod01 fmt my-cart
mod01 check my-cart
mod01 build my-cart --debug
mod01 test my-cart
mod01 watch my-cart
mod01 run my-cart
mod01 run my-cart --headless --frames 120 --input tests/path.json
mod01 pack my-cart
mod01 info my-cart/dist/my-cart.m01c
mod01 export html my-cart
mod01 export png my-cart --output my-cart.m01c.png
mod01 export zip my-cart --output my-cart-itch.zip
mod01 lsp
```

`fmt` and `check` default to the current project and accept files or project directories. Project
builds resolve namespaced imports and perform deterministic restart; they do not pretend to migrate
live game state. `watch --once` is the noninteractive deterministic pack used by CI. The long-running
form serves a loopback-only standalone player, hashes project content, rebuilds after bytes change,
and reloads only after a successful revision. A failed edit reports diagnostics and leaves the last
good player intact.

## Cartridge tests

`mod01 test PROJECT` discovers a sorted `tests/` tree:

- ordinary `.modl` entries compile in debug mode and run for one deterministic frame; `on start`
  assertions are the compact pure-test convention;
- `*.fail.modl` must begin with `// expect M01....` and pass only for that compiler diagnostic;
- `*.m01run.json` revision 1 drives the main cartridge with a frame count, seed, compact `input`
  trace, optional raw `save` fixture path, and an `expect` object matched against the headless
  summary. Framebuffer/state/audio/save hashes are ordinary expected fields.

Test entries are selected only by the test runner and are never used as a release entry point.
Runtime assertion failures include the stable M01 fault and source span. The runner never uses host
evaluation; it invokes compiler-produced code in the bounded production headless host.

## Language server

`mod01 lsp` uses full-document synchronization and incrementally republishes the edited module and
its direct importers. It supplies project completion, hover, signature help, cross-file definition,
references and rename, diagnostics, formatting, and document/workspace symbols. Renaming an imported
member edits its declaration and qualified member references, not the import alias or comments.
MODL/1 is ASCII-only, so valid source has identical byte and LSP UTF-16 columns.

`export html` writes the source-inspectable single-file player. `export png` writes the deterministic
physical cartridge image with the same complete canonical bytes in its validated PNG chunk. `info`
accepts raw or PNG cartridges and reports the inner archive rather than trusting presentation
metadata. `export zip` stores the exact offline HTML as `index.html` with fixed zero timestamps for a
byte-identical itch.io-ready artifact.

`info` keeps manifest fields at the JSON top level and adds an `analysis` object. It reconciles the
exact canonical size/class with source, release-generated code, visual/map/font/audio data,
metadata, encoded payload, container overhead, compression gain, and the fixed 8 KiB save
allocation. It lists the largest archive entries and routines, actionable warnings, and a
deterministic 60-frame production-core profile (work, command, voice and mapped-bus peaks, hashes,
and any fault). That default profile uses seed `0x4d30_3031`, empty input and an empty save; use
`run --headless --input ... --save ...` for an intentional gameplay path.

Studio `SETTINGS`/`CONTROLS` stores one named four-port keyboard/gamepad profile locally. A key
capture moves an existing conflicting assignment instead of producing two bindings; physical
gamepad indices remain assigned across disconnect/reconnect. Reduced flashing, muted startup, UI
contrast, larger help text and output volume affect only host presentation/audio, never indexed
cartridge pixels, captures, replay state, or the fixed palette.

Studio commands, project persistence, editor recovery, runtime launch, and browser fallbacks remain
documented in [STUDIO.md](STUDIO.md). Headless traces and cartridge layout are documented in
[CARTRIDGE_FORMAT.md](CARTRIDGE_FORMAT.md).
