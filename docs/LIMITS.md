# Alpha limit calibration

The experimental profile was frozen after building and running all three bundled cartridges through
the public compiler, packer, worker, indexed renderer, and asset decoder. Work units are synthetic
deterministic costs, not elapsed time or CPU instructions. Measurements below are representative
active-play frames observed in the production Studio on 2026-09-07; control flow can vary slightly,
and the enforced ceiling remains the authority.

| Cartridge      | Packed `.pxc` | Visual store | Release JS | Representative work/frame |
| -------------- | ------------: | -----------: | ---------: | ------------------------: |
| Cinder Circuit |      32,270 B |      2,854 B |   11,945 B |                     3,295 |
| Ashvault       |      36,142 B |        288 B |   14,465 B |                    11,783 |
| Raster Rush 1P |      34,137 B |        160 B |   13,404 B |                    27,906 |
| Raster Rush 4P |      34,137 B |        160 B |   13,404 B |                    31,422 |

Raster Rush four-player is the governing frame case at about 63% of the 50,000-unit ceiling. It
executes four independent controller paths and view projections plus 144 raster callbacks while
remaining below the limit. The 256 KiB packed and 128 KiB visual ceilings have substantial headroom
for these deliberately compact games; they remain useful authoring ceilings rather than targets.

## Frozen revision-1 profile

- 240x144 indexed display, fixed 32-colour palette, 60 Hz rendering, 30/60 Hz updates.
- 50,000 deterministic work units and 4,096 draw commands per frame.
- 256 KiB packed cartridge and 128 KiB shared visual assets.
- 8 KiB isolated save data per cartridge.
- Eight synth voices, eight tracker channels, and 48 kHz stereo host output.
- Four controller ports, 1-64 pixel sprite axes, 8x8 tiles, integer nearest-neighbor transforms.

No limit required adjustment from the brief's initial values; the previously unspecified work
ceiling is frozen at 50,000. Later format revisions may change a profile only with a revisioned,
measured compatibility decision.

## Reproduction

```sh
node scripts/generate-cartridge-assets.mjs
cargo test -p px240c-cli --test cli bundled_cartridges_compile_and_pack_within_capacity
pnpm test -- --run packages/runtime/src/bundled-cartridges.test.ts
pnpm --filter @px240c/studio build
```

The frame figures come from the Studio's visible `W` counter during active play. Use `debug`, choose
`PROFILE`, and advance frames for per-source-span attribution.
