# Performance baselines and review

72 has four deterministic CPU reference-render scenes: sprites, tile maps,
primitives, and text. They measure command processing and raster work through
`render.ReferenceBackend` at a fixed logical `320x180` target. They are not GPU
benchmarks and do not establish a platform support claim.

Run the scenes directly:

```sh
make benchmark
```

Capture a reviewable report without overwriting an existing file:

```sh
mkdir -p reports
make benchmark-report REPORT=reports/render-$(git rev-parse --short HEAD).md
```

The report records revision, branch, Go version, operating system/kernel, CPU
count, five `go test -bench` samples, nanoseconds per operation, allocation
counts, and bytes per operation. Add the CPU model, power/thermal mode,
`GOMAXPROCS`, and any unusual background load before publishing it for review.

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

The current WebGPU work has only isolated experiments and no engine-owned GPU
renderer. Its manual evidence belongs in their compatibility records and must
not be compared with the CPU reference numbers as though they measured the
same work.
