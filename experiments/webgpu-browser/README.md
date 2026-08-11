# browser WebGPU spike

This wasm-only module is a disposable validation experiment for issue #3. It
does not import `engine` and it is not a production 72 browser host. It uses
the browser's `navigator.gpu` API directly through `syscall/js`, so it also
shows the browser-specific async device and presentation boundary that a future
host must own.

The program:

- obtains `navigator.gpu`, requests an adapter and device, and displays
  actionable status if any step is unavailable;
- owns a `<canvas>`, configures its WebGPU context, tracks CSS size and device
  pixel ratio on window resize, and submits a clear render pass each animation
  frame;
- skips presentation for hidden documents and reports a `GPUDevice.lost`
  notification instead of silently falling back to another renderer; and
- leaves all Go runtime and renderer APIs out of the experiment.

## reproduce

Run these commands from this directory:

```sh
GOOS=js GOARCH=wasm go build -o web/spike.wasm .
cp "$(go env GOROOT)/lib/wasm/wasm_exec.js" web/wasm_exec.js
python3 -m http.server 8080 --directory web
```

Open <http://127.0.0.1:8080>. Do not use `file://`: WebGPU is available only
in secure contexts in supporting browsers. Local loopback is appropriate for a
development check; deploy through HTTPS in a non-local environment.

On a working adapter the status changes to `WebGPU ready; rendering a clear
pass` and the canvas becomes a dark blue. Resize the browser to exercise
reconfiguration, switch tabs to exercise hidden-document behavior, and retain
the browser console and GPU/driver data with the result. To inspect the
unsupported path, disable WebGPU or run a browser profile with no available
adapter; the status must identify the failing step without a JavaScript panic.

Generated `spike.wasm` and `wasm_exec.js` are ignored by Git. Remove them after
manual use with `go clean` and `unlink web/spike.wasm web/wasm_exec.js`.

## current compatibility evidence

The first observation below is from 2026-08-11; the unsafe software-WebGPU
observation is from 2026-08-12. Neither is a browser support certification.

| Browser / target | Evidence | Support claim |
| --- | --- | --- |
| Chromium headless on this Fedora 43 environment | The wasm loaded over loopback; `requestAdapter()` returned no adapter and the page rendered `no compatible WebGPU adapter was available`. | Unsupported-path behavior verified; GPU presentation not verified. |
| Chromium 152 headless with `--enable-unsafe-webgpu --enable-features=Vulkan` | The page exposed `navigator.gpu`, configured a `1024x722` canvas from a `1024x768` viewport, then reported `WebGPU device lost: Device was destroyed`. The loss callback runs only after adapter/device creation and surface configuration. | Software/unsafe device-loss path observed; no stable clear-pass or presentation claim. |
| Chromium with a desktop GPU | Not independently verified. | No support claim. |
| Firefox | Not independently verified. | No support claim. |
| Safari | Not independently verified. | No support claim. |

MDN currently marks WebGPU as limited availability and secure-context-only.
Therefore 72 must use runtime feature detection and keep the unsupported
message actionable; it must not publish an unverified version-based browser
promise. A production support matrix requires a successful clear-pass run and
resize/focus/device-loss evidence on each browser and operating-system pair.

## result and limitations

`GOOS=js GOARCH=wasm go build` passes. Browser automation verified the wasm
network response and the no-adapter status. A separate unsafe software-WebGPU
run reached device creation, surface configuration, and `GPUDevice.lost`, but
the device was destroyed before a stable clear-pass result could be observed.
Neither result verifies clear-pass presentation, resize on a live GPU context,
or normal device-loss recovery. The spike deliberately uses only a clear pass;
it does not prove a WGSL pipeline, asset upload, or the engine command
renderer.

## sources

- [MDN WebGPU API: availability, security, adapter/device, and canvas flow](https://developer.mozilla.org/en-US/docs/Web/API/WebGPU_API)
- [WebGPU specification](https://www.w3.org/TR/webgpu/)
- [Go `syscall/js` package](https://pkg.go.dev/syscall/js)
