#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
fixture="$(mktemp -d)"
worktree="$fixture/worktree"

cleanup() {
    git -C "$root" worktree remove --force "$worktree" >/dev/null 2>&1 || true
    rm -rf "$fixture"
}
trap cleanup EXIT

git -C "$root" worktree add --detach --quiet "$worktree" HEAD
if ! git -C "$root" diff --quiet HEAD; then
    git -C "$root" diff --binary HEAD | git -C "$worktree" apply
fi
printf '\npub const PreReleaseContractProbe = struct {};\n' >> "$worktree/packages/core/src/core.zig"
(cd "$worktree" && zig build api-contract)
PUBLIC_API_COMPATIBILITY_ROOT="$worktree" sh "$root/script/check_public_api_regression.sh"
if PRE_RELEASE_API_BASELINE_ROOT="$worktree" sh "$root/script/check_pre_release_api_baseline.sh" >/dev/null 2>&1; then
    exit 1
fi
