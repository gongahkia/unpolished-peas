#!/usr/bin/env bash
set -euo pipefail

repo="${1:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}"
index="$(mktemp)"
cleanup() {
    rm -f "$index"
}
trap cleanup EXIT HUP INT TERM

# Use a private index so archive-based tests include the current reviewed
# worktree without staging, committing, or changing the caller's index.
GIT_INDEX_FILE="$index" git -C "$repo" read-tree HEAD
GIT_INDEX_FILE="$index" git -C "$repo" add -A
GIT_INDEX_FILE="$index" git -C "$repo" write-tree
