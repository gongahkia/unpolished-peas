# CI

## Required pull-request suite

`zig build test-docs` checks source-derived API pages for stale signatures,
defaults and recipe excerpts, validates member fragments, and executes the
documented native/Wasm recipes using Node.js 24. `zig build docs` also checks
the links in its emitted Markdown bundle, including linked source snapshots.
After intentional API/example/template changes, refresh the checked pages
with `zig build docs-update-api -Dwith_sdl=false` and review their diff.

Pushes and pull requests also run `browser-host` for the DOM/renderer/audio/
storage host contracts, browser development server, and version/release
wiring, plus `browser-rendering` for real Chromium shell interactions and
the WebGL 2/WebGPU/CPU-reference pixel comparison. These checks catch browser
regressions before the nightly matrix. Renderer failure artifacts are retained
under the checkout even when a test uses a temporary working directory.

`browser-host` also runs `test-browser-input-v2`, passing real host-generated
input packets through Wasm decoding, fixed-step buffering, the portable input
workbench, and replay. `browser-rendering` runs
`script/test_browser_input_workbench.sh` for real Chromium text/IME events,
focus changes, Unicode commits, and textarea cleanup.

The portable asset recipes and initialization-failure coverage run through
`test-asset-workbench`. `test-browser-asset-collection` compares the same game's
pixels and saved bytes natively and in Wasm. The real Chromium job also runs
`script/test_browser_asset_workbench.sh`; the non-PR downstream job builds that
game outside the checkout against a verified source archive through
`test-asset-collection-consumer`.

`test-audio-lifetime` runs native Debug/ReleaseFast release, PCM, slot/memory
reuse and failure checks, and is included in default tests.
`test-browser-audio-lifetime` repeats them in Wasm, including allocator failures
and linear-memory plateaus; `test-docs` and `browser-host` run this comparison.
`browser-rendering` also runs `script/test_browser_audio_lifetime.sh` for real
Chromium transitions, paused-source release, WebAudio submissions and cleanup.
The explicit `script/test_native_audio_lifetime.sh` needs a display and audio
device; its UUID namespace is removed after the run. The SDL suite's queue
check skips when no output device is available. Neither check establishes
physical speaker quality. See [audio lifetimes](audio-lifetimes.md).

`stable-core-capability` is the intended required pull-request matrix; `capability-matrix` is its generated-matrix dependency. The matrix is generated from `docs/capabilities/v1.0.json`; it selects only supported desktop SDL GPU rows.

`nightly.yml` consumes the nightly matrix from the same catalog. It runs the documented macOS, Linux, Windows, Chromium, Firefox, and separately forced Safari WebGL2/WebGPU rows, preserving renderer diagnostics and workload artifacts under the matrix identity. Unsupported Firefox WebGPU is absent.

Its separate `portable-authoring` job runs `test-browser-authoring` on Intel
macOS with Node 24 and locked Playwright test dependencies. It installs the
matching Firefox, enables Safari WebDriver and runs the same archive-consumer,
font and audio assertions in Chromium/Firefox/real Safari with WebGL 2.
The job has a 35-minute limit; its matrix step has 10 minutes. It retains all
authoring diagnostics even on failure and does not change capability statuses.
`browser-host` also runs `test-browser-authoring-contract`, which rejects empty
captures, bad pixels and unavailable prerequisites reported as success. See
[browser authoring verification](browser-authoring.md).

The matrix enables `-Dauthoring-logging=true`: each browser must retain valid
session-correlated JSONL with no console-sink errors, bound repeated failure
incidents and export them through the real JSON support-bundle CLI. The same
job runs `test-runtime-logging` separately with a six-minute step limit, after
the browsers so native windows cannot steal Safari focus. Its nine compiled
native cases cover original init/update/draw/cleanup errors, repeat launches,
filters, blocked output, explicitly disabled collection and early video failure.
Evidence is uploaded from `zig-out/diagnostics/local-logging/**` alongside the
browser artifacts. Limits bound each step; the job-wide deadline still applies.

Safari WebGL checks independently probe rendering and canvas PNG export on a
blank page before loading Peas. A runner whose PNG encoder returns an empty
data URL still has to pass the Peas Wasm renderer's pixel readback and every
input, audio, storage, diagnostic, and lifecycle check. Its nullable capture
result, independent probe, runtime pixels, and WebDriver screenshot are retained;
a working runner PNG encoder continues to require a valid Peas PNG capture.

Nightly and tag-release capability rows run `script/check_workload_performance.sh` on macOS/Linux and `script/check_workload_performance.ps1` on Windows after their supported SDL GPU checks. Each records a `ReleaseFast` workload artifact, compares it to the exact reviewed target baseline, and fails with target, workload, metric, baseline, observed value, and tolerance. Performance checks are intentionally absent from pull-request CI; baseline changes require a reviewed artifact record.

| Job | Rows | Checks | Execution budget |
| --- | --- | --- | --- |
| `capability-matrix` | all selected rows | validates and emits the matrix | 1 minute |
| `stable-core-capability` | macOS, Linux, Windows SDL GPU | formatting; frozen core API; deterministic unit, headless, and test-support checks; starter generation; clean external native and browser builds; starter browser package; documentation links; macOS/Linux generated-project host smoke | 15 minutes per row |

The budget is an operational target, not a wall-clock guarantee. Graphics failures retain `zig-out` diagnostics in the retained non-PR renderer-conformance jobs.

`zig build test-starter-external` generates a game outside the checkout with
the default local dependency. `zig build test-starter-external-web` generates
from a clean archive checkout with a prepared template, fetching the actual
archive over loopback HTTP and verifying its Zig package hash. Both execute
`zig build`, `zig build test`, `zig build web`, and `zig build package` on the
untouched generated game with separate generator/consumer caches, then verify
that the authored files did not change. Release checks also reject missing
coordinates and a URL paired with a real hash from different archive bytes;
no public release is needed. The bundled-SDL check runs the local case with a
failing `pkg-config` shim and a bounded native host smoke.

The real Chromium pull-request job also runs `test-starter-persistence` for an
untouched generated game's earned-score reload, followed by
`test-portable-conformance`. The latter uses a verified archive and isolated
native namespace for downstream builds, native restart, browser interactions,
failure recovery and UPR5 replay. Its logs, package hash, environment record
and PNG are retained under `zig-out/diagnostics/portable-conformance/`.

Surface composition differential tests run in Debug and ReleaseFast as part of
`zig build test`. `browser-host` runs `test-browser-surface-composition` to
compare exact native/Wasm pixels and trace hashes against a scalar reference;
`browser-rendering` runs `script/test_browser_surface_composition.sh` in real
Chromium. Logs and browser metadata are retained under
`zig-out/diagnostics/surface-composition/`. The focused performance comparison
is a separate manual experiment; no pull-request timing gate or performance
budget is changed. See [surface measurements](surface-composition-performance.md).

Authored text layout runs through `test-font-layout` in native Debug and
ReleaseFast and `test-browser-font-layout` in Node-hosted Wasm. Both are
included in `test-docs`; the native suite is also in `test`. The
browser-rendering job runs `script/test_browser_font_layout.sh` for the
compiled proportional-font menu/dialogue example. It checks visible text and
real keyboard-driven selection/page changes and retains a screenshot and
browser metadata under zig-out/diagnostics/font-layout.

## Non-PR validation

The nightly macOS portable-authoring job also runs `test-render-capacity` with
native/Wasm ReleaseFast. Its short mixed GameProtocol workloads verify exact
native-reference/browser pixels and zero game-owned frame allocations at
three resolutions with nearest/linear composition. The job retains
`zig-out/diagnostics/render-capacity/` artifacts and has a 25-minute bound,
with 10 minutes for this step. Timing distributions are diagnostic only;
full three-round measurements remain manual experiments. See
[GameProtocol capacity](game-rendering-capacity.md).

The same nightly job runs `test-browser-chess` with an eight-minute step bound
and retains `zig-out/diagnostics/chess/`. Native chess rules and headless game
checks are included in `zig build test`; browser checks use the shared adapter
and exact native frame references, without adding a performance threshold.

Package, proof-game, renderer, release-compatibility, and next-Zig jobs run outside pull requests until their owning removal or release issue changes that policy. They are not stable-core required checks.
