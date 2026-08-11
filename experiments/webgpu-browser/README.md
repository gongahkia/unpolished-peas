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

| Browser / target | Evidence on 2026-08-11 | Support claim |
| --- | --- | --- |
| Chromium headless on this Fedora 43 environment | The wasm loaded over loopback; `requestAdapter()` returned no adapter and the page rendered `no compatible WebGPU adapter was available`. | Unsupported-path behavior verified; GPU presentation not verified. |
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
network response and the no-adapter status. The automated browser had no usable
WebGPU adapter, so the clear pass, resize on a live GPU context, and device-loss
callback are not runtime-verified. The spike deliberately uses only a clear
pass; it does not prove a WGSL pipeline, asset upload, or the engine command
renderer.

## sources

- [MDN WebGPU API: availability, security, adapter/device, and canvas flow](https://developer.mozilla.org/en-US/docs/Web/API/WebGPU_API)
- [WebGPU specification](https://www.w3.org/TR/webgpu/)
- [Go `syscall/js` package](https://pkg.go.dev/syscall/js)
