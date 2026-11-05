# Framework and value-proposition audit — November 4, 2026

Reviewed checkout: `0bc46bc7` (`1.0.0` package metadata), using Zig `0.15.2`.
This is an assessment and proposed roadmap; it does not implement framework
changes or announce a release. Peer capabilities were checked against primary
documentation on the audit date. Performance figures quoted from Peas guides
are earlier local observations, not new comparative measurements.

## Verdict

**Peas makes a small, portable 2D game substantially easier to build than Zig
plus a hand-assembled platform stack. It already supplies the central
framework value that LÖVE supplies to Lua: write game callbacks while the
framework owns the host. It does not yet deliver the same overall convenience,
breadth, or adoption confidence.**

The strongest current proposition is:

> Write an ordinary Zig 2D game once, run it on desktop and in a browser, and
> reproduce its gameplay and logical drawing in headless tests.

That is useful and supported by real code. The weaker proposition is “a
general-purpose LÖVE/raylib equivalent for Zig.” Installation, general keyboard
and text input, everyday resource ergonomics, and rendering scope still get
in the way. More engine subsystems would not resolve the first three.

| Question | Assessment |
| --- | --- |
| Easier than Zig and OS/graphics/audio APIs directly? | Yes, by a large architectural margin. |
| Easier than Zig with SDL3? | Yes for the combined desktop/browser/testing workflow. The difference is smaller for a single native window drawing a rectangle. |
| Easier than Zig with raylib bindings? | Not established overall. Peas offers an integrated deterministic testing path; its setup and general game APIs currently have more constraints. |
| Same kind of value as Lua → Lua with LÖVE? | Yes: it supplies the game host and reusable game services missing from the language. |
| Same level of accessible, broadly useful experience? | Not yet. An untouched generated project currently fails to build. |

“Large” here describes responsibilities removed, not a measured productivity
multiplier. No controlled developer study or equivalent-game peer benchmark
was performed.

## What this repository is

Peas is a code-first, small-game framework with a deliberate emphasis on
repeatability. It is more than SDL bindings:

| Layer | What Peas provides | Repository evidence |
| --- | --- | --- |
| Game lifecycle | `init`, fixed-step `update`, presentation `draw`, optional `deinit`, failure phase reporting | [GameProtocol and GameContext](../../src/app.zig), [protocol guide](../guides/game-protocol.md) |
| Platform hosts | Native SDL3 GPU presentation, optional OpenGL presenter, browser Wasm/JavaScript runtime with WebGL2/WebGPU | [native host](../../src/backend/sdl_gpu.zig), [browser runtime](../../src/browser/runtime.zig), [platform status](../guides/platforms.md) |
| Everyday services | Canvas, images/fonts/atlases, sprite animation, camera transforms, normalized input/actions, WAV effects, streamed music, small save blobs | [public facade](../../src/api.zig), [learning path](../index.md) |
| Testing | Explicit seeds, input replay, headless game runner, logical Canvas traces, pixel assertions | [test support](../../src/test_support.zig), [testing guide](../guides/testing.md) |
| Development and shipping | Starter generator, project CLI, packaging scripts, browser watch/build/refresh, opt-in native image/font reload and diagnostics | [CLI](../../src/peas.zig), [starter](../../templates/starter/build.zig), [browser development](../guides/browser-development.md) |

The root facade has six namespaces: `core`, `input`, `graphics`, `assets`,
`preview`, and `testSupport`. Game state remains ordinary Zig. Seed Sprint is
the introductory game; Neon Siege and Lantern Leap demonstrate two genres
using the public package boundary. The latter retains level layout, collision,
checkpoints, and animation selection in game code. See the
[authoring baseline](../guides/authoring-experience-freeze.md) and both
[friction](../../dogfood/neon-siege/FRICTION.md)
[logs](../../dogfood/lantern-leap/FRICTION.md).

The default `Canvas` rasterizes into CPU pixels; normal protocol hosts upload
that frame for presentation. `Renderer2D` is a separate advanced queue for
material sprites, particles, and post passes. GPU backends existing does not
make ordinary Canvas drawing GPU-rasterized. That distinction matters when
positioning the framework. See [rendering](../guides/rendering.md) and
[advanced 2D](../guides/advanced-2d.md).

## The benchmark: raw Lua versus Lua with LÖVE

“Raw Lua” means the Lua language and its standard libraries, without a game
host or third-party graphics bindings. It can implement game rules, but its
standard library does not provide a graphical window, game input, sprite
renderer, or audio device. Those responsibilities require a host or external
libraries. This follows the scope of the
[Lua reference manual](https://www.lua.org/manual/5.4/manual.html#6).

For example, this is a complete piece of raw Lua simulation:

```lua
local player = {x = 40}

local function advance(direction, dt)
    player.x = player.x + direction * 48 * dt
end

advance(1, 1 / 60)
print(player.x)
```

It has no window or live keyboard input. Calling hypothetical functions such
as `createWindow` in a “raw Lua” comparison would just conceal the framework
someone still has to supply.

With LÖVE installed, a small graphical counterpart fits in `main.lua`:

```lua
local x = 40

function love.load()
    love.window.setMode(320, 180)
end

function love.update(dt)
    local direction = 0
    if love.keyboard.isDown("left") then direction = direction - 1 end
    if love.keyboard.isDown("right") then direction = direction + 1 end
    x = x + direction * 48 * dt
end

function love.draw()
    love.graphics.setColor(0.3, 0.8, 0.5)
    love.graphics.rectangle("fill", x, 80, 8, 8)
end
```

LÖVE supplies the loop and calls the gameplay callbacks. Running a directory
containing `main.lua` is the normal model; it can also load a `.love` archive.
See the [callback API](https://www.love2d.org/wiki/love) and
[distribution guide](https://www.love2d.org/wiki/Game_Distribution).
This illustrative Lua example was not executed during this audit.

| Developer task | Raw Lua | Lua with LÖVE | Peas equivalent |
| --- | --- | --- | --- |
| Open a game window and keep it responsive | Supply a graphical host/bindings and loop | Framework host and callbacks | `sdl.playGame(Game)` |
| Move using live input | Integrate platform input | Keyboard/mouse/controller APIs | Fixed-tick `Input` and `ActionMap`, with a narrower keyboard vocabulary |
| Show an image | Integrate decoder and rendering | Create an image and draw it | Decode embedded bytes, own the Image, draw on Canvas |
| Play audio | Integrate decoder, mixer/output and lifetime | Source creation/playback | Host-owned SFX/music handles through `ctx.audio` |
| Draw offscreen | Supply renderer resources | Canvas API | CPU `RenderSurface`; different performance and composition scope |
| Persist progress | Choose paths and storage conventions | Framework filesystem | Native/browser `SaveStore`; game chooses byte format |
| Reproduce a gameplay regression | Build a harness and input/time control | Add a game-specific harness or supporting tools | Integrated seed, replay and headless runner |
| Define game rules | Write Lua | Still write Lua | Still write Zig |

The LÖVE proposition is therefore about replacing platform integration and
making common tasks direct. Its own
[image and audio examples](https://www.love2d.org/) show how short those tasks
can be; its [graphics API](https://www.love2d.org/wiki/love.graphics) also
offers fonts, shaders, sprite batches, particles, and other reusable drawing
resources.

Some convenience belongs to Lua itself: dynamic values and automatic memory
management reduce the amount of ownership/type code an example needs. Peas
cannot erase that language difference. It can still reduce repeated resource
plumbing while retaining explicit Zig ownership.

Also, the default LÖVE update receives elapsed frame time; Peas explicitly
owns a fixed-step simulation boundary. A fixed timestep, portable seeded RNG,
input recording, and replay assertions require additional design in a normal
LÖVE game. This is a credible Peas differentiator, not evidence that LÖVE
cannot support deterministic games. See
[love.update](https://love2d.org/wiki/love.update).

## Does Peas remove enough work from Zig?

The repository already has a [35-line compiled tutorial](../../examples/tutorial_game_protocol.zig)
that opens a window, moves a rectangle from normalized keyboard input, and
draws instructions. Its game author writes three callbacks and calls
`sdl.playGame(Game)`. The important part is:

```zig
pub fn update(self: *Game, ctx: *up.core.GameContext, dt: f32) !void {
    if (ctx.input.isDown(.left)) self.player_x -= 48 * dt;
    if (ctx.input.isDown(.right)) self.player_x += 48 * dt;
}

pub fn draw(self: *Game, ctx: *up.core.GameContext) !void {
    const canvas = try ctx.requireCanvas();
    canvas.clear(up.core.Color.rgb(14, 18, 24));
    canvas.fillRect(@intFromFloat(self.player_x), 42, 8, 8,
        up.core.Color.rgb(255, 198, 74));
}
```

This is an excerpt, not an independent complete program. The linked tutorial
contains the imports, configuration, initialization and entry point and was
compiled as part of this audit.

| Baseline | Work the developer still integrates | What Peas adds |
| --- | --- | --- |
| Zig standard library alone | Window/display, platform events, graphics, asset decoding, audio and distribution | Nearly the whole graphical game host |
| Zig with SDL3 | SDL already supplies substantial window/input/audio/GPU infrastructure. The game still integrates a game loop, render strategy, content decoding, resource policy, persistence and tests; a browser path needs a suitable deployment/host strategy. | One coherent game protocol, chosen rendering/content paths, native/browser services, headless replay and packaging conventions |
| Zig with raylib bindings | raylib already supplies many game-facing drawing/input/audio functions. The application still chooses its game architecture and regression-testing approach. | Most plausibly the portable protocol, fixed-input/replay contract and integrated headless tests; a convenience advantage for ordinary drawing is unproven |

Using SDL's basic 2D renderer can make a tiny native Zig program quite short.
It would be misleading to compare every Peas game only with hand-writing a
Vulkan backend. Peas's strongest savings appear when a game needs several
services, a second host, and reproducible tests together.

Conversely, Peas still asks the game author to manage allocators, resource
lifetimes, optional capabilities, recoverable output errors, and conversions
between simulation coordinates and pixels. Those are reasonable Zig choices,
but the current image/font/atlas setup is appreciably more involved than the
simple LÖVE asset examples. The
[authored-assets guide](../guides/image-assets.md) and
[Neon Siege initialization](../../dogfood/neon-siege/src/game.zig) make the
remaining cost visible.

## Comparison with the three peers

This compares documented capabilities and authoring models. It is not a speed
ranking, and peer features do not automatically become requirements for Peas.

| Area | Peas | raylib | Ebitengine | LÖVE |
| --- | --- | --- | --- | --- |
| Main authoring model | Zig game struct and lifecycle callbacks | Direct library calls and an application-owned loop | Go `Update` / `Draw` / `Layout` and `RunGame` | Lua callbacks in a game directory |
| Ordinary drawing | CPU logical Canvas plus presentation | Texture/shape drawing, render textures, shaders | Images as drawing sources and destinations; GPU batching | Images, Canvas, shaders and sprite batches |
| Simulation timing | Framework fixed step, tick snapshots, replay tools | Application chooses timing strategy | Fixed updates, 60 ticks/s by default | Elapsed-time callback by default; game can add fixed stepping |
| Input | Ten normalized keyboard controls, pointer, four gamepads | General key/character input, mouse/gamepad/touch functions | Keyboard, mouse, gamepad and platform-dependent touch | Keyboard/controller/touch and UTF-8 text events |
| Asset authoring | Portable embedded decode; separate native runtime-file workflow | Direct file/resource loading APIs | Image resources plus Go asset conventions | Direct file/resource creation APIs |
| Offscreen rendering | CPU RenderSurface; no general GPU target in that API | Render textures | An Image can be a drawing destination | Canvas offscreen rendering |
| Custom effects | Multiple shader dialects/artifacts and staged materials | Shader APIs | Portable Kage shader source | Shader API |
| Regression workflow | Integrated seed/replay/headless/trace/pixels | Application adds an equivalent workflow | Application adds an equivalent workflow | Application adds an equivalent workflow |
| Target scope | Desktop; browser available under preview contract; no mobile host offered | Multiple desktop/web/mobile targets | Desktop, web, Android/iOS | Windows/macOS/Linux, Android/iOS; official downloads do not offer the same Peas Wasm workflow |

raylib evidence: [official API reference card](https://www.raylib.com/cheatsheet/raylib_cheatsheet_v6.0.pdf)
and [project overview and learning model](https://www.raylib.com/).
Ebitengine evidence: [game lifecycle](https://ebitengine.org/en/documents/cheatsheet.html),
[automatic batching/atlas guidance](https://ebitengine.org/en/documents/performancetips.html),
[platform features](https://ebitengine.org/en/documents/features.html), and
[Kage shaders](https://ebitengine.org/en/documents/shader.html).
LÖVE evidence: [graphics](https://www.love2d.org/wiki/love.graphics),
[offscreen Canvas](https://love2d.org/wiki/love.graphics.newCanvas),
[text input](https://www.love2d.org/wiki/love.textinput), and
[official platform downloads](https://www.love2d.org/).

Ebitengine is a particularly relevant architectural comparison: it also uses
ordinary application structs, separates fixed logical updates from drawing,
and avoids requiring an editor. A fixed-step callback API alone is therefore
not unique. Peas's distinction is the explicit replay/headless/Canvas testing
workflow around that model. See Ebitengine's
[introductory example](https://ebitengine.org/en/tour/hello_world.html).

## Main gaps, in priority order

### 1. P0: a working independent-project path

**Confirmed first-run failure.** `zig build peas -Dwith_sdl=false -- new
<temporary-directory>/game` succeeds. Running `zig build` in that untouched
project exits unsuccessfully with:

```text
no dependency named 'unpolished_peas' in '.../game/build.zig.zon'
```

The [template manifest](../../templates/starter/build.zig.zon) has empty
dependencies, while [its build script](../../templates/starter/build.zig)
immediately requests `unpolished_peas`. The
[generator](../../src/starter.zig) copies those files without filling the
coordinate. Its existing test verifies structure and a project check; that
does not prove the untouched output can actually build.

This is documented as a source-checkout template, but an available `new`
command that emits an unbuildable project still breaks the expected workflow.
The advertised checkout-only evaluation path does work independently of this
failure.

The public [latest-release API](https://api.github.com/repos/gongahkia/unpolished-peas/releases/latest)
was also checked: `1.0.0` has an empty attached-assets list. GitHub supplies
automatic source archives, but the prepared package/starter coordinates
described by the [installation guide](../guides/installation.md) are absent.

**Recommendation:** make generation produce a complete project in both
documented modes: an explicit local dependency for source-checkout development,
and pinned, verified coordinates for release consumers. Run the untouched
output's `build`, `test`, and `web` from outside the engine checkout in a clean
consumer check. Do not require users to learn the release-preparation scripts
before writing their first game.

### 2. P0: project licensing is unresolved

The repository has third-party notices but no top-level code license, and the
[authoring baseline](../guides/authoring-experience-freeze.md) explicitly says
the license is undecided. This prevents a clear adoption proposition even if
the code is technically capable.

**Recommendation:** the owner selects and records the project license and
includes it in distributed packages. Third-party notices and a project code
license serve different purposes. This audit does not choose one.

### 3. P1: general keyboard and text input

[Key](../../src/input.zig) exposes only `up`, `down`, `left`, `right`,
`action`, `cancel`, `start`, `select`, `debug`, and `screenshot`. Named
`ActionMap` bindings cannot recover physical keys the host never exposes.
There is no ordinary way to bind distinct letter/number keys, implement a
general rebinding screen, or enter a player name through the portable input
contract. The [input guide](../guides/input.md) explicitly excludes text input.

**Recommendation:** retain the useful defaults, add general physical-key
identities and UTF-8 text/composition events, and document their deterministic
capture boundaries. Expand the native host, browser contract, replay format,
and tests coherently; this needs an explicit compatibility plan. A normalized
touch-ID API is a separate requirement if multi-touch/mobile games become a
target; browser pointer handling alone is not that API.

**Acceptance:** a game can bind distinct `Q`, `E`, `1`, and `2` controls,
rebind them, and enter a Unicode name on desktop and browser without importing
SDL or writing DOM handlers. LÖVE already supplies
[UTF-8 text events](https://www.love2d.org/wiki/love.textinput).

### 4. P1: one obvious everyday API, especially for assets

The README demonstrates older `sdl.Context` callbacks and native file-loading
helpers. The compiled quickstart recommends portable `GameContext` callbacks
and embedded decoding. Both styles exist, but a newcomer has to distinguish
native convenience from the recommended portable contract. Atlas animation
also has a legacy supported path alongside the recommended tick-based path.

For embedded art, the portable workflow can require a package-root asset
module, build imports, an allocator request, Image/Font ownership, an Atlas,
frame handles, and cleanup. The complexity has reasons; the amount required
for “draw this PNG” weakens the LÖVE comparison. See
[images/fonts](../guides/image-assets.md),
[animation](../guides/sprite-animation.md), and the
[compatibility inventory](../guides/authoring-experience-freeze.md).

**Recommendation:** make the first examples use the same portable model. Add
small compiled recipes for image, font, sound, animation and save tasks.
Consider an optional, explicitly owned game asset collection that releases
resources together and accepts embedded bytes. Preserve the lower-level owned
values for games needing precise lifetimes. The goal is fewer repeated steps,
not implicit global state or a second game framework.

API discovery also needs work: [the docs generator](../../src/docs.zig)
currently reads the root facade and emits six namespace names, rather than
documenting the nested methods an author needs. A task-oriented reference
with signatures, ownership rules and working examples would be more useful
than namespace stability alone.

### 5. P1 for broad 2D positioning: a coherent drawing/performance story

The CPU Canvas is a strong fit for small logical resolutions and exact
headless pixel tests. It is a constraint for larger-resolution blending,
offscreen composition and many effects. `RenderSurface` cannot be passed as
a general GPU material texture/target, and advanced draws have a staged order
instead of arbitrary interleaving with ordinary Canvas draws.

The [rendering guide](../guides/rendering.md) records earlier Intel Mac
measurements of 23–29 ms for linear composition from 320×180 to 1280×720.
That single operation exceeds a 60 Hz frame's roughly 16.7 ms budget on that
machine. Nearest scaling and low-resolution drawing have much better recorded
results. These figures do **not** establish that Peas is slower than any peer;
the workloads, machines and execution paths have not been matched.

**Recommendation:** choose the product promise before redesigning rendering.
For a low-resolution deterministic framework, state the intended workloads
prominently and retain the CPU reference. For a broad LÖVE/Ebitengine-style
framework, provide a direct, batched GPU image/primitive/offscreen path with
clear ordering and a testable logical contract. Requiring custom materials
for ordinary accelerated sprite drawing would add unnecessary authoring cost.

The shader authoring path is another burden: executable materials require
vertex/fragment artifacts for three native formats plus GLSL ES and WGSL,
with platform-specific compilation/assembly. A portable source workflow or
well-supported built-in effect recipes would reduce this cost. Ebitengine's
[Kage model](https://ebitengine.org/en/documents/shader.html) demonstrates the
kind of shader portability work a framework can absorb for the author.

### 6. P1/P2: stronger evidence for the portability promise

The repository has substantial capability, package and browser test machinery.
Nevertheless, [the contract](../guides/capabilities.md) still classifies
browser renderers as preview, and [platform status](../guides/platforms.md)
records missing Apple Silicon and bare-metal Linux interactive evidence.
Windows has automated coverage but no local interactive validation recorded
there. The absence of recorded manual evidence is not proof those hosts fail.

**Recommendation:** close and publish the remaining runtime checks, including
audio/controller behavior and actual downstream packages, then promote browser
support when its contract warrants it. Keep build success, automated rendering
coverage and manual hardware checks distinct. Mobile is a real breadth gap
against Ebitengine/LÖVE, but should remain a deliberate later product decision
if desktop/browser is the chosen market.

### 7. P2: text, content lifetime and audio beyond tiny games

Authored TTF/OTF and UTF-8 decoding already exist; “no fonts” would be an
incorrect finding. Missing shaping/fallback and dynamic glyph streaming still
limit localized or text-heavy games. The generic
[text layout helper](../../src/text_layout.zig) uses fixed debug-font advances,
so it is not a general layout engine for the authored proportional fonts.

The portable asset path embeds content; native runtime files are a separate
workflow, and `AssetStore` is not an asynchronous browser fetch API. The
high-level audio service retains resources until host teardown and supports
one active music stream. Its advanced mixer has more controls, so this is
primarily a gap in the ordinary portable authoring path, not absence of audio
mixing. See [assets](../guides/image-assets.md) and
[audio limits](../guides/audio-assets.md).

**Recommendation:** use a larger representative game to establish which of
scene-scoped resource release, bounded asynchronous loading, better authored
font layout, or multi-track audio actually blocks shipping. Add the smallest
reusable facility that resolves that case.

## What should not become a feature checklist

An ECS, editor, scene graph, physics engine, networking stack, tilemap importer,
and camera controller are not all prerequisites for the desired value.
Code-first frameworks can already be valuable without them. LÖVE does include
[Box2D-backed physics](https://love2d.org/wiki/love.physics), so that is a real
relative capability for physics-heavy games, not a reason to make it the first
Peas priority.

Peas already has basic vector/rectangle helpers, camera transforms, sprite
animation, music, saves, materials and particles. Calling those missing would
ignore the current implementation. Conversely, two deliberately small dogfood
games not needing a subsystem does not establish general-purpose parity.
Their limited keyboard needs and low resolutions leave important gaps
untested. This qualifies the earlier
[product audit's scope assessment](2026-10-23-product-engineering-audit.md).

The ecosystem gap is chiefly reuse and confidence: readily discoverable
recipes, external consumers, supported extension points, and evidence from
games outside the framework's own reference set. Building many internal
validation tools is valuable but does not by itself shorten an author's first
image, first control binding, or first independent build.

## Recommended sequence and proof of value

1. **Make adoption work:** resolve licensing, repair both local and released
   project-generation paths, and validate an untouched independent project.
2. **Make ordinary tasks direct:** unify introductory examples, improve API
   discovery, add general keys/text, and reduce common asset setup.
3. **Prove the current promise:** collect the remaining target/runtime evidence
   and document desktop/browser support without implying more than is tested.
4. **Choose rendering ambition:** retain an explicit low-resolution niche or
   invest in general GPU drawing/offscreen resources with a CPU test reference.
5. **Expand from a real blocker:** use a larger external game to select content,
   typography, audio, mobile or genre helpers. Preserve ordinary Zig game state.

To determine whether the value reaches the desired level, use the same small
game specification across **Peas**, **Zig with SDL3**, and **Zig with pinned
raylib bindings**. A Lua/LÖVE implementation supplies an ergonomic reference;
raw Lua alone cannot fulfill the graphical specification, so an equivalent
lower-level Lua implementation must name its chosen host/bindings.

The task should include movement, an authored sprite/font, overlapping SFX,
background music, a saved high score, a rebindable action, text entry, a desktop
package, a browser package where offered, and a scripted regression. Count
unmet requirements explicitly rather than silently dropping them for one
implementation.

Record these separately:

- Setup steps and blockers before the first independent build.
- Gameplay code, build/configuration code, host-specific code and test code.
- Resource allocations/cleanup and platform conditionals the game author owns.
- Warm edit/build/relaunch time, hardware, toolchain, and cache state.
- Time and complexity needed to reproduce the same gameplay regression.
- Equivalent rendering workload and CPU/GPU timing methodology before making
  throughput claims; browser submission time is not GPU completion time.

Proposed acceptance goals, **not measured results**: a documented untouched
project builds without hand-repair; an author completes image/sound/save tasks
from short compiled recipes; key binding and text entry need no host escape;
the same game rules run on desktop/browser and in a headless regression test.
Have developers unfamiliar with the repository attempt the workflow and
record where they stop.

Peas already passes the architectural test of removing substantial integration
work. It needs to pass that end-to-end authoring test before claiming the same
overall value as LÖVE or a clear convenience advantage over Zig with raylib.

## Validation and limits of this audit

Executed locally on the audit checkout:

```sh
zig build test test-starter-template test-dogfood test-lantern-leap \
  test-core-api browser-starter -Dwith_sdl=false --summary all
```

Result: **42/42 build steps succeeded; 234/234 tests passed**, including the
starter and both reference games. The browser starter Wasm compiled. This
does not establish interactive native/browser behavior on every target.

The generator reproduction used a temporary directory outside the repository,
then ran `zig build` inside the untouched generated game. Generation succeeded;
the game build failed on the missing dependency described above. The temporary
project was removed afterwards. This was an intentional user-path probe, not
a failure of the preceding headless suite.

Additional validation:

- `zig build check-examples --summary all`: **38/38 steps succeeded**, including
  the native tutorial, starter, reference games, and explicit-loop Wasm example.
- `zig build docs test-docs -Dwith_sdl=false --summary all`: **6/6 steps
  succeeded; 8/8 tests passed**. The missing-link message printed by this suite
  belongs to its intentional broken-link fixture; documentation generation and
  repository link validation succeeded.
- `git diff --check`: passed.

No peer implementation was built or timed, and no fresh cross-platform
interactive hardware matrix was run. The comparisons distinguish inspected
capabilities, reproduced local behavior, earlier recorded measurements, and
proposed acceptance goals. Changes for this audit are the document and its
learning-path link.
