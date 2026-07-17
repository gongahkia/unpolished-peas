# unpolished-peas audit — 18 Jul 2026

## Scope

Static repository audit plus current web research. This is not a usability study or an independent production-game benchmark.

## Verdict

unpolished-peas has a substantial pre-1.0 implementation, but no public adoption proof. Its first release path is not yet trustworthy: the generated project pins `v0.0.3`, while the clean-consumer CI substitutes a local dependency instead of proving the public archive and hash.

The agreed direction replaces the previous broad-engine trajectory: **a small Zig 2D rendering framework for indie and game-jam developers, with a stable desktop and browser contract.** It will compete on a dependable first game, direct rendering performance, and testability—not engine breadth.

## What is already strong

- SDL-free core plus separate desktop runtime, browser host/runtime, developer tooling, and optional effects, physics, and extension infrastructure.
- Deterministic headless rendering, golden images, input replay, fuzzing, downstream fixtures, performance budgets, and release gating.
- Cross-backend SDL GPU/OpenGL capture comparison and desktop package smoke coverage on macOS, Linux, and Windows.
- Local runtime diagnostics: screenshots, command JSON, Chrome trace JSON, replay data, metadata, and failure log.
- Runtime failure phase reporting, in-window error state, asset-reload location diagnostics, retained last-valid asset content, F3 overlay, F12 screenshots, and renderer-selection diagnostics.
- Local diagnostics and no default transmitted telemetry.

This is unusually good regression and failure evidence for an early engine.

## Historical diagnostics findings

The following observations were retained from the original audit for context. They are not the active roadmap: the agreed future direction supersedes their expansion-first priority, and parts of this work now exist in the current tree.

### Original observations

- `unpolished-peas.log` is append-only plain text. It has no timestamps, severity, category, session ID, frame correlation, rotation, or retention cap.
- Failure bundles contain only the generated failure summary, not a bounded tail of the persistent engine log. The most useful chronological context is therefore absent.
- Runtime diagnostics use fixed artifact names in one directory. Later failures overwrite earlier evidence.
- `metadata.json` describes artifacts, but not environment: engine/game version, Git/build ID, OS/arch, SDL version, GPU/driver, renderer matrix, launch arguments, asset root, or effective runtime config.
- The profiler has four fixed scopes (`callback`, `update`, `draw`, `asset`), 64 samples per frame, and no named application scopes or GPU timestamps.
- The renderer capability contract is late-failing. For example, `run-primitives --renderer opengl` selects OpenGL and only fails during presentation because it starts with a pixel effect. The platformer can trigger the same error while its action-driven effect is active.
- The inspector has useful asset/input/metrics panels but no complete interactive diagnosis flow or support-bundle workflow.

### Original proposed order

1. **Capability preflight.** Games declare required and optional renderer features. Before opening the loop, select a compatible backend, degrade an optional feature with a visible warning, or fail with a recovery command. Never fail a known capability mismatch in `present`.

2. **Structured public logging.** Provide levels, categories, key/value fields, monotonic time, wall time, session ID, frame, and sinks for terminal, JSONL file, and bounded in-memory ring buffer. Remote telemetry remains opt-in only.

3. **Immutable diagnostics bundles.** Write to `diagnostics/<session>/<timestamp>-<failure-id>/`; include environment manifest, renderer diagnostic state, bounded persistent-log tail, active config, command/replay snapshot, screenshot, trace, and commands. Add size caps and retention.

4. **`peas doctor`.** Validate Zig version, dependency resolution, project assets/maps, selected target prerequisites, SDL setup, GPU/backend capabilities, and known incompatible feature combinations. Emit a machine-readable report plus a short recovery command.

5. **Interactive developer UX.** Make the F3 overlay navigable with tabs for backend capabilities, reload events, bindings, profiler timeline, and physics-provider state. Add copy-path/copy-report actions and a `peas support-bundle` archive command with configurable redaction.

6. **Tracing depth.** Support named game scopes, a bounded multi-frame ring buffer, frame markers, custom counters, and optional GPU timing where the backend permits it.

7. **Capability test matrix.** Every sample must declare whether each backend is supported, degraded, or rejected. CI must assert the documented behavior and recovery text.

## Comparison with established engines

| Area | unpolished-peas | LÖVE | raylib | Ebitengine |
|---|---|---|---|---|
| Primary audience | Zig, 2D desktop | Lua, 2D | C plus bindings | Go, 2D |
| Platform story | macOS/Linux/Windows packages plus browser host; no release-parity proof | Desktop, Android, iOS | Desktop, Raspberry Pi, Android, web | Desktop, web, Android, iOS |
| Public ecosystem proof | None yet | Docs/forums/Discord/subreddit | 60+ bindings, tools, examples, games | Go ecosystem, examples, showcase |
| Public stars, 16 Jul 2026 | 0 | 8.5k | 33.9k | 13.3k |
| Release history | Draft `v0.0.3` | 17 releases | 25 releases | 163 releases |

LÖVE supports Windows, macOS, Linux, Android, and iOS, and exposes community support through its wiki, forums, Discord, and subreddit. [Source](https://github.com/love2d/love)

raylib documents broad platform support, 60+ language bindings, 120+ examples, project templates, tools, and a large community. It also provides 3D, shader, and post-processing functionality; matching its scope is not a sensible goal for a 2D-first Zig engine. [Source](https://www.raylib.com/index.html)

Ebitengine documents graphics, audio, input, and platform support across desktop, web, Android, and iOS. [Source](https://ebitengine.org/en/documents/features.html)

The main comparison failure is not a missing primitive API. It is absent public proof: released artifacts, shipped games, external users, docs, community support, and a predictable compatibility record.

## Adoption blockers

- The root description says “Small Zig 2D engine experiment.” That correctly signals maturity but discourages risk-averse users and agents.
- The README leads with test matrices, backend details, and package internals before a newcomer sees a polished result.
- Public documentation is shallow: one small Quickstart and testing guide, with no clearly hosted full API reference or learning path.
- The root project defaults to pinned SDL source while the generated starter requires system SDL3 and `pkg-config`; this increases setup ambiguity.
- Zig `0.15.1`/`0.15.2` pinning is technically rational but restricts the potential audience while Zig evolves quickly.
- The scope is broad—physics, effects, extension infrastructure, and advanced gameplay systems—before a clear primary user journey is proven. This risks complexity without demand.
- There is no non-draft public release, changelog/migration contract, showcase, external game, community venue, contributor guide, or evidence of independent users.
- Web search for the engine name does not surface it; results instead foreground other Zig engines and communities. [Source](https://ziggit.dev/t/mutual-help-on-zig-gamedev/12706)
- Browser packaging exists, but a release-grade WebGL2/WebGPU matrix and publicly playable proof games do not. A web-playable demo is a stronger discovery mechanism than a repository clone.

No open issues does not demonstrate reliability when there are no observed outside users.

## Agreed future direction

### Product contract

> A Zig-first, high-performance 2D rendering framework for small indie and game-jam games, with one stable `init`/`update`/`draw` contract across native desktop and browsers.

- **Audience:** Zig indie and game-jam developers.
- **Stable v0.1 core:** lifecycle, presentation, 2D drawing and text, input, audio, assets, fixed timestep, desktop packaging, browser export, and deterministic headless test hooks.
- **Platforms:** macOS, Linux, Windows, and evergreen Chromium, Firefox, and Safari. Every target is release-grade.
- **Browser renderers:** WebGL2 and WebGPU both pass the same stable-core rendering, input, audio, and packaging matrix. Platform-specific capabilities stay outside the stable core.
- **Primary path:** from a released checkout, `zig build new -- game`, `cd game`, then `zig build run` works from empty Zig caches without a local-path substitution or system SDL dependency.
- **Advanced path:** explicit control flow remains available, but the starter and learning path use the three callbacks.

### Explicit cuts before v0.1

Remove, rather than merely hide, Box2D physics, effects/shaders/lighting, extension metadata and resolution, and advanced tile/collision systems. Preserve the removal rationale in Git history and do not add root exports or new engine-owned systems without an approved core-contract revision.

Networking, relays, hosted services, and Box2D physics are outside the v0.1 core; the historical reference above has been corrected accordingly.

Effects, shader assets, lighting, and public GPU-resource APIs are also outside the v0.1 core; the historical references above are retained only as audit context.

Tile maps, tile colliders, character controllers, collision geometry, and broadphase APIs are pre-v0.1 cuts; the historical references above are retained only as audit context.

### Performance and evidence

- Treat 2D rendering performance as a product requirement. Use versioned, representative workload baselines and tolerances per target; block regressions instead of making cross-engine speed claims.
- Split CI into a small required PR suite and capability-defined nightly/release matrices. Green status must correspond to a documented platform/core capability.
- Publish three complete source-available proof games—puzzle, top-down, and platformer—with packages, browser builds, screenshots, deterministic tests, and short postmortems.

### Priority order

1. Repair and prove the released-checkout first win and release gate.
2. Define and reduce to the stable v0.1 core API; hard-cut excluded systems.
3. Achieve release-grade native, WebGL2, and WebGPU parity for that core.
4. Establish rendering performance workloads, baselines, and regression gates.
5. Publish concise, versioned docs, copyable examples, and the three proof games.

## Bottom line

The adoption path is a tiny, stable, high-performance 2D framework with a proven first command—not a broad engine ecosystem.
