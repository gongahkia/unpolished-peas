# Performance baselines and review

72 has four deterministic CPU reference-render scenes: sprites, tile maps,
primitives, and text. They measure command processing and raster work through
`render.ReferenceBackend` at a fixed logical `320x180` target. They are not GPU
benchmarks and do not establish a platform support claim.

Each benchmark reports static scene facts alongside timing: `commands/op`,
`sprite-runs/op`, `tile-cells/op`, and `visible-tiles/op`. A sprite run is a
contiguous same-layer/texture/material/space/clip command group that could be batched
while preserving order; it is not a measured GPU batch or draw call. Tile-cell
values exclude empty (`< 0`) cells and visibility includes any cell intersecting
the target viewport.

Run the scenes directly:

```sh
make benchmark
```

The selected WebGPU renderer also has a deterministic software-adapter tile
scene. It reports submitted visible tiles, batches, and draw calls after a
warm-up upload:

```sh
make benchmark-webgpu
```

`BenchmarkHeadlessTileMapScene` uses the binding's fallback software adapter,
not a physical GPU. Its `visible-tiles/op`, `batches/op`, and `draw-calls/op`
values verify the submitted scene shape; its timing is not a hardware
performance baseline and must not be compared to the CPU reference scenes.

Capture a reviewable report without overwriting an existing file:

```sh
mkdir -p reports
make benchmark-report REPORT=reports/render-$(git rev-parse --short HEAD).md
```

The report records revision, branch, Go version, operating system/kernel, CPU
count, five `go test -bench` samples, nanoseconds per operation, allocation
counts, and bytes per operation. Add the CPU model, power/thermal mode,
`GOMAXPROCS`, and any unusual background load before publishing it for review.

A representative result shape is:

```text
BenchmarkReferenceTileMapScene-N  N  N ns/op  2.000 commands/op  0 sprite-runs/op  880 tile-cells/op  858 visible-tiles/op  N B/op  N allocs/op
```

The time and allocation values vary by machine and Go release. The static
scene metrics let reviewers tell whether two results exercised the same amount
of work before comparing them.

## Runtime metrics

`Runtime.Diagnostics()` returns the concurrency-safe
`diagnostics.Registry` owned by a runtime. `runtime.update_time` and
`runtime.draw_time` record duration samples. Command renderers receive that
registry through `render.Frame.Diagnostics` and record `renderer.*` metrics:
command kinds, non-empty/visible tile cells, compatible sprite runs, portable
texture counts and bytes, and render-target counts and bytes.

The engine-owned WebGPU renderer additionally records `renderer.texture_uploads`,
`renderer.native_texture_entries`, `renderer.native_texture_bytes`,
`renderer.native_buffer_bytes`, `renderer.native_pipeline_entries`,
`renderer.batches`, and `renderer.draw_calls`. Texture bytes are an RGBA8
dimension-based cache estimate and exclude driver overhead; buffer bytes are
the capacity of private reusable vertex and instance buffers; pipeline entries
count private cached pipelines; and batches/draws count submitted command
batches for the current frame. They are useful local diagnostics, not
cross-platform performance certification.

## Optional CPU trace export

An application can opt into a bounded CPU timeline for runtime updates, draws,
and renderer submission without enabling a global profiler:

```go
trace := diagnostics.NewTrace(4_096)
runtime.SetTrace(trace)

// after the capture window:
data, err := trace.ChromeJSON()
if err != nil {
    return err
}
if err := os.WriteFile("trace.json", data, 0o644); err != nil {
    return err
}
```

Open `trace.json` in Perfetto or Chrome's tracing viewer. The recorder keeps
the newest spans when it reaches capacity and reports discarded spans through
`Snapshot`. These are CPU wall-time spans through runtime and renderer
submission; they do not provide GPU timestamps or prove presentation latency.

## Comparing changes

Compare only reports with the same Go version, command, scene dimensions, and
machine configuration. The initial review budget is a five-percent regression
in median `ns/op`, allocations, or `B/op` for a scene. It is a review trigger,
not a CI gate: a change above it needs a measurement repeat, an explanation,
and an explicit maintainer decision. A speedup must not relax an exact
reference-render test or hide allocations in setup outside the timed loop.

Do not compare raw results across different CPU models or power modes. They are
useful as separate baselines, not as evidence that one change regressed.

## Manual GPU validation matrix

When a renderer exists, capture one row per target before making a performance
or support claim:

| Target | OS/compositor or browser | GPU and driver | Renderer/library version | Resolution/DPI | Scene | Median/1% frame time | Draws/batches/uploads | Result and caveats |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Example | Fedora Wayland | vendor, device, driver | pinned version | logical/physical | named scene | measured values | measured values | runtime result or failure |

Record whether the result is runtime-tested or compile-only. Include resize,
hidden/minimized behavior, clean shutdown, and a device/surface-loss result
where the target can exercise them. Attach source command output or a trace;
do not replace the matrix with an unsupported "works on my machine" summary.

The current engine-owned renderer has a local deterministic software-WebGPU
image regression and a five-second example startup smoke. Its manual evidence
must not be compared with CPU reference numbers as though they measured the
same work.
