# Portable downstream workflow verification

The [conformance project](../../fixtures/portable-conformance/build.zig) is a
small external consumer of the public Peas package. Its
[game](../../fixtures/portable-conformance/src/game.zig) combines physical Q/E
and 1/2 controls, F5 rebinding to R, F4 Unicode name entry with separate preedit,
embedded image/font/Atlas resources, fixed-tick animation, sound, and progress.
The game imports no SDL, DOM, or private engine implementation. Wrappers supply
the host boundary; fixture-owned browser exports expose test observations.

```sh
zig build test-starter-persistence -Dwith_sdl=false --summary all
zig build test-portable-conformance -Dwith_sdl=false --summary all
```

The first command generates an untouched starter outside the checkout, builds
its web output, earns a seed through real browser keyboard events, checks its
rendered score and saved bytes, reloads, and checks the restored best score.
Frame captures are awaited explicitly while polling the HUD.

The second creates a source archive of the current worktree using the existing
private-index packaging helper, computes its real Zig package hash, and serves
it over loopback HTTP. It copies the conformance project outside the checkout
and replaces the fixture's dependency coordinates with that URL/hash pair.
The consumer has a separate empty package cache and must fetch and validate the
archive. No release is published and no public coordinates are invented.

## Consumer commands and isolation

Inside the external project, the harness executes:

```sh
zig build --summary all
zig build test --summary all
zig build web --summary all
zig build package --summary all
zig build test-replay-wasm --summary all
zig build run -Dtest-organization=<unique-test-id> -Dnative-phase=write -- --frames 3
zig build run -Dtest-organization=<same-test-id> -Dnative-phase=read -- --frames 3
```

Native tests use a fresh UUID in both organization and application names,
observe the actual SDL preference path, and remove only that UUID's directory
afterwards. They do not override the user's home directory or read another
game's saves. Both launches use the real SDL host, renderer, audio service and
native SaveStore. The write launch feeds a bounded scripted input sequence
through the portable game. The next process loads score 4, counters 1/1,
the R binding and exact name `Zoë你好`. This is automated native host evidence,
not physical keyboard or native IME interaction evidence.

The external web output runs through
[`test_portable_browser.sh`](../../script/test_portable_browser.sh). Chromium
checks authored image/font/Atlas pixels, Q/E movement, completed 1/2 taps during
paused zero-update frames, and replacement of Q with R. A real textarea and CDP
composition update/commit enter `Zoë你好`; preedit is excluded from the saved
name. The test observes accepted audio PCM submissions after a user gesture,
rejected storage writes preserving prior bytes, continued gameplay, a later
successful write, and actual reload of score 7, counters 2/2, binding and name.
Accepted PCM submission does not measure physical speaker output quality.

Lifecycle checks reject initialization after real asset allocations, verify
exactly-once cleanup and cancellation of old frames, retry with exactly one
scheduled frame, and repeat shutdown without a second game cleanup callback.
Failure is exercised with an active IME preedit: cleanup cancels that session
through the existing input ABI even though no subsequent frame will poll it.
The callback exercises Canvas/audio while those host capabilities must remain
alive. Shutdown removes the text-input element and clears the live game.

## Headless replay and failures

The [tests](../../fixtures/portable-conformance/src/tests.zig) cover every game
allocation failure, explicit partial-init rejection, desktop wrapper cleanup,
corrupt progress, unavailable storage and blocked audio. The session test
captures initial score 7 and name `Start` **before Game.init**, records the
integrated sequence, encodes/parses UPR5 and initializes a fresh replay from
those saved bytes. Final score is 11 and name is `StartZoë你好`; progress bytes,
logical drawing and pixels agree. A native/Wasm probe repeats that full session
three times in Wasm and compares with native output.

The fixture's `PCG1` progress is 82 explicit bytes: magic; little-endian u32
score/one-counter/two-counter; a rebound flag; name length; and 64 UTF-8 name
bytes. No raw Zig struct memory is persisted. The example has a 64-byte name
limit and simple font fallback, not a full localized editor.

## Integration failures repaired

| Failure | Evidence and repair |
| --- | --- |
| Starter silently lacked browser saves | The original runtime rendered earned score 1 but wrote no best score. It checked only `Game.storage_id`; the starter declares module-level `storage_id`. Both locations now work, retaining Game-level precedence. The corrected real-browser regression passes save and reload. |
| Named actions lost complete taps between updates | The paused browser test retained 1/2 edges in Input but neither action advanced because ActionMap only compared held values. ActionMap now caches digital edges too; tests cover normalized/physical keys, pointer, gamepad buttons, aliases and catch-up clearing. |
| Failed reinit retained a scheduled frame | Chromium observed an old callback after failed init. Shared cleanup now cancels the prior frame, resets ownership flags, releases partially initialized host resources, and retries with one frame. |
| Shutdown omitted game cleanup | Inspection found host capabilities were released without game deinit. Shared cleanup invokes it first. Regression checks exercise live capabilities during cleanup, count exactly one callback and repeat shutdown safely. |

APIs and replay formats are retained. Honoring already-recorded digital edges
intentionally repairs lost taps; existing replay/pixel/namespace goldens remain
assertions. High-level audio resources still belong to the Audio host.

## Recorded evidence — November 5, 2026

Environment: Intel x86_64 macOS 15.7.7 (24G720), Zig 0.15.2, Node 24.19.0,
Headless Chromium 156.0.0.0 with WebGL 2. Native launches selected Cocoa and SDL GPU/Metal and
reported audio ready. These local automated checks do not promote browser
status or establish interactive coverage for other hardware/browser targets.

```sh
zig build test test-core-api test-support test-replays test-starter \
  test-starter-template test-dogfood test-lantern-leap test-docs docs \
  test-browser-runtime test-browser-protocol-host test-browser-wasm-host \
  test-browser-input-v2 test-browser-asset-collection \
  -Dwith_sdl=false --summary all
```

Result: **82/82 steps and 393/393 tests passed**, retaining previous goldens.
The downstream project passed seven headless/lifecycle tests. Native/Wasm UPR5
pixels matched at hash **5381745576618378904**, with equal explicit progress
across three Wasm lifecycles. Archive-consumer build/test/web/package, native
write/restart and real-browser checks passed.

Additional successful checks:

```sh
zig build test-sdl check-examples --summary all
script/test_browser_input_workbench.sh
script/test_browser_asset_workbench.sh
script/test_browser_shell.sh
zig build docs test-docs -Dwith_sdl=false --summary all
zig fmt --check build.zig src examples templates dogfood fixtures/portable-conformance
git diff --check
actionlint .github/workflows/toolchain.yml
sh -n script/test_starter_persistence.sh script/test_portable_browser.sh
```

The SDL suite passed 63/63 tests and all 40 example build steps succeeded.
Existing input, asset workbench, browser shell and material checks also passed.

`zig-out/diagnostics/portable-conformance/` retains `result.json` with the exact
source tree, computed package hash, platform, toolchain and commands, plus
native logs, replay results, browser checks/environment and a PNG. Starter
baseline failure artifacts are in `zig-out/diagnostics/starter-persistence-before/`
and `zig-out/diagnostics/starter-persistence-before.log`. These generated
artifacts describe the tested run and are not published release assets.

Manual checks still include native keyboard layouts/IME, physical controllers,
subjective audio, accessibility tooling and interactive testing on remaining
hardware/browser combinations. See [platform evidence](platforms.md).
