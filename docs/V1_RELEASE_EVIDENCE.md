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
| Cinder Circuit    | 42,942 | `192a4c6845418cf7e2a7ea638f8a98c022fcb7a039e1a36c70d0b65abf91d6cd` | `84a6e5ef84545eb0e0e69deaa743043aa60bd67f028cce39523274323f98c6ba` | `32ef82581b11ac188954f6b25c820b30e071a617b58b319dcdc15a57a30c53fc` | `ac2857fa48303154e9bf113bb9ed526d902bb92a1f6482eee6bf9f3dfc67d733` |
| Ashvault          | 41,354 | `387cf0a12d3de5fb93270e91b7ecf60973f07582ba204fb944a57949e9d6aa5f` | `0cb768e29924965fa1c04c3e332d53e27019bb45c7934f605997e508cb5281da` | `b7b14d4a83a31d810e3dd3c6b41401c56c1d44289ca73447699754b80c81dc9c` | `5dbbbee291b614f2fa6bebb57e18bc384b907a2b4911d719343f98deb1a9cd96` |
| Raster Rush       | 38,124 | `96016c679dbb5d302274d5e813fcd5c803bc2f78ebd0357e964679b62ee4f729` | `225a9730ad20490e858b427d9b54006ce02bf571731abbb788fa402a1b8658c2` | `a7c1bea3f70be84f92dfa77735591246de9b6b1c0305db66fd59c5d051ed951d` | `052d6ee265e725d0d0227124a7c528608beca572c71bdb03437cae56db3c930e` |
| MOD-01 Service    | 27,931 | `07f354e7158d28766b0724a100949530824e408e49fa4e13e77afd060228e9a4` | `2362f373ea67b9e4ee17c0b78d4dff425e4754d05593885913007638feb66e40` | `a5cc07b3a8037dc5e367ab86b848564bb640a08c9ca3a8f3cd78a1c283344ac2` | `583021f6e889e2a529a94140b608359f2ed85b71ffb929dfc0f0e5c4d47034dd` |
| Signal 4K         |  2,370 | `0a62ce2feed90b120356ba6318007ba88237d205ab9b122c9a3d30702f736a1d` | `f983a2bb20d14f1b0c0e98f12eec7b6eda5339574b5c79032193084f2587fa1b` | `47b63b21505b0f5abb6a42953bbc1b2ca5111aec567eb2ed8f66c89ef9e2242e` | `f5ff169b8b299809d49457e14702cad1eea959c98ac3b7f1373c4fffc921a648` |
| Pocket Relay      |  4,621 | `5d15072aea55719c93c3a8386846a6935174b043bd47b36e1ad845d3f17351f0` | `dc66eab5f1bbff6f5d78a0320114ee858d8685c4e4f5f023d72183775939e153` | `af16b8e8cf196d7ce0c35e6b2fe25f4fd5b2d9e986686feb21fd53fd411456ec` | `ed752ff110b47c6e604d5d2aec3c19295e42b906d8292ea96dea8d3f97fde794` |
| Hardware Gauntlet |  4,632 | `eeae55be7766535805bf47e184a0ee043f76abd42c90ac0cc39c82a58a4467ec` | `d155ed25724289bde02177579c02e3f784880c37598513d1c98d94ca50754b00` | `6347812cefe8428c48f79a42c1bc43d6c362ba4256e1cdea7d261629a829c812` | `61531fe429e0e7feb11fa08f052dc543e4d7fd25edf32e87c6935507506e5fc6` |
| MODL tutorial     | 11,718 | `540f7d5566a3743d7a4e07948f8fc7cb181b2b0524feb21f472e1dceaefe6f00` | `cf8a394129ccb9dbac0937f5ff5491199bb7c898214333f11fdc50a3db0ee5f6` | `8cca4d2f965c74cb447773cdbed8b2e993fef8b64c839e20f980021b7b38e08c` | `09a49699edf95b6d4ef5fd5fc991c9cec5cd331592d9ba792e0443044859402c` |

## Quality gate and intentional limits

The release gate is `make check`, plus the artifact verifier above. It covers
Rust and TypeScript unit suites, first-party cartridge tests, format validation,
determinism, browser baseline replay, and production build output.

MOD-01 remains local-first: no accounts, backend, telemetry, cloud gallery,
netplay, compatibility importers, plugin system, alternate hardware, native
wrapper, or RGB/shader renderer are part of V1.
