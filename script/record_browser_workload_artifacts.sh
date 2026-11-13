#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
browser=${UP_BROWSER:-chromium}
renderers=${UP_RENDERERS:-"webgl2 webgpu"}
artifacts=${UP_PERFORMANCE_ROOT:-$repo/zig-out/performance}
case "$artifacts" in /*) ;; *) artifacts=$repo/$artifacts ;; esac
case "$browser" in
    chromium) engine=chrome ;;
    firefox) engine=firefox ;;
    webkit) engine=webkit ;;
    *) printf 'unsupported browser workload engine: %s\n' "$browser" >&2; exit 64 ;;
esac
tmp=$(mktemp -d)
trap 'if [ "${server:-}" ]; then kill "$server" 2>/dev/null || true; fi; rm -rf "$tmp"' EXIT HUP INT TERM
session=unpolished-peas-browser-workloads-$$
pw=$repo/script/playwright_cli.sh

decode_result() {
    encoded=$(sed -n 's/^"\([A-Za-z0-9+\/=][A-Za-z0-9+\/=]*\)"$/\1/p' "$1" | head -n 1)
    test -n "$encoded"
    if printf '%s' "$encoded" | base64 -D > "$2" 2>/dev/null; then return; fi
    printf '%s' "$encoded" | base64 -d > "$2"
}

record_renderer() {
    renderer=$1
    case "$renderer" in webgl2|webgpu) ;; *) printf 'unsupported browser workload renderer: %s\n' "$renderer" >&2; return 64 ;; esac
    output=$tmp/$renderer.out
    artifact=$artifacts/browser-workloads-$browser-$renderer.json
    "$pw" -s="$session" open "http://127.0.0.1:8126/?renderer=$renderer" --browser "$engine"
    "$pw" -s="$session" snapshot > "$tmp/$renderer.snapshot.txt"
    "$pw" -s="$session" eval "async () => { const browser = \"$browser\"; const renderer = \"$renderer\"; const encode = (value) => { const bytes = new TextEncoder().encode(JSON.stringify(value)); let text = \"\"; for (const byte of bytes) text += String.fromCharCode(byte); return btoa(text); }; const catalog = await fetch(\"./workloads-v1.json\").then((response) => response.json()); const runner = await import(\"./workload_runner.mjs\"); const version = runner.browserVersion(browser, navigator.userAgent); const api = window.unpolishedPeas; if (api?.renderer !== renderer) return encode(runner.unavailableBrowserWorkloadArtifact({browser: {name: browser, version}, renderer, workloadVersion: catalog.workload_version, diagnostic: api?.rendererDiagnostic ?? null})); try { return encode(runner.benchmarkWorkloadCatalog(api.runtime, api.host, catalog, {browser: {name: browser, version}, renderer})); } catch (error) { return encode({schema_version: 1, status: \"error\", target: {os: \"browser\", architecture: \"browser\", browser: {name: browser, version}, renderer}, workload_version: catalog.workload_version, workloads: [], timer: {clock: \"performance.now\", unit: \"nanoseconds\", measurement: \"cpu_submission\", limitations: runner.browserTimerLimitations}, diagnostics: {error: error instanceof Error ? error.message : String(error), renderer_diagnostic: api?.rendererDiagnostic ?? null}}); } }" > "$output"
    decode_result "$output" "$artifact"
    "$pw" -s="$session" close
    node "$repo/script/validate_browser_workload_artifact.mjs" "$artifact" "$browser" "$renderer"
}

mkdir -p "$artifacts"
cd "$repo"
script/package_web.sh "$tmp/package" --game bounce
bundle="$tmp/package/unpolished-peas-bounce-web"
python3 -m http.server 8126 --bind 127.0.0.1 --directory "$bundle" > "$tmp/server.log" 2>&1 &
server=$!
sleep 1
cd "$tmp"
for renderer in $renderers; do record_renderer "$renderer"; done
printf 'browser workload artifacts recorded: browser=%s renderers=%s root=%s\n' "$browser" "$renderers" "$artifacts"
