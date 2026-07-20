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
cp "$root/build.zig" "$worktree/build.zig"
cp "$root/contracts/v1_public_api.zig" "$worktree/contracts/v1_public_api.zig"
printf '\npub const PreReleaseContractProbe = struct {};\n' >> "$worktree/packages/core/src/core.zig"
(cd "$worktree" && zig build api-contract)
PUBLIC_API_COMPATIBILITY_ROOT="$worktree" sh "$root/script/check_public_api_regression.sh"
