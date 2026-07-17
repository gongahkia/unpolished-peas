# Releases and support

`main` is an integration branch, not an installation target. The current draft tag, `v0.0.3`, is withdrawn because its public archive lacks the `sdl.playGame` API emitted by the current starter.

## Release contract

A maintainer must complete all of these steps for every new tag:

1. Update `src/starter.zig`, `templates/bounce/README.md`, and the root README with the exact new tag URL and the hash printed by `zig fetch <tag-archive-url>`.
2. Run the required local checks in [CONTRIBUTING.md](../../CONTRIBUTING.md), including the clean archive starter test.
3. Push an immutable `vMAJOR.MINOR.PATCH` tag only after CI is green.
4. Let the tag workflow generate, build, and run a project from that exact public archive with empty Zig caches. The workflow rejects a local path dependency or a tag mismatch.
5. Publish the generated desktop archives and checksums as a non-draft GitHub release.

A release is not validated merely because a checkout archive or a local path dependency builds. The public tag archive is the consumer contract.

## Installing a published release

Once a non-withdrawn tag is published, use the starter command documented for that version. Do not copy a dependency URL or hash from `main`; it may reference the next unreleased contract.

## Capability policy

Headless tests are required on every supported platform. Explicit GPU backend conformance is required only on runners that provide the documented real or software context. A runner that cannot create an OpenGL context must record `capability-unavailable`; it cannot be counted as renderer coverage.
