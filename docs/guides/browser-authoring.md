# Browser authoring workflow verification

`zig build test-browser-authoring` runs the same public-package consumer and
compiled font/audio examples in real Chromium, Firefox and macOS Safari with
WebGL 2. The [platform record](platforms.md) separates this automated evidence
from manual hardware checks. Browser renderers remain preview.

## Prerequisites and commands

Use Zig 0.15.2 and Node 24. The test-only Playwright dependency is locked in
[package.json](../../script/browser-authoring/package.json) and
[package-lock.json](../../script/browser-authoring/package-lock.json), using
the same Playwright build as the existing CLI at implementation time.
It is not a dependency of a generated game's normal build or browser output.

```sh
npm --prefix script/browser-authoring ci --ignore-scripts --no-audit --no-fund
PLAYWRIGHT_SKIP_BROWSER_GC=1 \
  node script/browser-authoring/node_modules/playwright/cli.js install firefox
zig build test-browser-authoring -Dwith_sdl=false -j2 --summary all
```

The Chromium adapter uses installed Google Chrome's headless channel. Firefox
uses Playwright's matching real Firefox build. Safari uses the installed macOS
Safari through safaridriver; Playwright WebKit is not substituted. Enable
**Safari Settings → Developer → Allow remote automation** before running it.

When needed, the runner starts its own loopback Safari WebDriver on a free
port and stops that process afterwards. An existing service on port 4444, or
an explicit UP_SAFARI_WEBDRIVER_URL, is reused without being stopped.
A busy service is reported unverified rather than replacing its session.
Run Safari checks serially: competing automation windows can steal focus.
The Safari adapter activates its actual WebDriver window before trusted or
injected input actions when necessary; observations do not activate the window.
It does not inject focus/key events to bypass focus checks. Composition events
remain explicitly injected test input, not physical IME validation.

For a selected subset:

```sh
zig build test-browser-authoring -Dauthoring-browsers=firefox \
  -Dwith_sdl=false -j2 --summary all
PEAS_AUTHORING_BROWSERS=firefox,safari script/test_browser_font_layout.sh
PEAS_AUTHORING_BROWSERS=firefox,safari script/test_browser_audio_lifetime.sh
```

The existing example scripts retain Chromium as their default. They also
accept the older UP_BROWSER selector. Their shared runner installs the locked
Node dependencies if needed; installing Firefox remains an explicit setup
step. Requested browser names and actual versions are retained in the report.

## External consumer and shared assertions

Add `-Dauthoring-logging=true` to the build command to verify opt-in structured
logs and failure evidence. Every case validates the v1 event schema, correlation,
retention bounds and zero console-sink errors, persists session-specific runtime
artifacts, then exports them through the real JSON/non-interactive support CLI.
The consumer induces six additional compiled init failures and verifies that
the latest four distinct incidents retain the original error with no leaked
resources or scheduled callbacks. Reports include exact artifact/export paths.
Nightly CI enables this option. [Local debugging](developer-diagnostics.md)
explains user-facing activation, formats and bounds.

The [existing consumer harness](../../script/test_portable_conformance.py)
takes a source snapshot, creates a real archive, computes its Zig package hash,
and serves it over loopback HTTP. A separate project outside the checkout has
an empty dependency cache and fetches that exact archive. Browser-matrix mode
builds `zig build web` and `zig build test-replay-wasm` there.

One consumer bundle is then served to all three browsers. The report records
archive/tree/hash coordinates and every built-file SHA-256. Authored project
files and built bundle hashes must remain unchanged after testing.
The harness injects test observation code into HTTP HTML responses, before
bootstrap; it never edits the built bundle or ships those observers in output.

The original `test-portable-conformance` still runs native build/test/package,
write/restart, replay and the Chromium consumer workflow. Browser-matrix mode
does not stand in for that native validation.

| Workflow | Assertions |
| --- | --- |
| External consumer | Authored image/font/atlas pixels; distinct Q/E and 1/2; Q/E releases; paused complete taps; Q→R rebinding; Unicode; persistence and actual reload; rejected-write preservation/retry; audio submission; partial-init rejection, cleanup and retry; shutdown |
| Authored font | Three full 320×180 frames compared with native CPU references: initial centered menu/wrapped dialogue, changed selection and next dialogue page |
| Audio lifetime | Initially blocked playback retains sources; trusted gesture activation; twelve transitions releasing paused music; stable three sound/two music registry slots and two sound/one music live sources; finite nonzero accepted PCM; no new submissions after shutdown |

Native [font references](../../examples/authoring_browser_reference.zig) are
generated from the actual compiled [menu/dialogue game](../../examples/font_layout_game.zig).
Full-frame readback checks 172,800 logical pixels per browser, with the existing
maximum absolute per-channel RGBA difference of one. References also establish
different narrow/wide advances and multiple dialogue lines. They are frozen
into each report directory with hashes, not regenerated from browser output.

The [shared checks](../../script/browser-authoring/checks.mjs) execute through
small [automation adapters](../../script/browser-authoring/adapters.mjs).
Browser-specific behavior stays in transport/setup. There are no CDP calls
in the shared consumer, font or audio checks.

## Input, audio and capture boundaries

Key actions are trusted browser automation events. The test verifies physical
bindings, release, rebinding and trusted committed text. Composition start,
update and end are explicitly injected DOM CompositionEvent/InputEvent values:
the preedit `Zo` must not save; injected composition commits `Zoë` once;
automation text insertion adds `你好`. The saved/reloaded bytes must be exactly
`Zoë你好`. Pending injected preedit must be canceled during failed reinit.
This is not physical keyboard-layout or operating-system IME validation.

Audio checks use a trusted canvas click and wait for AudioContext readiness
before requesting gameplay playback. Firefox may resume asynchronously.
Accepted nonzero finite PCM and bounded source ownership are verified; physical
speaker quality and sample-exact device scheduling are not measured.

Every browser first visits a blank page at the package's origin. The existing
independent WebGL red-pixel/PNG probe must pass before Peas loads. The Peas
Wasm renderer must then pass its own red-rectangle readback, regardless of PNG
availability. Safari's established nullable-PNG rule remains: only independently
unavailable export permits null capture, while renderer/pixel assertions and a
WebDriver screenshot are still required. Available PNGs must have a valid
signature and dimensions matching the readback. Empty images never pass.

## Automation issues resolved

- Safari WebDriver can emit a literal space with code Unidentified. Its
  adapter uses WebDriver's named Space key so the real event has code Space.
- Separate ordinary-character keyUp actions omitted DOM release in the tested
  Safari. The adapter uses WebDriver Release Actions for its single keyboard
  source; shared Q/E checks independently verify that held states clear.
- Safari WebDriver may leave BODY focused after the shell button's scripted
  transfer. A trusted canvas click plus an explicit focus assertion establishes
  the keyboard target.
- Fixed frame waits could race actual delivery. Font checks poll until the
  complete native reference matches or retain the exact mismatching byte.
- Firefox's first gesture can leave audio resuming. The harness waits for
  readiness after a real gesture instead of assuming synchronous activation.

These are harness/automation corrections; no game APIs, renderer implementation,
input ABI or deterministic goldens changed.

## Reports, failures and CI

The main report is
`zig-out/diagnostics/browser-authoring/consumer/result.json`. Its browser
subreport is `browser/result.json`. Per browser/case directories retain actual
version/user agent, renderer diagnostics, input-event observations, HTTP and
console/error logs, WebDriver capabilities, independent/runtime probes,
screenshots, raw RGBA readbacks and assertion failures. Native reference
snapshots and harness hashes bind the evidence to the code that ran.
On failure the external compiled web bundle is retained for reproduction.

Each requested browser/case is passed, failed or unverified. Missing browser
executables, disabled Safari automation or a busy service are unverified and
cannot produce a successful exit. The runner exits 69 for an unverified-only
run, 1 for assertion failures and 0 only when every requested case passed.
A subset run establishes evidence for its requested browsers only.

```sh
zig build test-browser-authoring-contract test-safari-webdriver-contract \
  -Dwith_sdl=false --summary all
```

Contract checks cover invalid/empty PNGs, empty or wrong native pixels, nullable
Safari capture, lost contexts, transport exceptions, standard key-source
release requests, request deadlines, cleanup and unavailable prerequisites never passing.
They complement real browsers rather than proving browser behavior themselves.

The nightly portable-authoring job runs the full matrix on Intel macOS, with
a 15-minute job limit and 10-minute matrix-step limit, and retains diagnostics
even on failure. Shared waits, navigation and WebDriver requests have bounded
timeouts; individual cases have a 150-second watchdog. PR browser-host checks
run the fast harness contracts. See [CI](ci.md).

## Recorded local evidence

Intel macOS 15.7.7, Zig 0.15.2, Node 24.19.0:

| Real browser | External archive consumer | Authored font | Audio lifetime |
| --- | --- | --- | --- |
| Google Chrome 157.0.8103.38 | passed | passed | passed |
| Playwright Firefox 158.0 | passed | passed | passed |
| macOS Safari 18.6 / Safari WebDriver | passed | passed | passed |

The matrix passed all 19 build steps. All three browsers passed their independent
PNG probe and Peas renderer readback. The unavailable-PNG path is separately
guarded by contract tests, not claimed as an observed limitation of this run.
Safari initially rejected sessions until Allow remote automation was enabled.

The wider unit/API/docs/replay/browser-contract suite passed 413 tests across
111 build steps; all 50 example/SDL build steps succeeded, including 64 SDL
tests. The original full archive-consumer/native-restart command also passed.
These checks retained the existing deterministic goldens and capability statuses.

This evidence covers WebGL 2 on this Intel Mac. It does not promote browser
support or establish new WebGPU, mobile, Apple Silicon, bare-metal Linux,
Windows, physical controller, physical IME, accessibility or speaker-quality
evidence.
