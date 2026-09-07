# PX-240C Cohesive Alpha Implementation Brief

## Objective

Build a cohesive, genuinely usable alpha of **PX-240C**, a fictional fantasy console presented as a commercially released but unsuccessful 1999 colour handheld. It must run as a static browser application and locally on Linux, provide its own statically typed game-oriented language and compiler, include the expected integrated fantasy-console creation tools, and ship with three polished microgames written in that language.

This is both a real creative tool that experienced developers and size-coding/demo-scene users could enjoy and a serious compiler/runtime/systems-engineering project. Do not reduce it to a themed JavaScript game engine, a collection of disconnected editor mockups, or a PICO-8 clone with larger limits.

The alpha is complete when a new user can boot the fictional machine, create or open a cartridge, edit code and assets entirely inside the console, compile and run it, debug and rewind it, save/recover it locally, pack it reproducibly, export a standalone HTML player with inspectable source, and play all three bundled cartridges.

## Product identity

- Product/model: **PX-240C Color Development Unit**.
- Do not invent or display a named manufacturer.
- Fiction: a real commercial handheld released in 1999, technically interesting but commercially unsuccessful. Express this lightly through the boot ROM, manuals, model/revision labels, built-in help, cartridge labels and restrained interface copy. Do not bury the tool under lore.
- Credit the project and every bundled cartridge as `Made by @gongahkia` or `Author: @gongahkia`, as appropriate.
- Visual identity: warm industrial cream and charcoal surfaces with restrained coral, cyan and amber accents. The console output itself uses one carefully designed fixed 32-colour master palette with useful ramps and unmistakable character.
- The host webpage should be minimal. The fantasy display is the product, not one panel in a conventional web IDE.
- All creation tools occupy the same 240x144 virtual display used by cartridges. Integer-scale it crisply to the available browser viewport.
- Use an original readable bitmap font throughout the fictional machine.

## Ownership and publication boundaries

- This repository is private and proprietary for now.
- Do not add an open-source `LICENSE` file or claim an open-source licence.
- Add a concise copyright/all-rights-reserved notice and comply with every third-party dependency licence in `THIRD_PARTY_NOTICES.md`.
- Cartridge authors retain ownership of cartridge source and assets. Exported players may redistribute only the runtime material necessary to run their cartridges.
- Never push, publish, deploy, create a remote, or change repository visibility.
- The browser build must nevertheless be a static, offline-capable PWA suitable for eventual GitHub Pages hosting.

## Non-goals for this alpha

- No cloud account, synchronization, hosted backend, public gallery, ratings, social system or network/multiplayer API.
- No packaged desktop GUI. Local development means the browser studio plus a native Linux CLI/toolchain.
- No PICO-8, TIC-80 or other cartridge compatibility/importer.
- No real 3D renderer, user shaders, true-colour escape hatch, arbitrary-alpha compositing, bilinear filtering, DOM access, host filesystem access from cartridges, or raw JavaScript escape.
- No built-in physics engine, ECS, scene graph or collision engine. Provide coherent low-level game primitives and small source-visible helper modules; the bundled games implement their own gameplay systems.
- No fake online services, fake benchmarks, unsupported compatibility claims or decorative controls without working behaviour.

## Recommended implementation architecture

Use a workspace/monorepo with clean package ownership and documented dependency direction.

- **Rust compiled to WebAssembly and to a native Linux CLI**: lexer, indentation-aware parser, source spans, static type checker, typed IR, optimizations that preserve semantics, PXCL-to-JavaScript generation, source maps, debug instrumentation, formatter, deterministic cartridge packer and shared analysis used by the language server.
- **TypeScript**: studio shell, cartridge runtime coordination, sandbox worker, graphics/audio/input adapters, persistence, debugger UI, editors, PWA and standalone exporter.
- **Dedicated Web Worker**: generated cartridge JavaScript executes without DOM access. PXCL has no syntax for reaching worker globals. Remove or shadow network/host capabilities, enforce budgets, and terminate runaway cartridges safely.
- **WebGL2**: maintain an indexed framebuffer and resolve it through the fixed 32-colour palette. Keep the abstraction compatible with a later fallback, but do not implement duplicate renderers unless evidence requires it.
- **Web Audio**: implement the PX-240C synthesizer/tracker rather than playing arbitrary imported audio files.
- A mature browser text-editing component such as CodeMirror 6 is acceptable internally, but it must be styled, clipped and controlled as part of the diegetic 240x144 bitmap interface.
- Prefer reproducible, pinned, actively maintained dependencies. Do not use an existing game engine, scripting language runtime or compiler that substitutes for the core work.

Minor architectural details may change when evidence from implementation demands it. Record meaningful deviations and their reasons in the architecture decision log.

## PXCL/1 language

The bundled language is **PXCL/1 — PX Cartridge Language, Revision 1**. Source files use `.pxl`. Packed cartridges use `.pxc`.

PXCL/1 is a compact, statically typed, indentation-based, ASCII-only language designed specifically for deterministic small games. Its surface syntax should be pleasant for an experienced developer, terse enough for constrained cartridges, and teachable later to beginners.

### Required syntax and semantics

- Newlines terminate statements and indentation defines blocks. No mandatory semicolons or braces.
- Keywords are lowercase; identifiers are case-sensitive; indexing is zero-based.
- `state name: Type = value` declares persistent mutable cartridge state and requires an explicit type.
- `let name = value` declares an immutable local with inferred type.
- `var name = value` declares a mutable local with inferred type.
- Function parameters and return types are explicit: `fn move(pos: Vec2, vel: Vec2) -> Vec2:`.
- System callbacks use `on start:`, `on update:`, `on draw:` and the constrained raster facility. Ordinary reusable logic uses `fn`.
- Provide deterministic `task` routines that can be started explicitly and suspended with frame/time literals such as `wait 2f` and `wait 0.5s`. Lower tasks to inspectable bounded state machines; do not expose host promises or async semantics.
- Provide records/value types, enums, exhaustive `match`, `Option[T]`, fixed arrays, fixed-capacity `List[T, N]`, modules/imports, compile-time constants and assertions.
- Provide non-capturing function references if they materially improve game code. Do not add general closures until their allocation and debugging semantics are coherent.
- Core types include at least `Num`, `Int`, `Bool`, `Text`, `Color`, `Vec2`, `Rect`, controller/button values and typed asset handles. `Num` and `Int` may both use JavaScript numbers at runtime, but integer operations and required integer positions must be statically/debug validated.
- Named asset references use syntax such as `#hero`, participate in type checking, and produce precise missing/wrong-kind diagnostics.
- Ranges are half-open: `0..10` yields 0 through 9.
- No implicit globals, `any`, classes, inheritance, exceptions, reflection, raw host values, raw JavaScript, unrestricted dynamic allocation or observable host garbage collection.
- Errors must be designed, not leaked parser internals: include stable codes, exact spans, helpful messages and relevant secondary spans.
- Embed a language and cartridge-format revision even though long-term evolution is not currently planned.

### Compiler pipeline

Implement and expose a real pipeline:

`source -> tokens -> parsed AST -> name resolution -> typed AST -> typed IR -> lowering/instrumentation -> compact JavaScript + source map`

The studio compiler explorer must display useful forms of tokens, AST, typed representation, IR, generated JavaScript, source map relationships, diagnostics and code/resource-size accounting.

Generate two modes from the same typed IR:

1. **Release mode**: compact JavaScript, source maps, deterministic budget instrumentation and minimal runtime probes.
2. **Debug mode**: semantically equivalent output with source-level probes and suspendable execution sufficient for real breakpoints, conditional breakpoints, stepping, watches, call/task inspection and line-level cost attribution.

Use golden tests, positive/negative type fixtures and cross-mode semantic tests so the debugger does not change cartridge behaviour.

## Determinism and execution budgets

- Cartridge time is derived from update/frame progression, never wall-clock time.
- Supply console-owned deterministic RNG and deterministic math paths for operations where cross-browser host behaviour could otherwise diverge. Do not expose `Date`, `Math.random`, network timing or host events directly.
- Record controller/pointer input, RNG state and task transitions for replay.
- Insert deterministic work-unit checks at function entries, loop back-edges, task transitions, allocations/capacity operations and expensive console API calls.
- Document work units honestly as a synthetic PX-240C execution model. Do not call them real CPU instructions or advertise a fictional MHz value unsupported by the implementation.
- A runaway frame must stop with a source-mapped budget error; it must not freeze the studio.

## Experimental PX-240C hardware profile

Start with the following values as centrally defined experimental alpha constants. Build visible budget meters and measure all three bundled games. Codex may adjust values when evidence shows that a limit is trivial, incoherent or obstructs the intended games. At the end, freeze and document one profile rather than exposing user-configurable hardware presets.

- Display: 240x144 indexed pixels at 60 Hz.
- Optional cartridge update callback rate: 30 or 60 updates per second; rendering remains 60 Hz.
- Fixed master palette: 32 colours. Authors may remap logical colours and raster palette state but may not replace master RGB values.
- Double-buffered indexed framebuffer; framebuffer storage is separate from cartridge visual assets.
- Initial packed cartridge ceiling: 256 KiB, including source and assets required by the cartridge format.
- Initial shared visual asset capacity: 128 KiB for sprite pixels/frames, tiles, maps, fonts and animation data.
- Persistent save capacity: 8 KiB per cartridge.
- Initial draw-command ceiling: 4,096 commands per frame.
- Variable sprites: 1-64 pixels per axis, charged to the shared visual capacity.
- Tiles: 8x8; tilemaps and sprites consume the same visual capacity.
- Transparency: one transparent colour index. No arbitrary alpha.
- Sprite scaling/rotation: deterministic nearest-neighbour affine operations with explicit work/draw costs.
- Inputs: keyboard, mouse/pointer, touch and standard gamepads. Model four local controller ports, each with D-pad, four face buttons, two shoulders and Start/Menu.
- Audio: eight simultaneous synthesizer voices and an eight-channel tracker. Include pulse, triangle, saw, noise and small editable wavetable sources, plus volume envelope, pitch effects and pan. Do not support arbitrary sample imports in the alpha.

### Graphics API

Provide a small coherent immediate-mode API around:

- indexed pixels and framebuffer clearing;
- lines, rectangles, circles and triangles;
- named variable-sized sprites and animation frames;
- tilemaps, tile flags and bounded map queries;
- camera and clipping state;
- nearest-neighbour sprite flipping, scaling and rotation;
- palette remapping;
- a constrained per-scanline/raster display list capable of scroll offsets and palette changes;
- deterministic ordered-dithering helpers.

Keep API naming compact and consistent. The pseudo-3D racer must use scanline/raster projection and ordinary 2D operations, not hidden 3D support.

## Cartridge and project model

Support two complementary representations:

1. A Git-friendly project directory with `cart.toml`, `.pxl` modules and ordinary, documented asset files.
2. A single deterministic `.pxc` sharing artifact.

The packed cartridge contains a canonical manifest, all original PXCL source modules, packed graphics/maps/audio, compiled release JavaScript, source map, cartridge label/thumbnail, language and format versions and integrity hashes. Define stable ordering, normalized timestamps/paths/line endings and deterministic compression so identical project inputs produce byte-identical `.pxc` files.

All cartridge source is always inspectable. The integrated player, `.pxc` inspector and standalone HTML export must offer a visible source/metadata inspection path. Do not imply that minified generated JavaScript satisfies this requirement.

The standalone HTML exporter embeds the runtime and cartridge, runs offline and preserves the PX-240C presentation. It must not require a CDN or backend.

## Native CLI and external-editor workflow

Provide a native Linux CLI with a coherent command family such as:

- `px240c new`
- `px240c check`
- `px240c fmt`
- `px240c build`
- `px240c run`
- `px240c watch`
- `px240c pack`
- `px240c export html`
- `px240c info`
- `px240c lsp`

Reuse the same Rust compiler/packer used in the browser. Include formatter check mode and a usable stdio language server with diagnostics, completion, hover, go-to-definition, references and rename for implemented PXCL constructs. Document generic Neovim and VS Code/editor-client setup; a polished custom extension is not required for the alpha unless inexpensive.

## Diegetic integrated studio

Boot first into a monitor shell rather than a graphical launcher. A restrained initial screen may read approximately:

```text
PX-240C COLOR DEVELOPMENT UNIT
SYSTEM ROM 1.0  (C) 1999
128K VISUAL STORE / 8V SOUND
PXCL/1 READY

>
```

Useful shell commands include `dir`, `new`, `load`, `save`, `run`, `edit`, `pack`, `export`, `info`, `help` and `reboot`. The boot sequence, shell and every tool use the fixed display, palette and bitmap font.

Implement every tool below as a functional alpha surface, with undo/redo and sensible keyboard/mouse navigation where applicable:

- cartridge browser/project settings;
- code editor with PXCL syntax highlighting, live diagnostics, completion, symbol navigation, formatting and external-change-safe reload behaviour;
- variable-size sprite/animation editor with palette selection, selection tools, transforms, onion skinning and asset-capacity feedback;
- layered tile-map editor with tile flags, camera/navigation tools and shared-capacity feedback;
- palette-bank/remapping and raster-state editor that cannot modify the fixed master palette;
- sound-effect editor for oscillator, envelope, pitch/pan and preview;
- eight-channel pattern/order-list music tracker with playback and looping controls;
- searchable built-in PXCL/API/manual browser;
- compiler explorer;
- debugger, profiler, state/task viewer, visual-memory view, framebuffer/palette inspector and audio/channel inspector;
- build/pack/export/status views.

The implementation may use accessible DOM controls internally, but the rendered result must remain a cohesive low-resolution console UI, not conventional host chrome around a canvas. Preserve text-input correctness, focus visibility and keyboard operability.

## Persistence and recovery

- Store projects, settings and cartridge save blocks locally in browser storage such as IndexedDB.
- Autosave safely, maintain bounded recovery snapshots and surface recovery after an interrupted/failed edit.
- Provide explicit project and `.pxc` import/export paths.
- Never require login, cloud storage or synchronization.
- Prevent a cartridge from reading another cartridge's save block or studio project data.

## Debugger and profiler

Time-travel and conventional source debugging are equally important. Implement a coherent, tested alpha of both:

- pause/resume/restart and frame advance;
- source breakpoints and conditional breakpoints;
- step into, over and out;
- call stack, locals, globals, records, fixed collections and deterministic task state;
- watch expressions within a deliberately safe PXCL subset;
- source-mapped runtime and budget errors;
- periodic serializable frame snapshots;
- input/RNG/task event recording and deterministic rewind/replay;
- a frame timeline and divergence detection rather than silently incorrect replay;
- per-function and per-line synthetic work-unit attribution;
- draw-command, visual-capacity, cartridge-size and audio-voice meters;
- framebuffer, sprite/map store, palette/raster and audio-channel inspection.

Prefer a smaller set of reliable debug semantics over pretend controls. Document intentional limitations precisely.

## Three bundled PXCL/1 cartridges

Create three visually distinct polished microgames, all credited to `@gongahkia`. They need not share a fictional universe. Each should offer roughly 3-10 minutes of meaningful play, coherent original pixel art and audio, a title/instruction screen, restart flow and real win/lose or scoring conditions. Do not use placeholder presentation.

1. **Platformer**: demonstrate responsive movement, collision, tilemaps, animation, tasks, camera, controller input and SFX. Include optional two-player functionality if it improves the design, but prioritize one-player feel.
2. **Roguelike**: demonstrate bitmap text, deterministic procedural generation, map visibility, records/enums, fixed-capacity collections, save storage and rich debugger state. Keep scope compact but meaningfully replayable.
3. **Pseudo-3D racer**: use 2D scanline/road-projection mathematics, raster palette/scroll effects, sprite scaling and synth music. Single-player is the primary polished mode; also implement simultaneous 2-4-player split-screen so all four controller ports and budget behavior are genuinely exercised.

Use the games as conformance and calibration artifacts. They must compile only through public PXCL/PX-240C facilities; do not add private runtime shortcuts for them.

## Documentation deliverables

Write documentation as part of the implementation, keeping claims tied to actual working behavior:

- `README.md`: identity, screenshots/GIF instructions, quick start, current alpha status and explicit non-goals.
- `docs/PRODUCT.md`: product principles, audience, fictional framing and differentiation from existing fantasy consoles without disparagement.
- `docs/HARDWARE.md`: frozen alpha machine profile and honest work-unit model.
- `docs/PXCL.md`: complete implemented PXCL/1 language reference with grammar/semantics and examples.
- `docs/API.md`: complete public cartridge API.
- `docs/CARTRIDGE_FORMAT.md`: authoring tree, deterministic `.pxc` representation and versioning.
- `docs/ARCHITECTURE.md`: packages, trust boundaries, compiler/runtime flow and ADR links.
- `docs/STUDIO.md`: integrated and external workflows.
- `docs/DEBUGGER.md`: debug compilation, stepping, snapshots, replay and limitations.
- `docs/TUTORIAL.md`: build a small playable cartridge from scratch.
- `docs/LIMITS.md`: measured calibration evidence from the three cartridges.
- `docs/SECURITY.md`: practical sandbox boundaries without overclaiming isolation.
- `THIRD_PARTY_NOTICES.md`: dependencies/assets/fonts and their licences.
- `docs/PROGRESS.md`: concise milestone log, decisions, verification and remaining risks.

Include an EBNF or similarly precise grammar, but treat the compiler and tests as authoritative when documentation disagrees.

## Engineering and validation requirements

- Start by inspecting the empty directory and available toolchains, then write a short execution plan and initial ADRs before major implementation.
- Initialize Git if needed. Commit each coherent verified milestone locally. Never push or rewrite history.
- Keep the worktree clean at milestone boundaries and at final handoff.
- Install project dependencies and reasonable missing system packages when possible.
- Maintain strict formatting, linting and type checks for Rust and TypeScript.
- Test the compiler with lexer/parser fixtures, indentation edge cases, positive and negative type suites, error-span snapshots, IR/codegen goldens, task lowering, asset typing, budget instrumentation and source maps.
- Add property/fuzz tests for parser, packer and cartridge decoding where practical and bounded.
- Prove debug/release semantic equivalence over representative fixtures.
- Prove deterministic replay and explicit divergence detection.
- Prove deterministic `.pxc` output by rebuilding and byte-comparing.
- Test sandbox capability denial, runaway-loop termination and cross-cartridge storage isolation.
- Add rendering/palette/raster/audio state tests that do not depend entirely on fragile screenshots; supplement with selected visual goldens.
- Add browser end-to-end tests for boot, shell, create/edit/run, each major editor, autosave/recovery, debugging, packing, import and standalone export.
- Build and smoke-test every bundled cartridge through the public toolchain.
- Measure bundle size, cartridge sizes and representative frame costs. Report numbers; do not invent performance claims.
- Run the full relevant test/lint/build suite before every milestone commit and the complete suite at the end.
- Visually inspect the running studio and all three games at multiple integer scales. Fix clipping, unreadable text, non-pixel-aligned rendering, broken focus and obvious placeholder UI.

Choose minor unconfirmed details autonomously when they preserve the locked identity and constraints. Use targeted web research where it materially improves language, fantasy-console or accessibility decisions, but do not copy proprietary code, palettes, fonts, games or art. Record externally derived ideas and licences when used.

## Suggested milestone sequence

The sequence may change for dependency reasons, but keep each milestone vertically verifiable and locally committed:

1. Repository/toolchain foundation, product brief, ADRs and quality gates.
2. PXCL lexer/parser/spans/formatter and language fixtures.
3. Type system, assets, typed IR and diagnostics.
4. JavaScript code generation, deterministic runtime, task lowering, budgets and worker sandbox.
5. Indexed graphics, input, raster display list, audio synthesizer/tracker core and calibrated machine constants.
6. Project model, deterministic `.pxc`, browser persistence/recovery, native CLI, watch mode and LSP.
7. Boot ROM, shell and cohesive diegetic studio foundation.
8. Functional code, sprite, map, palette/raster, SFX and music editors.
9. Release/debug dual generation, breakpoints/stepping, profiler, state inspectors and rewind/replay.
10. Platformer cartridge and related quality fixes.
11. Roguelike cartridge and related quality fixes.
12. Four-player pseudo-3D racer and final limit calibration.
13. Standalone HTML/PWA export, full documentation, accessibility/visual polish and release-candidate validation.

Commit more often when a milestone is too large. Do not postpone integration until the end.

## Final stopping condition

Stop only when all of the following are true, or when a genuine external blocker requiring user authority is documented:

- The repository is locally committed, clean and unpushed.
- One documented command installs/builds the complete project on Linux.
- The static browser studio boots into the PX-240C shell and works offline after initial load.
- A user can create, edit, compile, run, debug, rewind, save, recover, pack, import and export a cartridge without cloud services.
- All named integrated tools have meaningful working behavior inside the 240x144 diegetic interface.
- The native CLI, formatter, watch flow and language server work against the same compiler semantics.
- Release and debug compilation are tested for semantic equivalence.
- The deterministic sandbox, budgets, cartridge packing and replay guarantees have automated evidence.
- All three original PXCL/1 cartridges are playable, visually distinct, source-inspectable and built solely through public APIs; the racer supports simultaneous 2-4-player split-screen.
- The experimental limits have been evaluated against the cartridges, any adjustments are justified, and one coherent alpha profile is frozen.
- The full documented validation suite passes.
- Documentation describes actual behavior, known limitations and non-goals without unsupported claims.

At completion, provide a concise handoff containing the starting and ending commits, milestone commits, architecture summary, exact verification commands/results, final hardware limits, how to run the studio and games, known limitations, and confirmation that nothing was pushed or deployed.
