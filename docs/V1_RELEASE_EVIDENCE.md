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
| Cinder Circuit    | 42,942 | `192a4c6845418cf7e2a7ea638f8a98c022fcb7a039e1a36c70d0b65abf91d6cd` | `84a6e5ef84545eb0e0e69deaa743043aa60bd67f028cce39523274323f98c6ba` | `e028d1d2eae50cfdc38deb5cfae51d9c31937be8da53d60c28551e593d6f497e` | `f570cf667d05c5f480dfc160b334821999347ce82b5f5b0778204e3693bc2e07` |
| Ashvault          | 41,354 | `387cf0a12d3de5fb93270e91b7ecf60973f07582ba204fb944a57949e9d6aa5f` | `0cb768e29924965fa1c04c3e332d53e27019bb45c7934f605997e508cb5281da` | `c278fbc89ad74e22ed6514bb6858b6b9b1df200c1af9abf94adf8c96be2d288b` | `bebbfe449765a22c5e1d7eb46a2450c9309154d941afa6f4db547df8d370100d` |
| Raster Rush       | 38,124 | `96016c679dbb5d302274d5e813fcd5c803bc2f78ebd0357e964679b62ee4f729` | `225a9730ad20490e858b427d9b54006ce02bf571731abbb788fa402a1b8658c2` | `0d3deeb60b5c3fe25962aaaf3a4bfd0e58fcfcbbfcc80d57924bfa7a063960d2` | `50bf6838d12397925f7733679a556844842ed89379492b9c3be7fc838d96a7c4` |
| MOD-01 Service    | 27,931 | `07f354e7158d28766b0724a100949530824e408e49fa4e13e77afd060228e9a4` | `2362f373ea67b9e4ee17c0b78d4dff425e4754d05593885913007638feb66e40` | `d071c85b68202504509277f1d8925cb9aa882a5f69aef8c5c00f3210104f59c7` | `6c4cf9a4713a55684f8a61cc256636cc3c0411e17810256b3ed7072e61670b77` |
| Signal 4K         |  2,370 | `0a62ce2feed90b120356ba6318007ba88237d205ab9b122c9a3d30702f736a1d` | `f983a2bb20d14f1b0c0e98f12eec7b6eda5339574b5c79032193084f2587fa1b` | `0cacef588e25ce3a35766f92cd53ae548b8b8ce5021df84fb81f6ebb3d009270` | `7c7f3fe10c5e1a0b564da399c9dc6bb5e85e004f2968bfd12d9d739b25059331` |
| Pocket Relay      |  4,621 | `5d15072aea55719c93c3a8386846a6935174b043bd47b36e1ad845d3f17351f0` | `dc66eab5f1bbff6f5d78a0320114ee858d8685c4e4f5f023d72183775939e153` | `3af0ef28277ccbb55f2649df3a72bdff2906f171c68ce2de75f35847522d208e` | `723758fd4a62adc089442be6d72ca6a255abb2acfd266efb104e85bf1631f41d` |
| Hardware Gauntlet |  4,632 | `eeae55be7766535805bf47e184a0ee043f76abd42c90ac0cc39c82a58a4467ec` | `d155ed25724289bde02177579c02e3f784880c37598513d1c98d94ca50754b00` | `fd590f2070df867e697abc3ddad0ab19c15f424fc2104ef94e85f426762d7f29` | `cc9d00fbf2a2d7eeb6da2e1859a00e210d4714092e58b5a3863eaa956e4854fd` |
| MODL tutorial     | 11,718 | `540f7d5566a3743d7a4e07948f8fc7cb181b2b0524feb21f472e1dceaefe6f00` | `cf8a394129ccb9dbac0937f5ff5491199bb7c898214333f11fdc50a3db0ee5f6` | `fdc27a981ce876c2d85fd38278cae40499effd9c4e0c3111c8e9ad86dfac32d3` | `6f758b0efed77ef314d3f1a08a9fed2f8dca36e4a669aaf13ab8bdd40afbc74d` |

## Quality gate and intentional limits

The release gate is `make check`, plus the artifact verifier above. It covers
Rust and TypeScript unit suites, first-party cartridge tests, format validation,
determinism, browser baseline replay, and production build output.

MOD-01 remains local-first: no accounts, backend, telemetry, cloud gallery,
netplay, compatibility importers, plugin system, alternate hardware, native
wrapper, or RGB/shader renderer are part of V1.
