#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
manifest="${PROVIDER_MANIFEST:-$root/providers/manifest.json}"
lock="${PROVIDER_MANIFEST_LOCK:-$root/providers/manifest.sha256}"

python3 - "$manifest" "$lock" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

manifest_path = pathlib.Path(sys.argv[1])
lock_path = pathlib.Path(sys.argv[2])
try:
    source = manifest_path.read_bytes()
    locked = lock_path.read_text(encoding="utf-8").strip()
    metadata = json.loads(source)
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid provider manifest: {error}")
if not re.fullmatch(r"[0-9a-f]{64}", locked) or locked != hashlib.sha256(source).hexdigest():
    raise SystemExit("provider manifest checksum mismatch")
if set(metadata) != {"schema_version", "allowed_licenses", "providers"} or metadata["schema_version"] != 1:
    raise SystemExit("invalid provider manifest schema")
known_licenses = {"Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "ISC", "MIT", "Zlib"}
allowed_licenses = metadata["allowed_licenses"]
if not isinstance(allowed_licenses, list) or not allowed_licenses or len(set(allowed_licenses)) != len(allowed_licenses) or not set(allowed_licenses) <= known_licenses:
    raise SystemExit("invalid provider license allowlist")
providers = metadata["providers"]
if not isinstance(providers, list):
    raise SystemExit("invalid provider list")
names = set()
for provider in providers:
    if not isinstance(provider, dict) or set(provider) != {"name", "license", "source", "revision", "artifact", "sha256"}:
        raise SystemExit("invalid provider entry")
    name = provider["name"]
    license_id = provider["license"]
    source_url = provider["source"]
    revision = provider["revision"]
    artifact = provider["artifact"]
    checksum = provider["sha256"]
    if not isinstance(name, str) or not re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,63}", name) or name in names:
        raise SystemExit("invalid provider name")
    names.add(name)
    if license_id not in allowed_licenses:
        raise SystemExit("provider license is not allowed")
    if not isinstance(source_url, str) or not re.fullmatch(r"https://[^\s]+", source_url):
        raise SystemExit("invalid provider provenance source")
    if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise SystemExit("provider provenance must use a pinned revision")
    artifact_path = pathlib.PurePosixPath(artifact) if isinstance(artifact, str) else None
    if artifact_path is None or artifact_path.is_absolute() or ".." in artifact_path.parts or artifact_path == pathlib.PurePosixPath("."):
        raise SystemExit("invalid provider artifact path")
    if not isinstance(checksum, str) or not re.fullmatch(r"[0-9a-f]{64}", checksum):
        raise SystemExit("invalid provider artifact checksum")
    try:
        actual = hashlib.sha256((manifest_path.parent / artifact_path).read_bytes()).hexdigest()
    except OSError as error:
        raise SystemExit(f"missing provider artifact: {error}")
    if actual != checksum:
        raise SystemExit("provider artifact checksum mismatch")
PY
