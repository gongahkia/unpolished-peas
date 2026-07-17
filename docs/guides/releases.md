# Releases and support

`main` is an integration branch, not an installation target. The current draft tag, `v0.0.3`, is withdrawn because its public archive lacks the `sdl.playGame` API emitted by the current starter.

## v0.1 support

The engine source supports Zig `0.15.1` and `0.15.2`. The generated starter requires the Zig version named in its copied template; the current v0.1-draft template requires `0.15.2`.

The [v0.1 capability matrix](capabilities.md) is the release platform contract. Its `supported` rows are macOS, Linux, and Windows with SDL GPU. `preview` rows are available for evaluation but have no v0.1 compatibility guarantee. `unsupported` rows are not offered by the v0.1 contract. `removed` means deliberately absent and has no upgrade path.

## v0.1 compatibility

`v0.1.x` patch releases preserve every public v0.1 core module, type, callback signature, lifecycle rule, error behavior, deterministic hook, supported target, and starter manifest format. Compatible changes include documentation corrections, implementation fixes that restore documented behavior, and additive APIs outside the frozen core.

A release is breaking when it removes or renames a public core export, changes a callback or error contract, changes fixed-timestep semantics, makes a supported target preview or unsupported, or changes generated-project dependency or package behavior. Breaking core changes require the next minor release (`v0.2.0`), a revised capability matrix, an API snapshot review, and explicit migration notes.

## Starter upgrades

Each generated project pins one public release archive URL and its matching hash in `build.zig.zon`. Upgrade both coordinates together from that release's starter template or release notes; never mix a URL from one tag with a hash from another, and never copy coordinates from `main`. Then run `zig build`, the generated project's test target, and its documented frame smoke before committing the upgrade.

## Release contract

A maintainer must complete all of these steps for every new tag:

1. Update `src/starter.zig`, `templates/bounce/README.md`, and the root README with the exact new tag URL. The generator resolves the archive hash with `zig fetch` and pins that result in each generated manifest.
2. Run the required local checks in `CONTRIBUTING.md`, including the clean archive starter test.
3. Push an immutable `vMAJOR.MINOR.PATCH` tag only after CI is green.
4. Let the tag workflow generate, build, and run a project from that exact public archive with empty Zig caches. The workflow rejects a local path dependency or a tag mismatch.
5. Publish the generated desktop archives and checksums as a non-draft GitHub release.

A release is not validated merely because a checkout archive or a local path dependency builds. The public tag archive is the consumer contract.

## Installing a published release

Once a non-withdrawn tag is published, use the starter command documented for that version. Do not copy a dependency URL or hash from `main`; it may reference the next unreleased contract.

## Changelog policy

Every non-draft release adds a dated section to `CHANGELOG.md` using Keep a Changelog categories: Added, Changed, Deprecated, Removed, Fixed, and Security. The section must identify compatibility impact and link migration instructions for every breaking change. Published release sections are immutable except for clearly marked factual corrections.

## Capability policy

Headless tests are required on every supported platform. Explicit GPU backend conformance is required only on runners that provide the documented real or software context. A runner that cannot create an OpenGL context must record `capability-unavailable`; it cannot be counted as renderer coverage. The [capability matrix](capabilities.md) owns status and CI-selection changes; update it before changing platform claims elsewhere.
