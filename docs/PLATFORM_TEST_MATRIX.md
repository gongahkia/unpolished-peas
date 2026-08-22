# Platform runtime test matrix

This is the required execution record for changing a target's classification
in the generated [support ledger](SUPPORT.md). It is not a substitute for a
claim in `support-evidence.json`: record a claim only after every applicable
test below passes on the exact commit and environment.

## Record header

Capture these fields before testing:

- full 40-character commit SHA and whether the worktree was clean;
- UTC date, operating system edition/build, CPU architecture, and host type;
- GPU model, driver version, backend, and display scale/monitor details;
- browser name, exact version, WebGPU enablement, and HTTPS or localhost
  secure-context condition for web tests;
- command, test type, result, and links to retained logs/artifact checksums.

An unavailable field is recorded as `not observed`, not omitted. A browser
result does not stand in for another browser or an OS result.

## Required scenarios

Run the engine examples and a texture-bearing scene on Linux X11, Windows, and
macOS. Run the browser bundle on Chromium, Firefox, and Safari where WebGPU is
available. For each applicable target, record:

1. startup, first presentation, texture upload/reload, and input response;
2. resize at one scale and a DPI/display-scale change at another;
3. minimize/restore or hidden/visible transition without a large simulation
   delta or stale held input;
4. a user-initiated close followed by clean listener/resource shutdown;
5. surface/device loss and recovery, then a new textured frame; and
6. an explicit result for unsupported WebGPU instead of a fallback claim.

The current `make device-loss-simulation` target injects `wgpu.ErrDeviceLost`
into the private renderer recovery path and checks that a portable texture is
rehydrated after recreation. It is a deterministic software/fallback-adapter
test, not a driver-reset or browser `GPUDevice.lost` result.

## Browser device loss

WebGPU exposes device loss through `GPUDevice.lost`. The pinned Go binding
currently does not expose that promise through its public browser `Device`
API, so 72 cannot honestly mark browser device-loss recovery as passed from
the engine's normal browser smoke. Do not use the older isolated experiment's
controlled `device.destroy()` result as runtime support evidence for this
engine host. Keep browser delivery WebGPU-only experimental until an
engine-level loss observation/recovery path and the Chromium/Firefox/Safari
matrix have complete ledger entries.

## Recording result

After a complete run, add one JSON claim per test/environment to
`docs/support-evidence.json`; then run:

```sh
make support-doc
make support-check
```

Review the generated diff. A missing scenario, abbreviated commit, or absent
environment metadata leaves the target classification unchanged.
