# MOD-01 V1 release evidence

This is the reproducible release record for MOD-01. It deliberately contains
only the clean-break product formats and current measurements; previous
generation inputs, storage, cartridges and compatibility fixtures are not
accepted.

## Hardware and formats

Hardware Revision 1 freezes the 22-bit little-endian address space described in
[HARDWARE.md](HARDWARE.md). MODL/1 source uses `.modl`; canonical cartridges use
`.m01c` and begin with `MOD-01\\x1a\\x01`. Asset extensions are `.m01g`, `.m01m`,
`.m01s`, `.m01t`, `.m01f`, and `.m01p`. PNG, HTML, and ZIP exports embed the
same verified cartridge. `.m01rec` and `.m01save` are bounded revision-1
envelopes.

## Fresh browser baseline

The fixtures in `tests/fixtures/mod01-baseline/` are a clean Firefox production
Studio recording: three 240-frame browser runs, fresh IndexedDB records, parsed
asset catalogs, command/audio/framebuffer/state hashes, and measured bundles.
They are recorded from a local production preview:

```sh
pnpm build
pnpm --dir apps/studio exec vite preview --host 127.0.0.1 --port 4173 --strictPort
node scripts/record-mod01-baseline.mjs
node scripts/record-mod01-baseline.mjs --latency-only
node scripts/record-mod01-baseline-metadata.mjs
```

The baseline browser was Firefox 155. It verifies the native compiler against
the shared Worker core for all captured inputs, commands, saves, indexed frames,
and complete runtime snapshots.

| Cartridge      |  Bytes | Cart SHA-256                                                       | Peak work / draw / audio |
| -------------- | -----: | ------------------------------------------------------------------ | -----------------------: |
| Cinder Circuit | 42,942 | `192a4c6845418cf7e2a7ea638f8a98c022fcb7a039e1a36c70d0b65abf91d6cd` |          10,477 / 90 / 1 |
| Ashvault       | 41,354 | `387cf0a12d3de5fb93270e91b7ecf60973f07582ba204fb944a57949e9d6aa5f` |         19,299 / 117 / 2 |
| Raster Rush    | 38,124 | `96016c679dbb5d302274d5e813fcd5c803bc2f78ebd0357e964679b62ee4f729` |         31,722 / 470 / 1 |

The clean edit/save/run/first-render measurement is 153.89 ms cold and 168.42
ms median across the recorded warm samples. The split-module latency pass is
205.54 ms cold and 174.65 ms median warm.

## Deterministic release artifacts

`./scripts/verify-release-artifacts.sh` builds every first-party project twice,
compares raw/PNG/HTML/ZIP outputs byte-for-byte, validates PNG embedding, and
boots each raw cartridge for five headless frames.

| Cartridge         |  Bytes | `.m01c`                                                            | `.m01c.png`                                                        | HTML                                                               | ZIP                                                                |
| ----------------- | -----: | ------------------------------------------------------------------ | ------------------------------------------------------------------ | ------------------------------------------------------------------ | ------------------------------------------------------------------ |
| Cinder Circuit    | 42,942 | `192a4c6845418cf7e2a7ea638f8a98c022fcb7a039e1a36c70d0b65abf91d6cd` | `84a6e5ef84545eb0e0e69deaa743043aa60bd67f028cce39523274323f98c6ba` | `67a2bf8bc0960d8868a64863af1e6632ac72fef62d6c56d167c1d2fa6405ec67` | `2f7566fb79e2222c7a837a7947d2b2834de4dc6b4261f9ad6ad5bb31843625df` |
| Ashvault          | 41,354 | `387cf0a12d3de5fb93270e91b7ecf60973f07582ba204fb944a57949e9d6aa5f` | `0cb768e29924965fa1c04c3e332d53e27019bb45c7934f605997e508cb5281da` | `a293b0576a11a0e48f3e5a539755d3c65d1141d5bd3eaa6783ac07f35c40d27c` | `0aa708b2bf5589984f2748f6f0efc036e1751dd5ee2ae46228234d34bd6f527e` |
| Raster Rush       | 38,124 | `96016c679dbb5d302274d5e813fcd5c803bc2f78ebd0357e964679b62ee4f729` | `225a9730ad20490e858b427d9b54006ce02bf571731abbb788fa402a1b8658c2` | `f7616ddccb84a6f9ebd1a6ce0d541775e228f0c79749768302b5da8674c1b380` | `a8e382e9ab1da028b8f7ba94ba3121c1848377e934f62e3c20810b1b1257490b` |
| MOD-01 Service    | 27,931 | `07f354e7158d28766b0724a100949530824e408e49fa4e13e77afd060228e9a4` | `2362f373ea67b9e4ee17c0b78d4dff425e4754d05593885913007638feb66e40` | `996809398fff3966a52c8a30f4f4808efae5074a66d7d1b3c4709e2a2ca3b200` | `b88a50c92c2184f4b520a0a5917259d10cb454491362e2aee584358c125c0c48` |
| Signal 4K         |  2,370 | `0a62ce2feed90b120356ba6318007ba88237d205ab9b122c9a3d30702f736a1d` | `f983a2bb20d14f1b0c0e98f12eec7b6eda5339574b5c79032193084f2587fa1b` | `f12e825ebafdaece83f197d97a09d6cd93a0e16176f5bea9e653f47baed390ba` | `9b2619460e2ff99ae0d6b17cfab3584e48ebad5a5944e25b9f2bd7f140173981` |
| Pocket Relay      |  4,621 | `5d15072aea55719c93c3a8386846a6935174b043bd47b36e1ad845d3f17351f0` | `dc66eab5f1bbff6f5d78a0320114ee858d8685c4e4f5f023d72183775939e153` | `7ff8b5b9b465dab52e0f885eba4e66232c6f8cc14c9808ab7bc9ca3e6c3e1c0b` | `88a91e384434c7c158dc456e21f2e8b7e3a053af7e2387e72a4eda40f7392cb6` |
| Hardware Gauntlet |  4,632 | `eeae55be7766535805bf47e184a0ee043f76abd42c90ac0cc39c82a58a4467ec` | `d155ed25724289bde02177579c02e3f784880c37598513d1c98d94ca50754b00` | `ff0cdd35d48ee51802eb7ae3b865dca551c522ccb9eacd1d73ea9d2f50a5c60e` | `0ba471c19caf3ecbaaa2bd4a57ace61ac3e427947d210b1ac6c78e7786a9b5cb` |
| MODL tutorial     | 11,718 | `540f7d5566a3743d7a4e07948f8fc7cb181b2b0524feb21f472e1dceaefe6f00` | `cf8a394129ccb9dbac0937f5ff5491199bb7c898214333f11fdc50a3db0ee5f6` | `77893bb78c324185c509ccccc58d60f3617a93b4109e5510df224e2c59c4711d` | `439711d739de1570ab92397587981bcaf8b705218ee5a7485dde9b5d42a33288` |

## Quality gate and intentional limits

The release gate is `make check`, plus the artifact verifier above. It covers
Rust and TypeScript unit suites, first-party cartridge tests, format validation,
determinism, browser baseline replay, and production build output.

MOD-01 remains local-first: no accounts, backend, telemetry, cloud gallery,
netplay, compatibility importers, plugin system, alternate hardware, native
wrapper, or RGB/shader renderer are part of V1.
