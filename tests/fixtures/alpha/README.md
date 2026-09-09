# Immutable pre-V1 fixtures

Origin: alpha `e39be5a`, recorded on 2026-09-09 before product implementation changes.
Never update these from V1 to make a compatibility test pass.

- The three `.pxc` files are exact complete alpha build outputs, not rebuilt V1 carts.
- `*.trace.json.gz` contains each actual 240-frame Firefox Worker path: initial configuration,
  inputs, draw/audio/save commands, work, per-frame indexed framebuffer and Worker snapshot SHA-256,
  and final Worker snapshot. State hashes use `JSON.stringify` of the original snapshot shape;
  compare the migrated legacy projection, not a V1 envelope's incidental representation.
- `indexeddb.json.gz` is the alpha first-install repository snapshot. Typed arrays are losslessly
  tagged `{ "alphaUint8Array": [...] }`. `catalogs.json` is the alpha CLI's parsed project metadata.
- `save.json` is a synthetic non-empty alpha save using the actual Ashvault key/schema, not progress
  earned by the short recording. The recorded game paths start with empty saves. Alpha has no public
  replay file format; its frame/input records and final revision-1 snapshot are the pre-V1 replay
  compatibility inputs. Do not invent a historical `.pxrec` envelope.
- `metrics.json`, `latency.json`, `bundles.json`, `audio.json` freeze the measured baseline. PCM is
  48 kHz, interleaved left/right IEEE float32 little-endian over 240×800 samples per channel. Voice
  peaks use the alpha production synth's post-frame active-voice count. The PCM fixture is measured
  by feeding actual recorded browser commands to the unchanged production synth, not a new synth.

Production-rasterizer tests compare all 720 recorded framebuffer hashes and canonical synth output.
Shared-core tests also recompile all three original sources using the native compiler, execute the
recorded inputs and compare every work/command/save/state result plus the core's own pixel/PCM output,
then restore and forward-run the full Worker-owned devices. Legacy state hashes use the explicit
revision-1 projection; the complete new snapshot is also compared after replay.
This is not yet a public CLI headless runner or Chromium parity check; those remain required.
Short paths do not cover complete game progression or save writes.

Recording commands (archival only, refuse post-alpha implementation diffs and existing outputs):

```sh
pnpm --dir apps/studio exec vite preview --host 127.0.0.1 --port 4173 --strictPort
node scripts/record-alpha-baseline.mjs
node scripts/record-alpha-baseline.mjs --latency-only
node scripts/record-alpha-metadata.mjs
```

The separate latency-only run splits Cinder's declarations/functions and callbacks into two modules
inside an isolated test browser profile. No original source files or user browser data are edited.
Initial recorder attempts failed on an off-by-one capture boundary; the final recorder gates the
game callback at execution time because Promise continuations may run between message listeners.
All retained traces have contiguous frames 0–239 and 240 corresponding renders/snapshots.
