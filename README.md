# Unpolished Bees

Unpolished Bees is a small, data-driven 2D game authoring application for
Lua/LÖVE projects. It keeps authored state as versioned JSON, so scenes,
tilemaps, tilesets, UI layouts, flow graphs, room templates, and generator
settings can be read, validated, edited, reviewed, and serialized again
without a hidden editor database.

It is also the JSON-only content workbench for the sibling ROAG project. It
may edit ROAG presentation and room-template JSON, but it never writes ROAG
Lua, saves, profiles, archive data, routes, or simulation state.

## Run

```console
love . --roag ../roag --project .
```

- `--roag` chooses the ROAG source checkout to open; it defaults to `../roag`.
- `--project` chooses a native Unpolished Bees project; it defaults to the
  current directory. A small runnable fixture lives in `examples/starter`.

The editor opens on **Project Launcher**. From there, or with `Cmd/Ctrl+O`,
choose either a project folder or its `unpolished_bees.project.json` manifest.
Recently opened projects are stored in the editor's own LÖVE settings
directory—not in any selected project. A manifest can also be dropped onto the
editor window to switch projects. The active project must validate before the
current project is replaced.

To run the headless suite:

```console
luajit tests/run.lua
```

The normal suite uses the small checked-in ROAG fixture under
`tests/fixtures/roag`; it never requires a sibling `../roag` checkout. To
perform an explicit read-only compatibility smoke check against a real ROAG
checkout, run:

```console
luajit tests/test_live_roag.lua ../roag
```

ROAG title actions whose identity/target pair is known to this Studio version
remain editable. Structurally valid newer actions load as preserved read-only
data, so publishing an unrelated presentation edit does not remove them.

## Current workspaces

- **Native Project** creates scenes, tilesets, maps, flow graphs, room
  primitives, and generators without asking authors to start from raw JSON.
  Its inspector edits serializable properties; its tree and graph controls add,
  delete, reparent, and connect primitives; tilemaps have selectable layers,
  sparse painting, pan/zoom, and image-backed tile selection. Native changes
  have per-asset bounded undo/redo, validation on save, dirty-change warnings,
  and reference-aware recoverable deletion (removal only unindexes the JSON
  file). Drop a PNG to copy it into `assets/` and make a managed tileset; drop
  Tiled JSON (`.json`/`.tmj`) to import an orthogonal sparse map.
- **Project Launcher** keeps project selection separate from game data. It
  uses a native folder chooser or JSON-manifest chooser when the host platform
  provides one, accepts a pasted path as a fallback, and protects unsaved
  Studio documents before changing projects.
- **ROAG Rooms** reads the dungeon and reactor JSON manifests, creates or
  recoverably removes manifest entries, paints a room template directly in
  memory, structurally validates it, and atomically writes only that selected
  `.room.json` file. It has per-room undo/redo, deterministic assembly preview,
  and corpus diagnostics explaining invalid rooms, duplicate identities, or
  missing connector patterns.
- **Art & Sprites**, **Scenes**, and **Title Flow** retain the existing ROAG
  presentation workflow: editable display copy, declared title transitions,
  art-pack selection, and sprite-role mapping. Every supported art pack now
  exposes its declared PNG source sheets in the Studio. ROAG 1-bit keeps live
  role-tile editing; other packs retain their deliberate fixed ROAG mappings,
  while any displayed source sheet can be copied into the open native project
  as an editable image-backed tileset.

## Native JSON contract

`core/project.lua` owns the canonical formats. The project manifest is
`unpolished_bees.project.json` (v2), with an explicit asset index. Native v1
assets are JSON objects with `format`, `version`, `type`, and semantic `id`:

```text
unpolished_bees.scene
unpolished_bees.tileset
unpolished_bees.tilemap
unpolished_bees.flow
unpolished_bees.room_template
unpolished_bees.generator
```

Tilemaps use sparse chunks, allowing fixed-size maps and infinite/chunked maps
to share one representation. Tilesets can reference linked assets or managed
imported copies by a safe relative path. The Tiled JSON importer intentionally
supports orthogonal tile layers first and reports unsupported layers or tile
transform flags instead of silently changing their meaning.

The runtime supports scene loading, basic retained UI drawing, event-driven
transitions, variables, arithmetic, and named Lua hooks. Lua hooks are
references such as `game.open_shop`; source code is never embedded in JSON.

## ROAG boundary

The ROAG mode reads/writes only these declared JSON areas:

```text
content/screens/legacy.json
content/presentation/flow.json
content/presentation/art_pack.json
sprite_editor/mappings.json
content/rooms/dungeon/*.room.json
content/rooms/reactor/*.room.json
```

Presentation publication retains the existing allow-list. Room publication is
one validated room file at a time. The application never opens a write handle
for `src/`, active saves, meta profiles, fallen archives, or other ROAG state.

## Editing safeguards

All authoring operations stay inside a project or ROAG JSON boundary. The
Studio uses native undo/redo snapshots for each edited document and asks before
discarding unsaved native, room, or presentation changes. Asset and room
deletion is intentionally manifest-only: the source JSON remains on disk for
recovery. Native asset removal also refuses to break declared scene instances,
flow scene targets, or tilemap tileset references.

The Studio can load an image once for a tileset preview and reuse it while
painting rather than decoding it every frame. PNG drop import copies bytes
atomically into the project before indexing the resulting tileset. This keeps
the project portable without treating external art paths as hidden state.

## Editor architecture

`ui/studio.lua` is the state and action façade: it coordinates LÖVE callbacks,
project/ROAG boundaries, undo state, and action dispatch. Reusable drawing
primitives live in `ui/theme.lua` and `ui/widgets.lua`; global menus and
navigation live in `ui/chrome.lua`; focused surfaces live under `ui/views/`.
Art-pack source metadata lives in `core/art_sources.lua`, separate from both
the editor and ROAG runtime code. New tools should add a focused view and
action family rather than grow the controller with another mixed-purpose
screen.

## Delivery direction

The foundational contracts, runtime preview, editable scene composition,
image-backed tileset rendering, visual flow authoring, Tiled import,
room-graph assembly, sparse tile painting, and deterministic noise/WFC preview
generation are implemented. Future work can grow the same formats with richer
node-specific inspectors, viewport tooling, and runtime graph diagnostics;
nothing in the current contract requires a ROAG Lua migration.

## Assets

`roag_assets/` contains source staging assets handed off from ROAG. The editor
UI uses the CC0 Kenney assets under `assets/kenney/`. See [LICENSES.md](LICENSES.md).
