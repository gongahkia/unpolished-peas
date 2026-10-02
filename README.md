# Unpolished Bees

Unpolished Bees is a standalone LÖVE authoring application for ROAG’s
presentation layer. It is deliberately **not** a second game runtime and not a
premature claim to be a general-purpose engine: ROAG’s simulation, saves,
routes, body system, and persistence stay in ROAG.

It owns a practical, editable presentation seam:

- choose a declared art pack;
- map ROAG’s stable rendering roles to the original 49×22 sheet;
- edit visible scene labels, subtitles, footer copy, layout tokens, and accent
  tokens;
- reorder presentation scenes for authoring/inspection;
- edit and order the title actions that ROAG explicitly supports;
- validate then atomically publish only allow-listed presentation files.

The separation is intentional. Mature 2D tools commonly separate reusable
scenes/resources from runtime behavior and let room/layer tools compose
content. For example, Godot documents scenes and nodes as reusable composing
units, while GameMaker’s room editor organizes asset layers. Unpolished Bees
keeps that useful authoring boundary without pretending that ROAG needs a new
scene graph, scripting VM, physics engine, or a second save system.

## Run

From this sibling repository:

```console
love . --roag ../roag
```

`--roag` may be an absolute path if the checkout is elsewhere. The default is
`../roag`. The tool reads and writes only:

```text
content/screens/legacy.json
content/presentation/flow.json
content/presentation/art_pack.json
sprite_editor/mappings.json
```

It never writes `active_run.json`, `meta_profile.json`,
`fallen_characters.json`, simulation code, route content, or body content.
Click **Publish** (or press Cmd/Ctrl+S) to validate and atomically apply the
four data files. Refocus or restart ROAG to load the saved presentation data.

## Workflow

1. Use **Art & Sprites** to select one of ROAG’s declared packs. Individual
   sprite mapping is purposely available only for the original ROAG 1-bit
   sheet, because the other packs carry complete authored starter maps.
2. Use **Scenes** to edit visible text and visual tokens. Its list ordering is
   authoring/inspection order, not a way to bypass game state.
3. Use **Title Flow** to reorder/edit New Run, Continue, Research, and Fallen.
   Each still resolves to ROAG’s fixed safe transition; the tool does not run
   arbitrary callbacks or Lua snippets.
4. Use ROAG’s existing Room Workbench for level templates and Generation
   Inspector for world verification. They remain specialized tools because
   they consume validated ROAG geometry rather than generic presentation data.

## Asset handoff

`roag_assets/` holds a source staging copy of the existing ROAG sprite packs,
including their attribution material. `assets/kenney/` contains the CC0 UI and
cursor packs that make this editor self-contained. See [LICENSES.md](LICENSES.md).

The ROAG-side `luajit tools/export_unpolished_bees.lua <fresh-directory>`
command can also make a safe presentation-only handoff snapshot. It refuses to
overwrite an existing directory.
