# Contributing

`main` is an unreleased integration branch. Do not describe it as a release or update the starter's pinned dependency except as part of the release procedure.

## Before opening a change

```sh
zig fmt --check build.zig src examples templates
python3 script/check_third_party_notices.py
UP_EXPECTED_ZIG_VERSION=0.15.2 script/test_zig_compatibility.sh
script/test_downstream_fixture.sh
zig build test
```

Run the focused test for the subsystem you changed as well. Desktop, browser, package, and release tests have platform prerequisites and are defined in `.github/workflows/toolchain.yml`.

## Compatibility and dependencies

- Treat exports from `src/unpolished_peas.zig` and `src/backend/sdl_gpu.zig` as public API. Update their snapshots, docs, and external fixtures deliberately.
- Keep every vendored, fixture, and fetched dependency in `THIRD_PARTY_NOTICES.json`; `script/check_third_party_notices.py` checks names and pinned source revisions.
- Keep renderer capability reporting truthful. A test may skip an unavailable host capability only when it records that state and a separate required lane exercises the feature.

## Release changes

A release candidate must have a green CI run before tagging. The tag workflow generates and builds the starter from the exact public archive URL and uses the result to publish a non-draft GitHub release. See [the release guide](docs/guides/releases.md).
