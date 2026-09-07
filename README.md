# PX-240C Color Development Unit

PX-240C is a private, proprietary fantasy-console project presented as a technically unusual,
commercially unsuccessful colour handheld from 1999. The finished alpha will provide a complete
PXCL/1 compiler, deterministic runtime, 240x144 integrated studio, native Linux workflow, and three
original pack-in cartridges.

Made by @gongahkia. All rights reserved.

## Current status

Active alpha implementation. The typed PXCL compiler and project linker, deterministic `.pxc`,
native CLI/LSP, browser persistence, runtime/worker, indexed graphics, four-port input, and
synthesizer/tracker core are implemented; the integrated product surfaces are not yet complete. See
[`docs/PROGRESS.md`](docs/PROGRESS.md) for verified state.

## Development

Requirements: Linux, Node.js 22.22 or newer, pnpm 10.32.1, and Rust 1.98 with Clippy, rustfmt, and the
`wasm32-unknown-unknown` target.

```sh
make setup
make check
pnpm dev
```

No cloud account, backend, deployment, or existing fantasy-console compatibility layer is part of
the alpha.
