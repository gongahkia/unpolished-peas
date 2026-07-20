# Browser renderer diagnostics

The browser bundle exposes `window.unpolishedPeas.rendererDiagnostic` and the same JSON as the local `renderer-diagnostics.json` artifact returned by `window.unpolishedPeas.host.artifacts()`. Both use schema version 1 and contain requested and selected renderer, fallback reason, recovery instruction, generic browser target, WebGL 2/WebGPU capability status, context status, adapter/device status, and recovery state.

The object deliberately excludes the raw user agent, hardware adapter name, driver, device ID, and any remote endpoint. It is local diagnostic data for browser/package tests, not telemetry.

`?renderer=webgl2` reports the selected WebGL 2 host after initialization. A forced `?renderer=webgpu` request reports `selected_renderer: null`, `capabilities.webgpu: "unsupported"`, and a recovery instruction to select WebGL 2 because WebGPU is outside the current [capability matrix](capabilities.md).

The internal WebGPU canvas lifecycle records only adapter/device state, the preferred canvas format, and logical dimensions; it never records hardware names, driver data, or device IDs. Package renderer selection remains governed by the capability matrix.

Run `zig build test-browser-renderer-diagnostics` for schema checks and `zig build test-browser-chromium` for the packaged artifact path.
