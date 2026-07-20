#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
platform=${1:?usage: test_desktop_package_matrix.sh <linux|macos|windows>}
case "$platform" in linux|macos|windows) ;; *) printf '%s\n' 'usage: test_desktop_package_matrix.sh <linux|macos|windows>' >&2; exit 64 ;; esac
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

for game in bounce topdown puzzle; do
    case "$platform" in
        linux) "$repo/script/test_linux_package.sh" "$tmp/$game" "$game" ;;
        macos) "$repo/script/test_macos_package.sh" "$tmp/$game" "$game" ;;
        windows) powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$repo/script/test_windows_package.ps1" -OutputDirectory "$tmp/$game" -Game "$game" ;;
    esac
done
printf '%s\n' "desktop-package-matrix passed: platform=$platform games=bounce,topdown,puzzle"
