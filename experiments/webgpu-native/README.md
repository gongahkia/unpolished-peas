# native WebGPU spike

This is a disposable dependency experiment for issue #2. It deliberately uses
a nested module and is not imported by `engine`; a successful experiment is not
approval to expose GoGPU or WebGPU types through the 72 API.

The spike uses `github.com/gogpu/gogpu v0.52.1`, whose native default path uses
`github.com/gogpu/wgpu v0.31.2`. It creates a native window, selects an adapter,
presents a triangle, reports first-surface and first-frame latency, observes
resize and surface lifecycle callbacks, and exits through the framework's
shutdown path. The selected adapter is an implementation detail of the test,
not an engine API decision.

## reproduce

Run the commands from this directory. The native implementation is pure Go, so
set `CGO_ENABLED=0` as required by GoGPU.

```sh
go mod download
CGO_ENABLED=0 go build .
CGO_ENABLED=0 go run .
```

The running window should show a triangle. Resize it, then close it. The
terminal should report a surface lifecycle event, the first-frame latency, any
resize callbacks, `surface destroyed`, and `clean shutdown`. Keep the output
with the platform, GPU, driver, window system, and command used; it is the
evidence needed for the compatibility report.

For a bounded framework-lifecycle smoke run, request a resize halfway through
the duration and then exit through `App.Quit`:

```sh
CGO_ENABLED=0 go run . -smoke-duration=2s
```

This should report the resize request, any resize callback accepted by the
window manager, `smoke quit`, and `clean shutdown`. It verifies the spike's
controlled teardown path; it does not replace a user-initiated window-close
test.

Compile-only target checks do not require a window server:

```sh
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o /tmp/72-webgpu-native-linux .
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -o /tmp/72-webgpu-native-windows.exe .
GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -o /tmp/72-webgpu-native-darwin .
```

Remove test binaries after a local run with `go clean`.

## observed Linux result

On 2026-08-11, this repository's Fedora 43 Linux environment ran the spike
under the available graphical session on Intel Iris Xe Graphics (RPL-U). GoGPU
selected its Vulkan backend, reported `surface available after 63ms`, and
reported `first frame after 64ms`. The process was deliberately interrupted
after eight seconds by the non-interactive test harness.

On 2026-08-12, `CGO_ENABLED=0 go run . -smoke-duration=2s` selected the same
Vulkan adapter, reported a surface after 70 ms and a first frame after 71 ms,
requested a logical `800x450` resize, then reported `smoke quit` and `clean
shutdown`. The Wayland compositor did not emit a resize callback for that
request; GoGPU documents `RequestSize` as advisory on Wayland. This verifies a
framework-controlled teardown, not a user-initiated close, sustained frame
cadence, or device-loss recovery.

`GOOS=linux GOARCH=amd64`, `GOOS=windows GOARCH=amd64`, and
`GOOS=darwin GOARCH=arm64` compile checks passed on the same date. Windows and
macOS were not run here. The compile checks do not verify driver support,
window presentation, resize, device loss, or shutdown on those systems.

## compatibility and distribution findings

| Target | Current evidence | Required runtime dependencies / caveats |
| --- | --- | --- |
| Linux amd64 | One Vulkan adapter selection and first presented frame on Intel Iris Xe. | A graphical X11 or Wayland session and a usable Vulkan/GLES/software path supplied by the system. Driver and compositor coverage remains incomplete. |
| Windows amd64 | Cross-compiles only. | Win32 plus a supported Vulkan, D3D12, GLES, or software path; a real Windows run remains required. |
| macOS arm64 | Cross-compiles only. | Cocoa plus Metal or the software path; a real macOS run remains required. |

The pure-Go default does not bundle `wgpu-native`, but it loads native graphics
and window-system libraries at runtime. That lowers artifact packaging work
relative to the optional `rust` build tag, which uses `go-webgpu/webgpu` and a
separately distributed `wgpu-native v29` binary. It does not remove the need to
document operating-system graphics prerequisites and security updates for those
system libraries. The candidate's pre-v1 version, community-tested Linux/macOS
support, and unverified driver matrix are decision risks rather than reasons to
claim production support.

## lifecycle and fault validation

Resize and clean shutdown are manual test cases: resize the window repeatedly,
then close it, retaining the terminal output. For surface/device-loss testing,
run on a dedicated test machine, collect its GPU/driver details, and trigger a
display suspend/resume or the platform's documented GPU-reset procedure. Record
whether the application recreates the surface or returns a contextual error.

This repository has not independently induced a device loss. GoGPU exposes
surface lifecycle callbacks and documents `ErrSurfaceLost`/`ErrDeviceLost`, but
that is upstream behavior, not verified 72 behavior. Therefore this spike is
evidence for API shape, buildability, and one Linux presentation only; it is
not sufficient to select the dependency or to claim all desktop targets.

## sources

- [GoGPU README and platform matrix](https://github.com/gogpu/gogpu)
- [GoGPU release `v0.52.1`](https://github.com/gogpu/gogpu/releases/tag/v0.52.1)
- [go-webgpu `v0.5.5` documentation](https://pkg.go.dev/github.com/go-webgpu/webgpu@v0.5.5)
- [wgpu-native `v29.0.0.0` release](https://github.com/gfx-rs/wgpu-native/releases/tag/v29.0.0.0)
