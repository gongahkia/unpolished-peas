# v0.1 release dry run

72 has no v0.1 release today. This procedure describes the evidence required
before creating a `v0.x.y` tag; it does not publish a module, create a GitHub
release, or relax the support policy.

## Prerequisites

The release owner needs all of the following before the dry run can pass:

1. A selected project `LICENSE` and a reviewed `NOTICE`/third-party license
   record. The repository currently has neither, so a maintainer must make the
   licensing decision before a release can proceed.
2. A clean, committed worktree and an `Unreleased` changelog entry promoted to
   the exact planned version with date, API migration notes, and limitations.
3. A completed CI run for the exact commit. Its Linux, Windows, macOS, wasm,
   and browser-smoke evidence must be classified using [SUPPORT.md](SUPPORT.md),
   not inferred from local cross compilation.
4. A public API review against [PUBLIC_API.md](PUBLIC_API.md), including
   support tier, compatibility, error/lifecycle, migration, and deprecation
   requirements.
5. A current CPU benchmark report following [PERFORMANCE.md](PERFORMANCE.md)
   and the required manual GPU matrix when the release changes renderer or
   platform behavior.
6. Reproducible artifact evidence: record the exact Go, Node/Playwright, module
   lockfiles, commands, SHA-256 checksums, target architecture, and source
   commit for every published binary or wasm bundle.
7. Run the release dry run with exactly Go 1.25.13. The project baseline stays
   Go 1.25.0; Go 1.26.6 is an informational compatibility target and cannot
   promote a buildable platform to certified support. See the
   [Go release history](https://go.dev/doc/devel/release).

## Local dry run

After adding the planned changelog entry and license records, run:

```sh
make release-dry-run VERSION=v0.1.0
```

The script rejects an invalid version, dirty worktree, a Go version other than
1.25.13, missing license/notice, or missing version heading, then runs
formatting, vet, tests, race tests, first-game/Wukong/audio builds, Wukong's
verified reference replay, wasm builds, and reference benchmarks. It is
deliberately strict: an unsuccessful dry run is a release blocker, not a
request to bypass a check.

The script cannot verify a remote GitHub Actions run or a real GPU/browser
matrix. The release owner must inspect the run for the exact commit and attach
the matrix/report to the release review. The configured CI jobs and current
evidence limits are listed in [SUPPORT.md](SUPPORT.md).

The weekly `go-next` workflow runs Go 1.26.6 as an allowed-to-fail compatibility
signal. It does not change the module's Go baseline or any support
classification.

## Tag and artifact checklist

When every prerequisite is evidenced and reviewed:

1. Re-run the dry run from the intended commit and retain its output.
2. Verify `go.mod`, `go.sum`, `package-lock.json`, source revision, and third
   party notices are the reviewed versions.
3. Build each claimed artifact in the target environment; publish checksums and
   artifact metadata alongside it. Do not call a cross-compile a runtime test.
4. Create the annotated tag only after the release notes, API review, target
   evidence, and artifacts match the same commit.
5. Publish the release notes with supported versus build-only targets and all
   known limitations. If a follow-up changes the tag artifacts, cut a new
   release rather than replacing opaque files.

Release automation may create the tag/release only after this evidence exists.
No automated workflow in this repository currently has authority to publish a
release or package registry artifact.
