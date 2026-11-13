# Browser renderer diagnostics

The browser bundle exposes `window.unpolishedPeas.rendererDiagnostic` and the same JSON as the local `renderer-diagnostics.json` artifact returned by `window.unpolishedPeas.host.artifacts()`. Both use schema version 1 and contain requested and selected renderer, fallback reason, recovery instruction, generic browser target, WebGL 2/WebGPU capability status, context status, adapter/device status, and recovery state.

The object deliberately excludes the raw user agent, hardware adapter name, driver, device ID, and any remote endpoint. It is local diagnostic data for browser/package tests, not telemetry. Smoke-test artifacts add the selected browser name, parsed browser version, and user agent outside this runtime diagnostic so a captured failure identifies its host.

`?renderer=webgl2` selects WebGL 2. `?renderer=webgpu` selects WebGPU or fails before the game loop with an adapter/device diagnostic. `?renderer=auto` prefers a ready WebGPU backend and otherwise selects WebGL 2 with a deterministic `*_fallback` reason. The package manifest records this query selection contract; the diagnostic artifact records the actual selection. Chromium and Safari WebGPU are [preview](capabilities.md); Firefox WebGPU is unsupported.

The internal WebGPU canvas lifecycle records only adapter/device state, the preferred canvas format, and logical dimensions; it never records hardware names, driver data, or device IDs. Package renderer selection remains governed by the capability matrix.

On WebGPU device loss, the host cancels scheduled frames, rejects subsequent rendering calls, and replaces the local renderer diagnostic with `context_status: "device_lost"`, `device_status: "lost"`, and `fallback_reason: "device_lost"`. The v1.0 policy is terminal restart: reload the package to create a new device; it does not migrate resources or switch renderers in place. WebGL 2 keeps its independent context-loss/restoration path.

Run `zig build test-browser-renderer-diagnostics` for schema checks, `zig build test-browser-chromium` for packaged Chromium smoke, `zig build test-browser-firefox` for packaged Firefox WebGL 2 smoke with an explicit declared-WebGPU-unavailable result, and `zig build test-browser-renderer-parity` for the forced Chromium WebGL 2/WebGPU corpus. Parity permits an absolute per-channel RGBA delta of one; a failure retains both PNG captures, dimensions, renderer diagnostics, and command traces in `zig-out/diagnostics/browser-renderer-parity/` (or `UP_DIAGNOSTICS_ROOT`).

## Local logs and failure evidence

Start with the [debugging workflow](developer-diagnostics.md). On a served game,
`?renderer=webgl2&peas-log=debug` enables readable console events and structured
collection. `peas-log-categories=engine,render` filters categories; `all` selects
all. Levels/categories match the native controls in that workflow. Omit
`peas-log` or use `peas-log=off` to disable collection. Invalid filters warn and
disable logging rather than preventing the game from starting. Custom hosts
can pass `logging: {level: "debug", categories: ["engine", "render"]}` to
`createBrowserHost`.

In developer tools, inspect a snapshot:

```js
const evidence = window.unpolishedPeas.host.artifacts();
console.table(evidence.map(({name, type}) => ({name, type})));
const events = evidence.find(({name}) => name === "events.jsonl");
console.log(events?.data);
```

This is a local array of `{name, type, data}` records, not a filesystem path.
Text/JSON records contain text; `screenshot.png` contains a PNG data URL.
To download a selected record using ordinary browser APIs:

```js
async function downloadEvidence(name) {
  const record = evidence.find((item) => item.name === name);
  if (!record) throw new Error("Artifact unavailable: " + name);
  const blob = record.type === "image/png"
    ? await (await fetch(record.data)).blob()
    : new Blob([record.data], {type: record.type});
  const link = document.createElement("a");
  link.href = URL.createObjectURL(blob);
  link.download = record.name;
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(link.href), 1000);
}
await downloadEvidence("events.jsonl");
```

Repeat for `logging.json` and the desired incident/renderer/trace/command/PNG
records. Save them together in a new directory, preserving filenames; the
existing `peas support-bundle` command can then select/redact that directory.
Browser download policies may require allowing each download. This helper
fetches only the captured PNG data URL, never a remote service. The automated
[authoring harness](browser-authoring.md) writes these records directly and
tests real CLI exports; case reports identify exact session directories.

| Retained data per host | Maximum |
| --- | --- |
| Legacy diagnostic messages | 128, each at most 1,024 UTF-8 bytes |
| Trace records | 512, each at most 4,096 serialized UTF-8 bytes |
| Command records | 256, each at most 4,096 serialized UTF-8 bytes |
| Structured events | 128 and 256 KiB total serialized UTF-8 bytes |
| Message/string field | 1,024 UTF-8 bytes; at most 16 primitive fields per event |
| Renderer diagnostic | 4,096 serialized UTF-8 bytes |
| PNG | Latest valid data URL, at most 16 MiB encoded ASCII |
| Failure incidents | Latest four, each with bounded event/trace/command context and applicable PNG |

Oldest records are evicted; malformed/oversized legacy payloads are rejected;
structured text is truncated at a valid UTF-8 boundary. `logging.json` schema 1
reports limits, drops, rejections, truncations and console-sink errors. Existing
`diagnostics.json`, `commands.json`, `trace.json` and renderer schema shapes are
retained. `events.jsonl` uses the native v1 event schema; elapsed timestamp and
frame semantics are described in the debugging workflow.

When collection is enabled, protocol errors generate
`incident-<session>-<failure>.json` with the original error/phase/operation,
frame, current renderer diagnostic, recent events and optional capture. A
capture failure is counted and does not replace the game failure. Incidents
are diagnostic evidence, not replay recordings. A browser unable to export
canvas PNG may still expose renderer readbacks through the test harness;
the independent Safari PNG/readback requirements remain unchanged.

Evidence belongs to the host and remains available after shutdown until the
host is released. Reload/new host creation resets it, so export before reload.
Snapshots and PNG conversion allocate; serialized payload bounds are not a
total JavaScript heap, browser console or GPU memory guarantee. External console
retention is controlled by the browser. Collection off avoids structured event
serialization and clock reads; compiled protocol-failure messages and explicitly
requested legacy artifacts remain bounded and available.
