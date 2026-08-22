#!/usr/bin/env sh
set -eu

status=0
for workflow in .github/workflows/*.yml; do
  while IFS= read -r line; do
    case "$line" in
      *uses:*)
        if ! printf '%s\n' "$line" | grep -Eq '@[0-9a-f]{40}([[:space:]]*(#.*)?$)'; then
          printf 'workflow action is not pinned to a full commit SHA: %s: %s\n' "$workflow" "$line" >&2
          status=1
        fi
        ;;
    esac
  done < "$workflow"
done
exit "$status"
