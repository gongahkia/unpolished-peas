# Developer-tools environment reference

Peas developer tooling is local and opt-in. It is separate from game state,
replay input, `SaveStore`, and release package contents. This page is the
authoritative reference for game-author environment controls; CI-only renderer
and browser variables remain documented in [CI](ci.md) and the [capability
matrix](capabilities.md).

## Runtime and authored assets

| Variable | Scope and default | Release relevance |
| --- | --- | --- |
| `UP_ASSET_ROOT` | Explicit runtime `AssetStore` root. If unset, embedding-only games may start without a runtime asset directory. An explicitly invalid root is an error. | Runtime-loaded assets only; it is not a source-asset watcher. |
| `UP_DEVELOPER_TOOLS` | Native SDL developer tools. Debug hosts enable them by default; set `1` to opt in explicitly or `0` to suppress them. | Ignored by normal browser builds and not needed by packages. |
| `UP_DEVELOPER_OVERLAY` | With developer tools enabled, `0` starts the compact overlay hidden; otherwise it starts visible. | Developer display only. |
| `UP_DEVELOPER_INSPECTOR` | With developer tools enabled, `1` opens the detailed native inspector. | Developer display only. |
| `UP_DEVELOPER_DIAGNOSTICS_DUMP` | With developer tools enabled, `1` writes one local JSON diagnostics snapshot on host exit. | Local non-versioned diagnostic output only. |
| `UP_DEVELOPER_ASSET_ROOT` | Explicit absolute source directory for registered native image/font reloads. Relative paths, escapes, and an absent root never fall back to the current directory. | Native developer-only; release and browser builds continue using embedded bytes. |

`UP_ASSET_ROOT` and `UP_DEVELOPER_ASSET_ROOT` are deliberately different.
The first is a configured runtime package asset location; the second is an
explicit development source directory used only by registered image/font
resources. Neither changes a fully embedded release game's source of truth.

## Diagnostics artifacts and timing

| Variable | Scope |
| --- | --- |
| `UP_DIAGNOSTICS_ROOT` | Optional root for test/renderer diagnostic artifacts. It is intended for local investigation and CI artifact collection, not normal game behavior. |
| `UP_NATIVE_TIMING_REPORT` | Opt-in native timing report used while investigating host presentation behavior. Host-present time is not completed GPU timing. |

The remaining `UP_RENDERER_*`, `UP_BROWSER`, `UP_SAFARI_*`, and release/test
variables are test or CI controls rather than supported game-author settings.
Do not put them in a shipped game's launch environment.

## Browser iteration prerequisite

`zig build dev-web` uses the repository-shipped `dev_server.py` through the
`python3` command. Install Python 3 with its standard library on the
development machine. This requirement applies only to local serving/watch
workflows; `zig build web` produces ordinary static output with no Python,
watcher, reload client, or source-tree dependency at runtime.

For commands and reload behavior, see [browser development](browser-development.md).
For native image/font replacement, see [developer asset reload](developer-asset-reload.md).
For the overlay and local diagnostic dump, see [developer diagnostics](developer-diagnostics.md).
