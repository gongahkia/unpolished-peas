#!/usr/bin/env python3
import json
from pathlib import Path

required_names = {
    "stb_image",
    "stb_vorbis",
    "stb_truetype",
    "Basic",
    "Source Sans 3",
    "SDL3",
    "SDL_linux_deps",
}
required_pins = {
    "SDL3": ("0.4.1+3.4.2", "701da66369221654c501e9661c648dd3aa2cfe52"),
    "SDL_linux_deps": ("fd349940b9dbaa0f221703b05df826d745d7ce2a", "fd349940b9dbaa0f221703b05df826d745d7ce2a"),
}
notices = json.loads(Path("THIRD_PARTY_NOTICES.json").read_text())
manifest = Path("build.zig.zon").read_text()

if not isinstance(notices, list):
    raise SystemExit("notices must be a JSON array")
if not all(isinstance(notice, dict) for notice in notices):
    raise SystemExit("each notice must be an object")
for notice in notices:
    if not all(isinstance(notice.get(key), str) and notice[key] for key in ("name", "version", "source", "license", "usage")):
        raise SystemExit("each notice requires name, version, source, license, and usage")
names = [notice["name"] for notice in notices]
if len(set(names)) != len(names):
    raise SystemExit("notice names must be unique")
if set(names) != required_names:
    raise SystemExit("notices must list every bundled, fixture, or fetched dependency")
by_name = {notice["name"]: notice for notice in notices}
direct_manifest_dependencies = {"SDL3", "SDL_linux_deps"}
for name, (version, pin) in required_pins.items():
    notice = by_name[name]
    if notice["version"] != version or pin not in notice["source"]:
        raise SystemExit(f"notice does not match pinned dependency: {name}")
    if name in direct_manifest_dependencies and pin not in manifest:
        raise SystemExit(f"manifest does not contain pinned dependency: {name}")
