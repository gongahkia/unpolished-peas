# Browser renderer diagnostics

The browser bundle exposes `window.unpolishedPeas.rendererDiagnostic` and the same JSON as the local `renderer-diagnostics.json` artifact returned by `window.unpolishedPeas.host.artifacts()`. Both use schema version 1 and contain requested and selected renderer, fallback reason, recovery instruction, generic browser target, WebGL 2/WebGPU capability status, context status, adapter/device status, and recovery state.

The object deliberately excludes the raw user agent, hardware adapter name, driver, device ID, and any remote endpoint. It is local diagnostic data for browser/package tests, not telemetry.

`?renderer=webgl2` selects WebGL 2. `?renderer=webgpu` selects WebGPU or fails before the game loop with an adapter/device diagnostic. `?renderer=auto` prefers a ready WebGPU backend and otherwise selects WebGL 2 with a deterministic `*_fallback` reason. The package manifest records this query selection contract; the diagnostic artifact records the actual selection. WebGPU remains outside the current [capability matrix](capabilities.md) until its full stable-core conformance coverage is complete.

The internal WebGPU canvas lifecycle records only adapter/device state, the preferred canvas format, and logical dimensions; it never records hardware names, driver data, or device IDs. Package renderer selection remains governed by the capability matrix.

On WebGPU device loss, the host cancels scheduled frames, rejects subsequent rendering calls, and replaces the local renderer diagnostic with `context_status: "device_lost"`, `device_status: "lost"`, and `fallback_reason: "device_lost"`. The v0.1 policy is terminal restart: reload the package to create a new device; it does not migrate resources or switch renderers in place. WebGL 2 keeps its independent context-loss/restoration path.

Run `zig build test-browser-renderer-diagnostics` for schema checks and `zig build test-browser-chromium` for the packaged artifact path.
