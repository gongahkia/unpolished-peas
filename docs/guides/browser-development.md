# Browser development workflow

`zig build web` remains the production browser build: it writes a normal
static directory under `zig-out/web` with no file watcher, reload connection,
or source-tree dependency. During browser game iteration, use the separate
development step from a standalone Peas project instead:

```sh
zig build dev-web
```

It performs an initial `zig build web`, starts a loopback-only server, and
prints a URL such as `http://127.0.0.1:8000/`. Open that URL once. The process
then watches the project's authored inputs, rebuilds through the same `web`
step, and fully reloads the page only after a successful rebuild.

This is developer tooling, not a game API. `GameProtocol`, replays, fixed
steps, and the browser runtime do not know that the watcher exists.

## What changes trigger a build

The watcher polls a deliberately small project tree every 200 ms by default.
It notices Zig/build files plus common authored image, font, audio, shader,
and JSON inputs. It ignores `.git`, Zig caches, `zig-out`, and `node_modules`,
so generated output cannot cause a rebuild loop. Several rapid edits coalesce
into one build; at most one Zig build runs at a time.

Choose another local port explicitly when `8000` is already in use:

```sh
zig build dev-web -Ddev-web-port=8010
```

The server binds to `127.0.0.1`, not the network. It is intentionally a local
developer tool rather than a LAN server or a general proxy.

## Broken edits are safe

The server copies a completed successful browser output into a private
development snapshot before telling the page to reload. If an edit produces a
compiler error, the terminal shows the normal Zig diagnostic, the watcher
stays alive, and the previously successful game remains served. Save a valid
edit and it retries automatically.

The first build follows the same rule: if it is broken, the server remains up
and waits for a later edit rather than exiting. It returns a short `503` page
until a successful output exists.

## Reload semantics

The development server injects a tiny local Server-Sent Events client while
serving `index.html`. A successful build sends one reload event; the browser
uses a normal `location.reload()`. There is no Wasm hot-module replacement,
live game-state migration, or source scanner.

This means the simulation starts again after every successful rebuild.
Browser `localStorage` remains intact, so ordinary `SaveStore` data persists
across the refresh. Browser audio may need another permitted user interaction
after a full page reload; that is browser autoplay policy, not a separate Peas
audio mode.

Native and browser iteration deliberately differ: native developer mode can
replace registered image/font resources in place; browser development rebuilds
the static bundle and reloads the whole page. See [developer asset
reload](developer-asset-reload.md) for the native path.

## Production and WSL

Use the ordinary command to make a packageable browser directory:

```sh
zig build web
```

It contains no reload client, watch metadata, server endpoint, or dependency
on the project source tree. Serve that output with any normal static host.

Under WSL2, a browser running on Windows can normally open the loopback URL
printed by `dev-web`. This is useful local development evidence, not a claim
about a production Linux or browser deployment environment. Press `Ctrl-C` to
stop the server and any active child build.
