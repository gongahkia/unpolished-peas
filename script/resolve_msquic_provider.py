#!/usr/bin/env python3
import argparse
import hashlib
import io
import json
import os
import pathlib
import platform
import re
import stat
import sys
import tarfile
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile

MAX_DOWNLOAD_BYTES = 64 * 1024 * 1024
TARGET_PATTERN = re.compile(r"(?:x86_64|aarch64)-(?:linux|windows|macos)")
QUOTED_HEADER_INCLUDE = re.compile(rb'^\s*#\s*include\s+"([^"\\]+)"', re.MULTILINE)


class ResolutionError(Exception):
    pass


def safe_path(value: object) -> pathlib.PurePosixPath:
    if not isinstance(value, str):
        raise ResolutionError("invalid manifest path")
    path = pathlib.PurePosixPath(value)
    if not value or path.is_absolute() or ".." in path.parts or path == pathlib.PurePosixPath("."):
        raise ResolutionError("invalid manifest path")
    return path


def load_provider(manifest_path: pathlib.Path) -> dict:
    try:
        metadata = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ResolutionError(f"invalid provider manifest: {error}") from error
    if metadata.get("schema_version") != 3 or not isinstance(metadata.get("providers"), list):
        raise ResolutionError("unsupported provider manifest")
    providers = [item for item in metadata["providers"] if isinstance(item, dict) and item.get("name") == "msquic"]
    if len(providers) != 1:
        raise ResolutionError("missing MsQuic provider")
    provider = providers[0]
    if set(provider) != {"name", "license", "source", "revision", "version", "headers", "artifacts"}:
        raise ResolutionError("invalid MsQuic provider")
    if provider["license"] != "MIT" or not re.fullmatch(r"[0-9a-f]{40}", provider["revision"]):
        raise ResolutionError("invalid MsQuic provenance")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", provider["version"]):
        raise ResolutionError("invalid MsQuic version")
    headers = provider["headers"]
    if not isinstance(headers, list) or not headers:
        raise ResolutionError("invalid MsQuic headers")
    header_paths = set()
    for header in headers:
        if not isinstance(header, dict) or set(header) != {"url", "path", "sha256"}:
            raise ResolutionError("invalid MsQuic header")
        if not isinstance(header["url"], str) or f"/{provider['revision']}/" not in header["url"]:
            raise ResolutionError("MsQuic headers are not revision pinned")
        path = safe_path(header["path"])
        if path in header_paths:
            raise ResolutionError("duplicate MsQuic header path")
        header_paths.add(path)
        require_checksum(header["sha256"])
    if not isinstance(provider["artifacts"], list) or not provider["artifacts"]:
        raise ResolutionError("missing MsQuic artifacts")
    targets = set()
    for artifact in provider["artifacts"]:
        if not isinstance(artifact, dict) or set(artifact) != {"target", "url", "sha256", "format", "library"}:
            raise ResolutionError("invalid MsQuic artifact")
        target = artifact["target"]
        if not isinstance(target, str) or not TARGET_PATTERN.fullmatch(target) or target in targets:
            raise ResolutionError("invalid MsQuic target")
        targets.add(target)
        if not isinstance(artifact["url"], str) or not artifact["url"].startswith("https://") or provider["version"] not in artifact["url"]:
            raise ResolutionError("MsQuic artifact is not version pinned")
        require_checksum(artifact["sha256"])
        if artifact["format"] not in {"deb", "zip"}:
            raise ResolutionError("invalid MsQuic archive format")
        safe_path(artifact["library"])
    return provider


def require_checksum(value: object) -> None:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        raise ResolutionError("invalid SHA-256 checksum")


def target_for_host() -> str:
    architecture = platform.machine().lower()
    arch = {"amd64": "x86_64", "x86_64": "x86_64", "arm64": "aarch64", "aarch64": "aarch64"}.get(architecture)
    operating_system = {"Linux": "linux", "Windows": "windows", "Darwin": "macos"}.get(platform.system())
    if arch is None or operating_system is None:
        raise ResolutionError("unsupported host target")
    return f"{arch}-{operating_system}"


def select_artifact(provider: dict, target: str) -> dict:
    if not TARGET_PATTERN.fullmatch(target):
        raise ResolutionError("invalid requested target")
    artifacts = [artifact for artifact in provider["artifacts"] if artifact["target"] == target]
    if len(artifacts) != 1:
        raise ResolutionError(f"unsupported MsQuic target: {target}")
    return artifacts[0]


def download(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "minna-san-msquic-provider/1"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            if urllib.parse.urlparse(response.geturl()).scheme != "https":
                raise ResolutionError("provider download redirected outside HTTPS")
            content_length = response.headers.get("Content-Length")
            if content_length is not None and (not content_length.isdigit() or int(content_length) > MAX_DOWNLOAD_BYTES):
                raise ResolutionError("provider download exceeds size limit")
            chunks = []
            total = 0
            while True:
                chunk = response.read(64 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                if total > MAX_DOWNLOAD_BYTES:
                    raise ResolutionError("provider download exceeds size limit")
                chunks.append(chunk)
    except urllib.error.URLError as error:
        raise ResolutionError(f"provider download failed: {error.reason}") from error
    return b"".join(chunks)


def verified_download(url: str, checksum: str) -> bytes:
    payload = download(url)
    actual = hashlib.sha256(payload).hexdigest()
    if actual != checksum:
        raise ResolutionError("provider artifact checksum mismatch")
    return payload


def validate_header_closure(headers: list[tuple[pathlib.PurePosixPath, bytes]]) -> None:
    paths = {path for path, _ in headers}
    for path, payload in headers:
        for match in QUOTED_HEADER_INCLUDE.finditer(payload):
            included = match.group(1).decode("ascii", "strict")
            included_path = safe_path(included)
            if path.parent / included_path not in paths:
                raise ResolutionError(f"missing MsQuic transitive header: {included}")


def extract_zip(payload: bytes, member_path: str) -> bytes:
    expected = safe_path(member_path).as_posix()
    try:
        with zipfile.ZipFile(io.BytesIO(payload)) as archive:
            info = archive.getinfo(expected)
            mode = info.external_attr >> 16
            if stat.S_ISLNK(mode) or info.is_dir():
                raise ResolutionError("invalid provider archive member")
            return archive.read(info)
    except (KeyError, zipfile.BadZipFile) as error:
        raise ResolutionError("provider archive member is missing") from error


def extract_deb(payload: bytes, member_path: str) -> bytes:
    if not payload.startswith(b"!<arch>\n"):
        raise ResolutionError("invalid Debian archive")
    index = 8
    data_archive = None
    while index + 60 <= len(payload):
        header = payload[index : index + 60]
        name = header[:16].decode("ascii", "strict").strip().rstrip("/")
        try:
            size = int(header[48:58].decode("ascii", "strict").strip())
        except ValueError as error:
            raise ResolutionError("invalid Debian archive member") from error
        if header[58:60] != b"`\n" or size < 0 or index + 60 + size > len(payload):
            raise ResolutionError("invalid Debian archive member")
        body_start = index + 60
        body_end = body_start + size
        if name == "data.tar.xz":
            if data_archive is not None:
                raise ResolutionError("duplicate Debian data archive")
            data_archive = payload[body_start:body_end]
        index = body_end + (size % 2)
    if data_archive is None or index != len(payload):
        raise ResolutionError("missing Debian data archive")
    expected = safe_path(member_path).as_posix()
    try:
        with tarfile.open(fileobj=io.BytesIO(data_archive), mode="r:xz") as archive:
            members = [member for member in archive.getmembers() if member.name.lstrip("./") == expected]
            if len(members) != 1 or not members[0].isfile():
                raise ResolutionError("provider archive member is missing")
            extracted = archive.extractfile(members[0])
            if extracted is None:
                raise ResolutionError("provider archive member is unreadable")
            return extracted.read()
    except tarfile.TarError as error:
        raise ResolutionError("invalid Debian data archive") from error


def write_atomic(path: pathlib.Path, payload: bytes, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def resolve(provider: dict, target: str, output: pathlib.Path) -> pathlib.Path:
    artifact = select_artifact(provider, target)
    library_archive = verified_download(artifact["url"], artifact["sha256"])
    headers = [(safe_path(header["path"]), verified_download(header["url"], header["sha256"])) for header in provider["headers"]]
    validate_header_closure(headers)
    library = extract_deb(library_archive, artifact["library"]) if artifact["format"] == "deb" else extract_zip(library_archive, artifact["library"])
    if not library:
        raise ResolutionError("provider library is empty")
    destination = output / target
    library_path = destination / "lib" / pathlib.PurePosixPath(artifact["library"]).name
    metadata_path = destination / "manifest.json"
    metadata = {
        "headers": [path.as_posix() for path, _ in headers],
        "library": library_path.relative_to(destination).as_posix(),
        "name": provider["name"],
        "revision": provider["revision"],
        "target": target,
        "version": provider["version"],
    }
    for path, header in headers:
        write_atomic(destination / path, header, 0o644)
    write_atomic(library_path, library, 0o755)
    write_atomic(metadata_path, (json.dumps(metadata, sort_keys=True, separators=(",", ":")) + "\n").encode(), 0o644)
    return destination


def main() -> None:
    root = pathlib.Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description="resolve the pinned optional MsQuic provider")
    parser.add_argument("--manifest", type=pathlib.Path, default=root / "providers" / "manifest.json")
    parser.add_argument("--target")
    parser.add_argument("--output", type=pathlib.Path, default=root / "zig-out" / "msquic")
    arguments = parser.parse_args()
    target = arguments.target or target_for_host()
    try:
        provider = load_provider(arguments.manifest)
        destination = resolve(provider, target, arguments.output)
    except (OSError, ResolutionError) as error:
        raise SystemExit(f"error: {error}") from error
    print(f"resolved {provider['name']} {provider['version']} for {target}: {destination}")


if __name__ == "__main__":
    main()
