# Neon Siege — current guide

This guide supersedes the historical README instructions where controls or
verification differ. The bounded work is described in [POLISH_PLAN.md](POLISH_PLAN.md).

From this checkout:

```sh
cd dogfood/neon-siege
zig build run -Doptimize=ReleaseFast
zig build test
zig build package web
```

Serve zig-out/web over loopback HTTP. The common bootstrap loads
unpolished-peas.wasm; package the complete web directory and font notice.
Current polish and full verification are in progress; the plan does not claim
those acceptance criteria already pass.
