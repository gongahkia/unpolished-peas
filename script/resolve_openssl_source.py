#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.parse
import urllib.request

MAX_DOWNLOAD_BYTES = 128 * 1024 * 1024
EXPECTED_KEYS = {"schema_version", "name", "license", "version", "source"}
EXPECTED_SOURCE_KEYS = {"url", "sha256", "signature_url", "signature_sha256", "public_keys_url", "public_keys_sha256"}
OUTPUT_MARKER = ".minna-san-openssl-provider"


class ResolutionError(Exception):
    pass


def checksum(value: object) -> None:
    if not isinstance(value, str) or len(value) != 64 or any(byte not in "0123456789abcdef" for byte in value):
        raise ResolutionError("invalid SHA-256 checksum")


def load(path: pathlib.Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ResolutionError(f"invalid OpenSSL source manifest: {error}") from error
    if not isinstance(value, dict) or set(value) != EXPECTED_KEYS or value["schema_version"] != 1 or value["name"] != "openssl" or value["license"] != "Apache-2.0":
        raise ResolutionError("invalid OpenSSL source manifest")
    if not isinstance(value["version"], str) or value["version"].count(".") != 2 or not isinstance(value["source"], dict) or set(value["source"]) != EXPECTED_SOURCE_KEYS:
        raise ResolutionError("invalid OpenSSL source release")
    for name, item in value["source"].items():
        if name.endswith("url"):
            if not isinstance(item, str) or not item.startswith("https://") or (name != "public_keys_url" and value["version"] not in item):
                raise ResolutionError("OpenSSL source URL is not pinned")
        else:
            checksum(item)
    return value


def verify_manifest_lock(manifest: pathlib.Path, lock: pathlib.Path) -> None:
    try:
        locked = lock.read_text(encoding="utf-8").strip()
    except OSError as error:
        raise ResolutionError(f"invalid OpenSSL source lock: {error}") from error
    checksum(locked)
    if hashlib.sha256(manifest.read_bytes()).hexdigest() != locked:
        raise ResolutionError("OpenSSL source manifest checksum mismatch")


def download(url: str, expected: str) -> bytes:
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "minna-san-openssl-provider/1"}), timeout=60) as response:
            if urllib.parse.urlparse(response.geturl()).scheme != "https":
                raise ResolutionError("OpenSSL download redirected outside HTTPS")
            content_length = response.headers.get("Content-Length")
            if content_length is not None and (not content_length.isdigit() or int(content_length) > MAX_DOWNLOAD_BYTES):
                raise ResolutionError("OpenSSL download exceeds size limit")
            payload = response.read(MAX_DOWNLOAD_BYTES + 1)
    except urllib.error.URLError as error:
        raise ResolutionError(f"OpenSSL download failed: {error.reason}") from error
    if len(payload) > MAX_DOWNLOAD_BYTES or hashlib.sha256(payload).hexdigest() != expected:
        raise ResolutionError("OpenSSL download checksum mismatch")
    return payload


def target_name() -> str:
    system = platform.system()
    machine = platform.machine().lower()
    values = {
        ("Linux", "x86_64"): "linux-x86_64",
        ("Linux", "amd64"): "linux-x86_64",
        ("Linux", "aarch64"): "linux-aarch64",
        ("Linux", "arm64"): "linux-aarch64",
        ("Darwin", "x86_64"): "darwin64-x86_64-cc",
        ("Darwin", "arm64"): "darwin64-arm64-cc",
        ("Darwin", "aarch64"): "darwin64-arm64-cc",
    }
    try:
        return values[(system, machine)]
    except KeyError as error:
        raise ResolutionError("unsupported OpenSSL build host") from error


def extract(source: bytes, destination: pathlib.Path) -> pathlib.Path:
    destination.mkdir()
    with tarfile.open(fileobj=__import__("io").BytesIO(source), mode="r:gz") as archive:
        members = archive.getmembers()
        if not members:
            raise ResolutionError("empty OpenSSL source archive")
        roots = {pathlib.PurePosixPath(member.name).parts[0] for member in members if member.name and not pathlib.PurePosixPath(member.name).is_absolute()}
        if len(roots) != 1:
            raise ResolutionError("invalid OpenSSL source archive layout")
        for member in members:
            path = pathlib.PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or member.issym() or member.islnk() or member.isdev():
                raise ResolutionError("unsafe OpenSSL source archive")
        archive.extractall(destination, members)
        return destination / next(iter(roots))


def verify_signature(source: bytes, signature: bytes, public_keys: bytes, work: pathlib.Path) -> None:
    source_path = work / "openssl.tar.gz"
    signature_path = work / "openssl.tar.gz.asc"
    keys_path = work / "pubkeys.asc"
    source_path.write_bytes(source)
    signature_path.write_bytes(signature)
    keys_path.write_bytes(public_keys)
    home = work / "gnupg"
    home.mkdir(mode=0o700)
    try:
        subprocess.run(["gpg", "--batch", "--homedir", str(home), "--import", str(keys_path)], check=True, capture_output=True)
        subprocess.run(["gpg", "--batch", "--homedir", str(home), "--verify", str(signature_path), str(source_path)], check=True, capture_output=True)
    except (OSError, subprocess.CalledProcessError) as error:
        raise ResolutionError("OpenSSL release signature verification failed") from error


def resolve(metadata: dict, output: pathlib.Path) -> pathlib.Path:
    source = metadata["source"]
    with tempfile.TemporaryDirectory(prefix="minna-san-openssl-") as temporary:
        work = pathlib.Path(temporary)
        archive = download(source["url"], source["sha256"])
        signature = download(source["signature_url"], source["signature_sha256"])
        public_keys = download(source["public_keys_url"], source["public_keys_sha256"])
        verify_signature(archive, signature, public_keys, work)
        source_root = extract(archive, work / "source")
        build = ["./Configure", target_name(), "no-shared", "no-tests", "no-apps"]
        try:
            subprocess.run(build, cwd=source_root, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["make", "-j4", "build_libs"], cwd=source_root, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except (OSError, subprocess.CalledProcessError) as error:
            raise ResolutionError("OpenSSL source build failed") from error
        temporary_output = work / "output"
        include = temporary_output / "include"
        library = temporary_output / "lib"
        shutil.copytree(source_root / "include" / "openssl", include / "openssl")
        library.mkdir(parents=True)
        for name in ("libssl.a", "libcrypto.a"):
            source_library = source_root / name
            if not source_library.is_file():
                raise ResolutionError("OpenSSL build did not produce static libraries")
            shutil.copy2(source_library, library / name)
        (temporary_output / "manifest.json").write_text(json.dumps({"name": metadata["name"], "version": metadata["version"], "target": target_name()}, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
        (temporary_output / OUTPUT_MARKER).write_text(f"openssl {metadata['version']}\n", encoding="utf-8")
        output.parent.mkdir(parents=True, exist_ok=True)
        if output.exists():
            try:
                marker = (output / OUTPUT_MARKER).read_text(encoding="utf-8")
            except OSError as error:
                raise ResolutionError("refusing to replace an unowned OpenSSL output directory") from error
            if marker != f"openssl {metadata['version']}\n":
                raise ResolutionError("refusing to replace an unexpected OpenSSL output directory")
            shutil.rmtree(output)
        shutil.copytree(temporary_output, output)
    return output


def main() -> None:
    root = pathlib.Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description="resolve a signed pinned OpenSSL source release")
    parser.add_argument("--manifest", type=pathlib.Path, default=root / "providers" / "openssl-source.json")
    parser.add_argument("--lock", type=pathlib.Path, default=root / "providers" / "openssl-source.sha256")
    parser.add_argument("--output", type=pathlib.Path, default=root / "zig-out" / "openssl")
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    try:
        verify_manifest_lock(arguments.manifest, arguments.lock)
        metadata = load(arguments.manifest)
        if arguments.check:
            return
        destination = resolve(metadata, arguments.output)
    except (OSError, ResolutionError) as error:
        raise SystemExit(f"error: {error}") from error
    print(f"resolved {metadata['name']} {metadata['version']} for {target_name()}: {destination}")


if __name__ == "__main__":
    main()
