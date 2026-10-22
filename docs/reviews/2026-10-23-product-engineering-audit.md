# Product and engineering audit — October 23, 2026

Peas aims to make a small 2D game understandable, deterministic, testable, and
portable without making the game depend on an editor, ECS, physics engine, or
content schema. Its product is primarily an authoring workflow: learn from
Seed Sprint, write ordinary Zig game state, test without a window, then use a
desktop or browser host and package the result.

The architecture broadly delivers that intent. The largest gaps found were
host correctness, browser usability, and release truthfulness, rather than
missing game systems. This audit preserves the public facade and the explicit
ownership model. All `README.md` files were left untouched as requested.

## Principles mapped to the repository

| Principle / user outcome | Evidence inspected | Assessment and action |
| --- | --- | --- |
| Start small and learn progressively | `docs/index.md`, quickstart, compiled tutorial, `templates/starter`, both dogfood games and friction logs | The three-project progression is sound. Corrected stale release claims; retained the compiled tutorial as the canonical API example. |
| Keep game rules in ordinary Zig | `src/unpolished_peas.zig`, `src/api.zig`, `src/core_api_snapshot.zig`, game state/collision code | Six public namespaces and snapshot/dependency checks enforce a boundary. Physics, ECS, networking, tilemaps, and an editor are deliberate exclusions, not missing features. |
| Deterministic simulation independent of presentation | `src/app.zig`, `frame_timing.zig`, `input.zig`, `input_replay.zig`, `test_support.zig`, Canvas trace and fixture tests | Fixed updates, explicit seeds, latched input and layered state/command/pixel tests are substantive. Corrected browser event accumulation that contradicted this contract. |
| Explicit resource ownership and failures | `GameContext`, `GameProtocol`, assets, surfaces, native save store, developer reload | Resources have owned lifetimes and failures remain explicit. Corrected failed teardown so a second cleanup cannot repeat resource release. |
| Equivalent drawing across hosts | `src/browser/host.mjs`, `webgpu_backend.mjs`, renderer corpus, SDL adapter and renderer guides | Reproduced the existing nightly failure: WebGL presented frames vertically inverted. Corrected framebuffer sampling, including post passes. Also isolated WebGPU material vertex/uniform data until GPU submission. |
| Portable input and recoverable host capability | Browser DOM input, native SDL mapping, shared input fixture, renderer selection, audio/storage hosts | Corrected summed pointer movement, physical keyboard aliases, standard controller triggers, and WebGPU acquisition before adapter availability. Tab can leave the browser canvas. |
| Clear player/developer feedback | Generated HTML, bootstrap, diagnostics, inspector/overlay code and guides | Native diagnostics are substantial. Browser startup was a bare canvas with console-only errors. Added an optional responsive shell with loading, error, recovery, focus, and sound-activation guidance. |
| Keep optional tooling outside simulation | `developer_diagnostics.zig`, `developer_assets.zig`, `dev_server.py`, tooling guides/tests | Native reload swaps valid decoded assets; browser development serves the last good snapshot. Diagnostics and development reload remain outside saves/replays and production watcher code. |
| Small, game-owned persistence and audio | SaveStore/native/localStorage implementations, audio service and tests, Seed Sprint | Bounded opaque saves, recoverable output failure, reusable SFX, and one streamed music track match the intended scope. No serializer, cloud store, playlist, or audio editor is warranted by this audit. |
| Honest, reproducible shipping | Manifests, release scripts, capability catalog, GitHub release and workflow history | `1.0.0` exists, but the checkout still called itself an unpublished `0.1.0`. Corrected metadata/guides per maintainer direction and fixed release ordering, tag naming, dry runs, and version validation. Existing tags were not changed. |
| Tests protect actual user paths | Zig suites, browser tests, package fixtures, GitHub Actions | Existing desktop coverage is extensive. Added push/PR browser contract, actual browser interaction, and pixel-parity checks; fixed temporary-directory loss of diagnostics. |

## Reproduced defects and fixes

| Severity | Defect and impact | Resolution / evidence |
| --- | --- | --- |
| High | WebGL's framebuffer UVs inverted the complete frame and every post pass. Nightly Chromium parity was repeatedly red. | Corrected the framebuffer UV orientation. Before: maximum channel error 236; reflecting the failed capture vertically produced an exact match. After: browser parity maximum delta 0; CPU reference delta at most 1. The tolerance was not loosened. |
| High | WebGPU reused vertex/uniform storage for pending material draws and the final blit. Later queue writes changed earlier draws. | Separate bounded vertex ranges and per-draw uniform buffers. Regression coverage checks overlapping queue writes and real captures with two different material draws and zero, one, and two post passes. |
| Medium | `auto` acquired a WebGPU canvas before knowing whether an adapter existed, preventing a subsequent WebGL context. | Request the adapter/device first; regression verifies that an unavailable adapter does not acquire the canvas. |
| High | A failing `Game.deinit` left the protocol initialized, allowing cleanup again or callbacks against released resources. | End the lifecycle before invoking cleanup, preserve the original failure, reject subsequent update/draw, and require a new initialization. Focused regression fails against the previous implementation. |
| Medium | Browser motion retained only the last event; a wheel event could erase movement. Aliases could release a still-held action, and standard triggers always read as zero. | Sum motion until consumed, track held physical codes, and read standard triggers from analog buttons 6/7. Tests cover serialized ABI state and reset boundaries. Mapping follows the [W3C Gamepad layout](https://w3c.github.io/gamepad/#remapping). |
| High | Browser failures left a blank canvas; Tab was prevented and trapped keyboard navigation. | Visible status/recovery controls, accessible canvas labeling, focus indication and Tab navigation. See the interface review below. |
| Medium | The packaged starter used a 320×180 canvas although Seed Sprint is authored at 160×90. CSS sizing could also alter initial logical dimensions. | Match starter dimensions and use authored canvas dimensions independently of CSS scale. |
| Medium | Seed Sprint's control instructions extended beyond the canvas, and large saved scores could exceed its formatting buffer. | Split instructions into a protected two-line footer and fit both full-width scores using compact labels when necessary. |
| High | Published version and package/docs disagreed. The release gate downloaded public assets before publication; a normal branch dry run used `main` as a version; unprefixed tags never triggered release. | Align with `1.0.0`; accept plain and prefixed tags; keep pre-publication local consumer validation and run public consumer validation downstream of publishing. Manual dry runs honor their input and retain package artifacts. Validate the archived ref's manifest, not an unrelated working-tree manifest. |
| Medium | A relative diagnostics root was interpreted under a temporary browser directory and deleted at exit. | Resolve it against the checkout before changing directories in renderer and Chromium smoke scripts. |
| Medium | Browser regression tests existed but were not part of normal push/PR checks. | Add browser-host and browser-rendering jobs. Required desktop capability rows and performance thresholds remain intact. |
| Medium | The checked-in browser demo predated current runtime modules and fixtures, so it did not represent the source being reviewed. | Regenerated the complete tracked bundle, including Wasm, assets, runtime modules, and verified checksums. |
| High | Release preparation served the wrong local archive directory, so the real dependency-hash fetch returned HTTP 404. Its generated version was also hardcoded. | Serve the archive directory and derive the template version from the selected release. A temporary repository regression exercises real HTTP fetching, both tag spellings, and archive stability without creating a release. |

## Full interface review

Scope: generated browser game pages, startup and recovery, keyboard/pointer
entry, and the native developer tooling's source/documented behavior. The web
UI uses vanilla DOM and plain CSS; no frontend framework or styling dependency
was added. Custom embeds opt into the shell through `data-peas-shell`.

| Category | Evidence inspected | Result |
| --- | --- | --- |
| Typography | Generated shell at desktop and 360px viewport; game HUD/source; loading/error copy | Added readable system text, balanced headings and wrapping instructions. Canvas text remains game-authored. |
| Surfaces | Canvas sizing, focus indicators, controls, startup/failure/retry states | Fixed canvas size/readability, named the canvas, added visible focus and 44px controls. |
| Animations | Bootstrap/shell CSS, loading/recovery transitions, game loop | No shell animation added. Game animation remains fixed-step content; there is no UI transition to inspect at 10% speed. |
| Icons | Generated shell and game entry controls | Text controls; no icon library or icon-only actions. Native bitmap diagnostics were source-reviewed, not redesigned. |
| Performance | Shell/bootstrap lifecycle, intrinsic dimensions, browser input and rendering tests | Shell has no polling/animation loop or UI dependency. CSS scaling leaves logical game dimensions unchanged. |

### Feedback, keyboard access, and readable surfaces

| Severity | Location | Before | After | Why |
| --- | --- | --- | --- | --- |
| High | `src/browser/bootstrap.mjs`; `src/browser/shell.mjs` | Console-only startup/device-loss failure | Live loading/ready/error text, reload and renderer fallback controls | State must be visible and recovery actionable. |
| High | `src/browser/input.mjs`; `src/browser/shell.mjs` | Tab prevented; unlabeled canvas; no focus instructions | Tab leaves the game; canvas has a name/help association, visible focus and an explicit focus button | Keyboard users must be able to enter and leave an interaction. |
| Medium | `script/package_web.sh`; starter and dogfood `build.zig`; `src/browser/shell.mjs` | Bare, small canvas; incorrect starter dimensions | Responsive game surface, clear heading/help, correct 160×90 starter backing size, 44px controls | Readability and usable targets without changing simulation coordinates. |
| Medium | `templates/starter/src/game.zig` | Clipped controls and unsafe score formatting | Two readable control lines, reserved footer space and full numeric scores | The starter must teach its controls and remain playable with valid saved data. |

Considered and rejected: adding an icon system would add no useful meaning to
these few controls; animated loading or button scaling would add distraction
to a game page; imposing the shell on custom embeds would conflict with their
own layouts. The shell is deliberately optional and static.

Verification: `script/test_browser_shell.sh` exercises real Chromium loading,
failed Wasm retrieval, unsupported renderer, retry, fallback preserving URL
parameters, keyboard entry/exit, and narrow viewport layout. Browser material
checks inspect all pixels across both renderers and three post-pass counts.
Desktop and narrow-viewport screenshot inspection cover the generated starter. Automated checks
do not establish screen-reader usability or physical controller/audio hardware
behavior on every supported OS; those remain unverified manual checks.

Verdict: **Approve** for the reviewed generated-page changes. Unverified:
manual screen-reader usability and physical controller/audio device checks.

## Remaining product decisions and intentional limits

| Area | Remaining gap or boundary | Next decision |
| --- | --- | --- |
| Published downloads | `1.0.0` has no attached prepared source package, checksums, or desktop builds. Correcting `main` does not retrofit that immutable release. | Prepare a new patch release after its final CI checks. No release was published during this audit. |
| Project license | Third-party notices exist; the project has no chosen top-level license. | Maintainer must choose the license. This audit does not invent a license decision. |
| Protected README | Its short examples use an older SDL-context style that differs from the current `GameContext` tutorial. Other README wording can still contain old draft references. | Left untouched by request. Use the compiled quickstart and guides for the current contract. |
| Browser support | WebGL/WebGPU remain preview under the capability catalog; Firefox WebGPU is unsupported. | Promote a target only with the documented coverage/compatibility decision. |
| Platform evidence | Automated package/runtime evidence is distinct from manual device testing. Intel macOS and browser checks do not prove every Apple Silicon, Windows, Linux audio, gamepad, or driver combination. | Retain the honest platform matrix and collect device-specific evidence before broader claims. |
| Distribution UX | Desktop archives are executable/assets layouts, not signed installers or app-store deliverables. | Add signing/installers only when they become a shipping requirement. |
| Game features | No text shaping/fallback stack, touch control scheme, GPU-owned RenderSurface, game editor, physics, tilemap system, or networking layer. | These are documented scope boundaries; avoid adding them without a concrete game need. |

## Validation record

The audit uses the repository's existing test layers rather than treating a
successful compile as runtime evidence:

- `zig build test`: initial baseline, 195 tests passed; the teardown regression
  was also reproduced separately and passed after the correction.
- Combined core, test-support, scene, starter, documentation, browser-runtime
  and browser-contract validation: 317 tests and 54 build steps passed after
  the runtime corrections.
- `zig build test-docs test-peas test-core-api`: 102 tests passed and the public
  declaration snapshot compiled after the version/documentation changes.
- Eleven browser host/development targets: 22 build steps passed, including
  input, WebGPU, WebGL, audio, storage, assets, diagnostics, artifacts and dev server.
- Real Chromium renderer corpus: exact WebGL/WebGPU match, existing CPU tolerance
  retained. The complete shell/material integration script passed locally and
  is also wired into normal CI.
- `actionlint`, release wiring, version consistency, formatting and diff checks.
- Source archives built using both `1.0.0` and `v1.0.0` names produce identical
  bytes from the same commit. This is local archive evidence, not a published
  package-consumer claim.

GitHub Actions for the final committed revision are the handoff gate. Consult
the linked run in the handoff for final remote job results; historic failed
nightlies remain useful evidence of the original renderer defect.
