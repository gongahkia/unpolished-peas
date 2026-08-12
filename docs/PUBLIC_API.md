# Public API stability and compatibility policy

72 is pre-1.0 software. This policy makes the current runtime useful to
independent game projects without claiming a 1.0 compatibility guarantee.

## Support tiers

| Tier | Packages | Contract |
| --- | --- | --- |
| Supported runtime | `engine`, `engine/ecs`, `engine/scene`, `engine/diagnostics` | 72 maintains source compatibility within a released `v0.x` minor line except for a documented security or correctness exception. |
| Technology preview | `engine/assets`, `engine/audio`, `engine/physics`, `engine/platform`, `engine/render`, `engine/ui` | Public APIs are available for evaluation, but may change in the next minor release as their extension boundaries, backend integration, or test coverage mature. A migration note accompanies intentional breaking changes. |
| Restricted implementation | `engine/render/webgpu` | The package implements the engine-owned renderer for `engine/platform`; applications should depend on `engine/render` commands rather than its binding-facing implementation API. |
| Example-only | `example/wukong/...` | Wukong is a consumer of the public runtime, not an engine package or a support-policy reference. Its `internal` simulation and presentation APIs are not available to other projects. |

An exported identifier is part of the relevant tier only when it appears in a
non-`internal` package under the module path. Tests, example programs, command
tools, generated files, and unexported names do not establish a public API.

## Versioning

72 follows [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html)
with the additional commitments below.

- A patch release changes no exported API in a supported runtime package. It
  contains compatible bug fixes, documentation, build, or verification changes.
- A minor `v0.x` release may make a planned breaking change in a technology
  preview package. It must state the affected symbols, rationale, migration
  path, and replacement in the changelog.
- 72 avoids breaking a supported runtime package during `v0.x`. If an urgent
  correctness or security fix requires one, the release notes must call it out
  as an exception, explain why a compatible alternative was not viable, and
  provide a migration path.
- A post-1.0 incompatible public API change requires a new semantic major
  version and the Go module major-version import suffix where Go requires it.
- Platform support claims, renderer bindings, and artifact distribution are
  release contracts. They are not implied simply because a package compiles on
  a contributor's machine.

This policy does not promise ABI stability, deterministic replay compatibility
across simulation-version changes, or stability for an untagged commit.

## Deprecation and removal

An API is deprecated only by all of the following:

1. A `Deprecated:` Go doc comment names the replacement or explains why no
   replacement exists.
2. The changelog and migration guide identify the first release containing the
   deprecation.
3. The old API remains available for at least one following minor release when
   a practical compatibility shim exists.
4. The removal release and any unavoidable behavior change are announced in
   the release notes.

## Canvas migration

The unreleased command-frame migration removed `engine.Canvas`,
`engine.CommandCanvas`, `engine.Frame`, immediate `Layer.Draw` callbacks, and
`Runtime.Draw(Canvas)`. A layer must now provide `DrawCommands`, record
portable `render` values through its `engine.CommandFrame`, and return any
validation error. Hosts pass a `render.Backend` to `Runtime.Draw`; applications
normally use `engine.Run` and do not invoke it directly.

For example, replace an immediate rectangle draw with a command callback:

```go
engine.Layer{
    ID: "world",
    Space: engine.WorldSpace,
    Parallax: 1,
    DrawCommands: func(frame engine.CommandFrame) error {
        return frame.FillRect(render.RectDraw{
            Bounds: render.Rect{X: 10, Y: 12, W: 16, H: 16},
            Color: render.Color{R: 255, A: 255},
        })
    },
}
```

The runtime supplies layer order, coordinate space, camera translation, and
texture ownership. Renderers receive only `render.Frame`; neither applications
nor hosts require the removed Canvas compatibility interface.

## Public API review checklist

Before adding or changing an exported identifier, a change author and reviewer
must answer these questions in the change description or package documentation:

- Which support tier owns it, and why is an exported API necessary?
- Does it leak a backend, operating-system, filesystem, goroutine, or mutable
  ownership detail that should remain private?
- What are its zero-value, error, lifecycle, concurrency, and determinism
  semantics?
- Can a project use it on every platform claimed by its tier? If not, is the
  limitation explicit and tested or documented as build-only?
- Which focused tests establish expected behavior and likely failure paths?
- If it changes an existing API, is the change source-compatible? If not, are
  the deprecation, migration, and release-note requirements met?

For a release, the checklist is applied to the exported API diff as well as to
new packages. Reviewers must reject an API that exposes a dependency type where
an engine-owned value or interface can preserve the boundary.
