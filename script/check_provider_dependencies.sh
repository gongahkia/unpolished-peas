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
if set(metadata) != {"schema_version", "allowed_licenses", "providers"} or metadata["schema_version"] != 2:
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
    if not isinstance(provider, dict) or set(provider) != {"name", "license", "source", "revision", "version", "headers", "artifacts"}:
        raise SystemExit("invalid provider entry")
    name = provider["name"]
    license_id = provider["license"]
    source_url = provider["source"]
    revision = provider["revision"]
    version = provider["version"]
    headers = provider["headers"]
    artifacts = provider["artifacts"]
    if not isinstance(name, str) or not re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,63}", name) or name in names:
        raise SystemExit("invalid provider name")
    names.add(name)
    if license_id not in allowed_licenses:
        raise SystemExit("provider license is not allowed")
    if not isinstance(source_url, str) or not re.fullmatch(r"https://[^\s]+", source_url):
        raise SystemExit("invalid provider provenance source")
    if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise SystemExit("provider provenance must use a pinned revision")
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise SystemExit("provider version must be pinned")
    if not isinstance(headers, dict) or set(headers) != {"url", "path", "sha256"}:
        raise SystemExit("invalid provider headers")
    header_url = headers["url"]
    header_path = pathlib.PurePosixPath(headers["path"]) if isinstance(headers["path"], str) else None
    header_checksum = headers["sha256"]
    if not isinstance(header_url, str) or not re.fullmatch(r"https://[^\s]+", header_url) or f"/{revision}/" not in header_url:
        raise SystemExit("provider headers must use the pinned revision")
    if header_path is None or header_path.is_absolute() or ".." in header_path.parts or header_path == pathlib.PurePosixPath("."):
        raise SystemExit("invalid provider header path")
    if not isinstance(header_checksum, str) or not re.fullmatch(r"[0-9a-f]{64}", header_checksum):
        raise SystemExit("invalid provider header checksum")
    if not isinstance(artifacts, list) or not artifacts:
        raise SystemExit("provider must define artifacts")
    targets = set()
    for artifact in artifacts:
        if not isinstance(artifact, dict) or set(artifact) != {"target", "url", "sha256", "format", "library"}:
            raise SystemExit("invalid provider artifact")
        target = artifact["target"]
        url = artifact["url"]
        checksum = artifact["sha256"]
        archive_format = artifact["format"]
        library_path = pathlib.PurePosixPath(artifact["library"]) if isinstance(artifact["library"], str) else None
        if not isinstance(target, str) or not re.fullmatch(r"(?:x86_64|aarch64)-(?:linux|windows)", target) or target in targets:
            raise SystemExit("invalid provider target")
        targets.add(target)
        if not isinstance(url, str) or not re.fullmatch(r"https://[^\s]+", url) or version not in url:
            raise SystemExit("provider artifact URL must pin the version")
        if not isinstance(checksum, str) or not re.fullmatch(r"[0-9a-f]{64}", checksum):
            raise SystemExit("invalid provider artifact checksum")
        if archive_format not in {"deb", "zip"} or not url.split("?", 1)[0].endswith(".deb" if archive_format == "deb" else ".nupkg"):
            raise SystemExit("invalid provider artifact format")
        if library_path is None or library_path.is_absolute() or ".." in library_path.parts or library_path == pathlib.PurePosixPath("."):
            raise SystemExit("invalid provider library path")
        target_os = target.rsplit("-", 1)[1]
        if target_os == "linux" and (archive_format != "deb" or not library_path.name.startswith("libmsquic.so.")):
            raise SystemExit("invalid Linux provider artifact")
        if target_os == "windows" and (archive_format != "zip" or library_path.name != "msquic.dll"):
            raise SystemExit("invalid Windows provider artifact")
PY
