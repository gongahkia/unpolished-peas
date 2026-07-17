# Changelog

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and semantic versioning after its first non-draft release. Every non-draft release gets a dated section using Added, Changed, Deprecated, Removed, Fixed, and Security categories; published sections are immutable except for marked factual corrections. See the [release policy](docs/guides/releases.md#changelog-policy).

## Unreleased

- Release engineering, CI, documentation, and runtime behavior are not a stable public contract.

### Removed

- Engine-owned extension manifests, resolution, locks, fixtures, and CI gates. See [v0.1 migrations](docs/guides/migrations.md).
- Engine-owned particle emitters and their public API.
- Engine-owned ECS and its public API, examples, fixtures, and tests.
- Engine-owned immediate-mode UI and its public API, examples, fixtures, and tests.

## 0.0.3 — withdrawn

- This draft tag does not provide the `sdl.playGame` API used by the current starter template.
- Do not start a new project from this tag.
