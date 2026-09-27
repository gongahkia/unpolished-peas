# MOD-01 baseline fixtures

These are reproducible MOD-01 V1 browser-baseline artifacts. Refresh them only
from a clean local production Studio preview using the commands in
[`docs/V1_RELEASE_EVIDENCE.md`](../../../docs/V1_RELEASE_EVIDENCE.md).

- The three `.m01c` files are the canonical MOD-01 cartridge outputs.
- Each compressed trace records a controlled 240-frame production Worker run:
  configuration, input, work, draw/audio/save commands, indexed framebuffer
  hashes, complete runtime snapshot hashes, and the final snapshot.
- `indexeddb.json.gz` is a fresh Studio repository capture. Typed arrays are
  stored losslessly as `{ "mod01BaselineUint8Array": [...] }`.
- `catalogs.json`, `bundles.json`, `metrics.json`, `latency.json`, and
  `audio.json` hold the corresponding build, latency, catalog, and synth data.

The suite recompiles each captured source with the native MODL compiler and
compares it with the production runtime for the same deterministic inputs. No
legacy input, storage, cartridge, or replay format is a fixture or compatibility
target here.
