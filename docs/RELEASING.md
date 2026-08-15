# v0.1 release dry run

72 has no v0.1 release today. The primary product is a signed, annotated
semantic-version Go module tag. Browser bundles are release evidence and demo
artifacts, not a substitute engine product or a generic desktop-binary
distribution. This procedure does not relax the support policy.

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
8. Complete the immutable evidence ledger in
   [`support-evidence.json`](support-evidence.json), regenerate `SUPPORT.md`,
   and keep any target without the required runtime matrix at its existing
   classification.

The latest remote CI inspection found that GitHub Actions is rejecting every
job before it starts because of account-payment or spending-limit state. That
is not test evidence. Restore runner eligibility and obtain a successful run
for the exact tag before release review; do not alter `SUPPORT.md` to make the
configuration look executed.

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

## Signed module tag and demo artifact build

After the prerequisites pass on a clean reviewed commit, create and verify an
annotated signed tag locally:

```sh
git tag -s v0.1.0 -m "72 v0.1.0"
git verify-tag v0.1.0
git push origin v0.1.0
```

The manual `reviewed release artifacts` workflow accepts an annotated `v0.x.y`
tag, checks that it is the checked-out commit, and builds only the versioned
wasm demo archive plus `SHA256SUMS` and an SPDX SBOM. It has no
`contents: write` permission and does not create a GitHub release, publish a
Go package, or publish desktop example binaries. Configure the repository's
`release` environment with required reviewers, then dispatch from the tag:

```sh
gh workflow run release.yml --ref v0.1.0 -f tag=v0.1.0 -f attest=false
```

Release reviewers must verify the tag signature, workflow run, artifact
checksums, SBOM, target evidence ledger, and release notes before separately
publishing any GitHub release. Authorized Go module consumers resolve the
signed tag through normal module tooling; while the repository remains private,
they also need the appropriate private-module configuration and access.

Artifact attestations are opt-in through the workflow input. The repository is
currently private, and GitHub makes private-repository attestations available
only to Enterprise Cloud; set the `ATTESTATIONS_ELIGIBLE` repository variable
only after confirming eligibility, then dispatch with `attest=true`. The job
has attestation-specific permissions only when this opt-in path runs. See
[GitHub's attestation eligibility and permission guidance](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations).

## Tag and artifact checklist

When every prerequisite is evidenced and reviewed:

1. Re-run the dry run from the intended commit and retain its output.
2. Verify `go.mod`, `go.sum`, `package-lock.json`, source revision, and third
   party notices are the reviewed versions.
3. Build each claimed artifact in the target environment; publish checksums and
   artifact metadata alongside it. Do not call a cross-compile a runtime test.
4. Create the signed, annotated tag only after the release notes, API review,
   target evidence, and artifacts match the same commit.
5. Publish release notes with supported versus build-only targets, all known
   limitations, and the module tag/checksum data. If a follow-up changes tag
   artifacts, cut a new release rather than replacing opaque files.

The release workflow only creates reviewable workflow artifacts. It has no
authority to create a tag, GitHub release, or package-registry artifact.
