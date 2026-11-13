# Game protocol

Call reference: [GameContext and GameProtocol](../api/lifecycle.md), including
capability defaults, cleanup, errors and a compiled portable game.

`up.core.GameProtocol(Game)` is the backend-neutral lifecycle. It borrows a game
value and never allocates or moves that value. Hosts create
`up.core.GameContext`, call `init` once, call `update` for each simulated step,
and call `draw` once for each presented frame. At teardown, the protocol calls
an optional game-owned `deinit` callback once while host capabilities remain
available. A cleanup error retains its original cause and `deinit` phase;
the lifecycle still ends, preventing a second cleanup or further updates
against released resources. A new lifecycle requires successful `init`.

```zig
const Game = struct {
    pub fn init(self: *Game, ctx: *up.core.GameContext) !void;
    pub fn update(self: *Game, ctx: *up.core.GameContext, elapsed_seconds: f32) !void;
    pub fn draw(self: *Game, ctx: *up.core.GameContext) !void;
    pub fn deinit(self: *Game, ctx: *up.core.GameContext) !void; // optional
};
```

`GameContext` borrows host capabilities. Normal native, browser and headless
protocol hosts provide the services below; a custom context can omit them.
Use the checked accessors when a capability is required.

| Capability | Use | Ownership and failure |
| --- | --- | --- |
| `input` | Read the fixed-tick snapshot in `update` | Host-owned; normalized/physical keys, pointer, gamepad and text events |
| `requireCanvas()` | Draw logical pixels | Host-owned Canvas; fails when absent |
| `requireAllocator()` | Create game-owned images, fonts, surfaces and layouts | Host-owned allocator; the game releases values it allocates |
| `audio` | Load/play WAV effects and one OGG/WAV music stream | Host-owned resources behind handles; playback can be blocked/unavailable. See [audio](audio-assets.md) and [explicit release](audio-lifetimes.md) |
| `save_data` / `requireSaveData()` | Read/write small game-owned byte blobs | Host owns storage location; absent or failed storage is explicit. See [saves](save-data.md) |

During `update`, the argument `elapsed_seconds` and `ctx.elapsed_seconds` are
the same non-negative finite fixed step; `ctx.interpolation_alpha` is zero.
During `draw`, that alpha is the remaining fixed-step fraction in `[0, 1]`.
Advanced renderer capabilities have their own [backend boundaries](rendering.md#choose-a-rendering-path).

## Everyday shape

For a first program, read the compiled
[tutorial GameProtocol source](../../examples/tutorial_game_protocol.zig), then
read [Seed Sprint](../../templates/starter/src/game.zig). The practical rule is
simple:

- `init` chooses initial state and loads long-lived resources once;
- `update` consumes one normalized fixed-tick input snapshot and changes only
  game state;
- `draw` reads game state and issues Canvas requests;
- `deinit` releases allocator-backed values the game owns.

One presentation frame may execute zero or several fixed `update` calls before
exactly one `draw`. Put movement, collision, score changes, timers, and random
decisions in `update`; do not use presentation frame rate or wall-clock reads
to decide gameplay. `draw` may use `ctx.interpolation_alpha` for visual
interpolation, but it must not advance simulation.

## Ownership and cleanup

The host owns `GameContext` capabilities. A game owns values it creates through
them. The usual Zig pattern is:

```text
init:    allocator = try ctx.requireAllocator(); create/decode once; store values in Game
update:  reuse those values; do not decode or allocate per tick
draw:    borrow them to draw
deinit:  release them in reverse dependency order
```

An `Atlas` owns its sheet Image and releases it itself. Release a separately
owned `Font` or `RenderSurface` when the game exits. For related embedded
images/fonts/sheets, an optional game-owned
[`AssetCollection`](asset-recipes.md) provides stable borrowed resources and
one cleanup call, including a single error cleanup for partial initialization.
If `init` fails, the host does not call game `deinit`; release partially
created resources with `errdefer`, as the collection recipe demonstrates.
Native wrappers must forward an optional game `deinit`; the generated starter
does so. A game with no owned allocation, such
as the first tutorial source, does not need `deinit`. The authored
[image/font guide](image-assets.md) and [RenderSurface guide](render-surfaces.md)
show concrete owned values; Neon Siege is the larger reference.

## Deterministic simulation

Hosts may set `ctx.simulation_seed` before `init`. Store a game-owned
`DeterministicRng` when spawn positions or other initialization need variation.
The useful promise is not that arbitrary code is deterministic; it is that the
same seed, controlled initial save data, fixed-tick replay/input, and
deterministic game code can reproduce a run. Follow the
[testing guide](testing.md) for the end-to-end pattern.

### Reference detail

`DeterministicRng` takes one stable `u64` seed and pins PCG XSH-RR 64/32 v1: it advances zero state, adds the seed, and advances once using the fixed PCG stream increment `1442695040888963407`. The exact `nextU32` sequence is covered by fixed compatibility vectors. `nextU64` joins two consecutive 32-bit values (first high), `uintBelow(upper)` is uniformly distributed in `[0, upper)` and rejects zero, and `float01` produces one of `2^24` `f32` values in `[0, 1)`. This makes integer random values portable across Peas targets; it does not make arbitrary game floating-point computation bit-identical across hardware.

Persistent bytes are environmental input. A reproducible test needs the same
initial save-store contents as well as the same seed and normalized fixed-tick
replay. `HeadlessGameRunner` defaults to an empty in-memory store and can receive
an explicitly preloaded one. Optional session recordings capture selected save keys and restore them
before initialization through `initReplay`. Normalized-only sessions encode
UPR4; sessions containing extended input encode UPR5. See the
[testing guide](testing.md#reproduce-a-session-that-depends-on-saved-progress).
See the
[save-data guide](save-data.md) for key rules, native locations, browser
`localStorage`, and error handling.

Desktop and browser hosts use an accumulator with a five-step catch-up cap. A non-paused frame clamps elapsed wall time to five fixed steps, runs zero to five `update` calls at the fixed step in seconds, then runs exactly one `draw` with the remaining interpolation fraction. Desktop selects the fixed rate through `sdl.Config.fixed_hz` and may supply `sdl.Config.simulation_seed`; the browser rate is 60 Hz. A paused frame runs no updates and draws with zero alpha; its accumulated remainder is retained. Browser visibility changes enter that pause state and reset the timestamp, so time while hidden is discarded rather than replayed on resume.

`sdl.playGame(Game)` dispatches a game with `GameContext` callbacks through this protocol. Legacy `sdl.Context` callbacks remain available for existing games; `sdl.run` remains the explicit-loop escape hatch.

The browser bundle runs the same portable game through its Wasm host.
Renderer selection and the opt-in compositor's WebGL 2 requirement are
explained in [rendering choices](rendering.md#choose-a-rendering-path).
Browser status remains governed by [capabilities](capabilities.md).

`GameProtocol.init` rejects a second initialization. `update` and `draw` reject calls before a successful initialization. If `Game` declares `deinit`, the host calls it once after a successful initialization and before releasing context capabilities. Callback failures preserve their original error and are available through `lastFailure()` with an `init`, `update`, `draw`, or `deinit` phase. Games without `deinit` retain the three-callback protocol.

`up.testSupport.HeadlessGameRunner(Game)` runs the same callback contract with scripted `HeadlessFrame` input, a deterministic core canvas capture, and retained shared render commands for tests.
