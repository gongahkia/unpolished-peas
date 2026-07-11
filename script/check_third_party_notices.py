#!/usr/bin/env python3
import json
from pathlib import Path

required_names = {"stb_image", "stb_vorbis", "SDL3", "allyourcodebase/box2d", "Box2D"}
notices = json.loads(Path("THIRD_PARTY_NOTICES.json").read_text())

if not isinstance(notices, list):
    raise SystemExit("notices must be a JSON array")
names = {notice.get("name") for notice in notices}
if names != required_names:
    raise SystemExit("notices must list every bundled or fetched dependency")
for notice in notices:
    if not all(isinstance(notice.get(key), str) and notice[key] for key in ("name", "version", "source", "license", "usage")):
        raise SystemExit("each notice requires name, version, source, license, and usage")
