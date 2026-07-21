#!/usr/bin/env python3
import hashlib
import io
import pathlib
import sys
import tarfile
import tempfile
import zipfile

import resolve_msquic_provider as resolver


def ar_member(name: str, payload: bytes) -> bytes:
    header = f"{name + '/':<16}{0:<12}{0:<6}{0:<6}{0:<8}{len(payload):<10}`\n".encode("ascii")
    return header + payload + (b"\n" if len(payload) % 2 else b"")


def deb(payload: bytes) -> bytes:
    return b"!<arch>\n" + ar_member("debian-binary", b"2.0\n") + ar_member("data.tar.xz", payload)


def data_tar(path: str, payload: bytes) -> bytes:
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:xz") as archive:
        info = tarfile.TarInfo(f"./{path}")
        info.size = len(payload)
        archive.addfile(info, io.BytesIO(payload))
    return output.getvalue()


def require(value: bool) -> None:
    if not value:
        raise AssertionError


def main() -> None:
    root = pathlib.Path(__file__).resolve().parents[1]
    provider = resolver.load_provider(root / "providers" / "manifest.json")
    require(resolver.select_artifact(provider, "x86_64-linux")["format"] == "deb")
    require(resolver.select_artifact(provider, "x86_64-windows")["format"] == "zip")
    try:
        resolver.select_artifact(provider, "aarch64-macos")
    except resolver.ResolutionError:
        pass
    else:
        raise AssertionError
    require(resolver.extract_deb(deb(data_tar("usr/lib/libmsquic.so.2.5.9", b"linux")), "usr/lib/libmsquic.so.2.5.9") == b"linux")
    with tempfile.TemporaryDirectory() as temporary:
        archive_path = pathlib.Path(temporary) / "provider.zip"
        with zipfile.ZipFile(archive_path, "w") as archive:
            archive.writestr("build/native/bin/x64/msquic.dll", b"windows")
        require(resolver.extract_zip(archive_path.read_bytes(), "build/native/bin/x64/msquic.dll") == b"windows")
    checksum = hashlib.sha256(b"fixture").hexdigest()
    resolver.require_checksum(checksum)
    try:
        resolver.extract_deb(b"invalid", "usr/lib/libmsquic.so.2.5.9")
    except resolver.ResolutionError:
        pass
    else:
        raise AssertionError


if __name__ == "__main__":
    main()
