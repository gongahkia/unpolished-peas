# Architecture and ownership

72 is a Go runtime SDK. Games own rules, content, and application composition;
the runtime owns portable lifecycle, simulation, and rendering intent. It is
not an editor or a broad production platform distribution.

## Dependency direction

```text
game -> engine, engine/ecs, engine/render
engine -> engine/ecs, engine/render
host -> engine
private renderer -> engine/render, selected graphics binding
host -> private renderer
```

`engine` and `engine/render` are the only engine-facing boundaries for a
future graphics binding. A game must not receive a window, browser canvas, GPU
device, queue, surface, or binding-specific image. A host owns its event loop
and platform resources; the private renderer owns GPU resource and presentation
lifecycle. [ADR 0001](adr/0001-webgpu-renderer-boundary.md) is the normative
renderer boundary.

## Package ownership

| Area | Owns | Change here when |
| --- | --- | --- |
| `engine` | application lifecycle, configuration, camera, layers, normalized input, and host contract | changing portable game-facing runtime behavior |
| `engine/ecs` | entities, component storage, resources, and ordered schedules | changing simulation data or system ordering rules |
| `engine/scene` | ECS-backed transform hierarchy | adding parent/child transform behavior |
| `engine/assets` | typed handles, reload hooks, loading, package manifests, and portable decoders | adding a portable asset format or loading policy |
| `engine/audio` | mixer, buses, voices, and portable audio state | changing backend-neutral playback behavior |
| `engine/audio/oto` | optional local-device output implementation | changing Oto-specific device or PCM conversion behavior |
| `engine/physics` | deterministic AABB 2D bodies, contacts, and queries | changing the documented 2D physics contract |
| `engine/ui` | retained layout, focus, and pointer hit testing | changing UI tree/layout behavior |
| `engine/render` | high-level 2D commands and portable texture sources | changing backend-neutral scene intent |
| `engine/diagnostics` | counters and duration summaries | adding portable observability data |
| `engine/platform` | Linux X11/browser host lifecycle and private renderer integration | changing platform event, surface, or presentation behavior |
| `engine/render/webgpu` | private WebGPU resource, batching, and pass implementation | changing graphics-binding behavior without exposing it to games |
| `example/wukong` | an optional game and its private simulation/presentation code | changing the example, never engine policy |
| `experiments/webgpu-*` | isolated dependency and platform evidence | collecting evidence for a later dependency decision, not shipping engine behavior |

The public support tier of each package is defined in
[the API policy](PUBLIC_API.md). A package being exported does not make every
new behavior stable; technology-preview packages may change in the next minor
release. Do not treat example or experiment code as an API precedent.

## Frame and input flow

An `engine.Application` initializes a `Runtime`, updates portable game state,
and records ordered `engine/render` commands. The runtime owns ECS schedule
execution and portable texture data; a backend creates its own native GPU cache
from those textures.

For a new `engine.Host`, the owner goroutine creates platform resources, polls
callbacks, converts them to `engine.Event`, then calls `Runtime.SampleInput`
before `Update` or `FixedUpdate`. It draws and presents on that same goroutine,
then releases the host context on shutdown. The full contract is in
[HOSTS.md](HOSTS.md), with control and unit rules in [INPUT.md](INPUT.md).

`engine/platform` owns the Linux X11 and browser host paths. The Linux host has
local creation and startup smoke coverage, and the browser host has limited
local Chromium render/input/resize/focus/visibility coverage. Cross-platform
host parity remains unverified.

## Renderer and platform boundary

The renderer uses private WGSL shaders and the pinned low-level WebGPU binding
in [ADR 0003](adr/0003-engine-owned-webgpu-renderer.md). Runtime evidence is
intentionally narrower than source-target builds; failures must remain
contextual rather than falling back to another graphics API.
