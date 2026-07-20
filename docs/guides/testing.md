# Testing

Run deterministic engine targets through the project CLI:

```sh
zig build peas -- test unit
zig build peas -- test replay
zig build peas -- test visual
zig build peas -- test integration
```

Runnable references:

- [Headless bounce](../../examples/bounce.zig)
- [Breakout simulation](../../examples/breakout_game.zig)

For a callback game, `up.testSupport.HeadlessGameRunner(Game)` owns a core canvas and `GameProtocol`. Pass deterministic `HeadlessFrame` values, then inspect `runner.capture().image_hash` and `runner.capture().commands`; no native window or browser is required.

## Safari WebDriver

`zig build test-browser-safari` packages the browser proof game and drives Safari through its native WebDriver endpoint with forced `webgl2` and `webgpu` requests. Before running locally, enable WebDriver once with `safaridriver --enable`; Safari’s automation sessions are isolated from normal browsing data. The test writes the Safari version, WebDriver status, forced-renderer diagnostic, host artifacts, and screenshots under `zig-out/diagnostics/browser-safari/`.
