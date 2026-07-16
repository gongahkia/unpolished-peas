# unpolished-peas audit — 16 Jul 2026

## Scope

Static repository audit plus current web research. This is not a usability study or an independent production-game benchmark.

## Verdict

unpolished-peas is a technically serious pre-1.0 Zig 2D engine, not yet an adoption-ready alternative to LÖVE, raylib, or Ebitengine.

The public repository snapshot has 0 stars, 0 forks, 0 open issues, and 290 commits. The `v0.0.3` release is still a draft. These are adoption signals, not an engineering-quality score. [Source](https://github.com/gongahkia/unpolished-peas)

[Inference] The credible niche is: **a Zig-first 2D engine for small desktop games with deterministic replay, visual CI, and excellent local failure diagnostics.** It should not compete on raylib feature breadth.

## What is already strong

- SDL-free core plus separate desktop runtime and optional ECS, effects, networking, physics, UI, tools, and services packages.
- Deterministic headless rendering, golden images, input replay, fuzzing, downstream fixtures, performance budgets, and release gating.
- Cross-backend SDL GPU/OpenGL capture comparison and desktop package smoke coverage on macOS, Linux, and Windows.
- Local runtime diagnostics: screenshots, command JSON, Chrome trace JSON, replay data, metadata, and failure log.
- Runtime failure phase reporting, in-window error state, asset-reload location diagnostics, retained last-valid asset content, F3 overlay, F12 screenshots, and renderer-selection diagnostics.
- Local diagnostics and no default transmitted telemetry.

This is unusually good regression and failure evidence for an early engine.

## Logging and debugging audit

### Current gaps

- `unpolished-peas.log` is append-only plain text. It has no timestamps, severity, category, session ID, frame correlation, rotation, or retention cap.
- Failure bundles contain only the generated failure summary, not a bounded tail of the persistent engine log. The most useful chronological context is therefore absent.
- Runtime diagnostics use fixed artifact names in one directory. Later failures overwrite earlier evidence.
- `metadata.json` describes artifacts, but not environment: engine/game version, Git/build ID, OS/arch, SDL version, GPU/driver, renderer matrix, launch arguments, asset root, or effective runtime config.
- The profiler has four fixed scopes (`callback`, `update`, `draw`, `asset`), 64 samples per frame, and no named application scopes or GPU timestamps.
- The renderer capability contract is late-failing. For example, `run-primitives --renderer opengl` selects OpenGL and only fails during presentation because it starts with a pixel effect. The platformer can trigger the same error while its action-driven effect is active.
- The inspector has useful asset/input/metrics panels but no complete interactive diagnosis flow or support-bundle workflow.

### Recommended order

1. **Capability preflight.** Games declare required and optional renderer features. Before opening the loop, select a compatible backend, degrade an optional feature with a visible warning, or fail with a recovery command. Never fail a known capability mismatch in `present`.

2. **Structured public logging.** Provide levels, categories, key/value fields, monotonic time, wall time, session ID, frame, and sinks for terminal, JSONL file, and bounded in-memory ring buffer. Remote telemetry remains opt-in only.

3. **Immutable diagnostics bundles.** Write to `diagnostics/<session>/<timestamp>-<failure-id>/`; include environment manifest, renderer diagnostic state, bounded persistent-log tail, active config, command/replay snapshot, screenshot, trace, and commands. Add size caps and retention.

4. **`peas doctor`.** Validate Zig version, dependency resolution, project assets/maps, selected target prerequisites, SDL setup, GPU/backend capabilities, and known incompatible feature combinations. Emit a machine-readable report plus a short recovery command.

5. **Interactive developer UX.** Make the F3 overlay navigable with tabs for backend capabilities, reload events, bindings, profiler timeline, and network/physics provider states. Add copy-path/copy-report actions and a `peas support-bundle` archive command with configurable redaction.

6. **Tracing depth.** Support named game scopes, a bounded multi-frame ring buffer, frame markers, custom counters, and optional GPU timing where the backend permits it.

7. **Capability test matrix.** Every sample must declare whether each backend is supported, degraded, or rejected. CI must assert the documented behavior and recovery text.

## Comparison with established engines

| Area | unpolished-peas | LÖVE | raylib | Ebitengine |
|---|---|---|---|---|
| Primary audience | Zig, 2D desktop | Lua, 2D | C plus bindings | Go, 2D |
| Platform story | macOS/Linux/Windows packages | Desktop, Android, iOS | Desktop, Raspberry Pi, Android, web | Desktop, web, Android, iOS |
| Public ecosystem proof | None yet | Docs/forums/Discord/subreddit | 60+ bindings, tools, examples, games | Go ecosystem, examples, showcase |
| Public stars, 16 Jul 2026 | 0 | 8.5k | 33.9k | 13.3k |
| Release history | Draft `v0.0.3` | 17 releases | 25 releases | 163 releases |

LÖVE supports Windows, macOS, Linux, Android, and iOS, and exposes community support through its wiki, forums, Discord, and subreddit. [Source](https://github.com/love2d/love)

raylib documents broad platform support, 60+ language bindings, 120+ examples, project templates, tools, and a large community. It also provides 3D, shader, and post-processing functionality; matching its scope is not a sensible goal for a 2D-first Zig engine. [Source](https://www.raylib.com/index.html)

Ebitengine documents graphics, audio, input, and platform support across desktop, web, Android, and iOS. [Source](https://ebitengine.org/en/documents/features.html)

The main comparison failure is not a missing primitive API. It is absent public proof: released artifacts, shipped games, external users, docs, community support, and a predictable compatibility record.

## Adoption blockers

- The root description says “Small Zig 2D engine experiment.” That correctly signals maturity but discourages risk-averse users and agents.
- The README leads with test matrices, backend details, services, and package internals before a newcomer sees a polished result.
- Public documentation is shallow: one small Quickstart and testing guide, with no clearly hosted full API reference or learning path.
- The root project defaults to pinned SDL source while the generated starter requires system SDL3 and `pkg-config`; this increases setup ambiguity.
- Zig `0.15.1`/`0.15.2` pinning is technically rational but restricts the potential audience while Zig evolves quickly.
- The scope is broad—services, networking, relay, physics, ECS, effects, UI—before a clear primary user journey is proven. This risks complexity without demand.
- There is no non-draft public release, changelog/migration contract, showcase, external game, community venue, contributor guide, or evidence of independent users.
- Web search for the engine name does not surface it; results instead foreground other Zig engines and communities. [Source](https://ziggit.dev/t/mutual-help-on-zig-gamedev/12706)
- Desktop-only distribution limits easy sharing. A web-playable demo is a much stronger discovery and virality mechanism than a repository clone.

No open issues does not demonstrate reliability when there are no observed outside users.

## Recommendation strategy

Position the project narrowly and honestly:

> A Zig-first 2D engine for small desktop games, built around deterministic testing and first-class local debugging.

Then earn trust in this order:

1. Ship a non-draft `v0.1.0` with copy-paste dependency installation, binaries/packages, compatibility policy, changelog, and known-limitations matrix.

2. Publish three polished complete games with source, downloadable builds, screenshots/GIFs, tests, and postmortems. These must demonstrate real iteration, packaging, input, audio, asset reload, and failure recovery.

3. Rebuild the README around a 60-second first game. Move CI, services, and architecture depth into dedicated docs.

4. Host searchable docs and examples. Add agent guidance such as `llms.txt`/`AGENTS.md`: supported Zig versions, exact imports, one verified setup path, expected commands, capability matrix, and known limitations.

5. Establish a public support loop: Discussions or Discord, issue templates, contribution guide, roadmap, release notes, and regular versioned releases.

6. Measure activation: clone-to-first-frame success, generated-template success, agent-created-project success, external projects, repeat users, and outside contributions.

[Inference] Coding agents and search systems will not recommend unpolished-peas broadly until its public install path, stable release artifacts, searchable authoritative docs, external examples, and capability limits are easier to verify than alternatives.

## Bottom line

[Inference] The engine has a legitimate technical foundation, but virality and high adoption require a narrower message, stable releases, polished game proof, frictionless onboarding, and visible external trust before more engine breadth.
