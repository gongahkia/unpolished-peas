#!/usr/bin/env python3
"""Write a deterministic gzip-compressed tar stream from stdin."""

import gzip
import sys
import tarfile


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: normalize_source_archive.py <destination.tar.gz>")
    with tarfile.open(fileobj=sys.stdin.buffer, mode="r|") as source:
        with open(sys.argv[1], "wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w|", format=tarfile.GNU_FORMAT) as archive:
                    for member in source:
                        member.mtime = 0
                        member.uid = 0
                        member.gid = 0
                        member.uname = ""
                        member.gname = ""
                        data = source.extractfile(member) if member.isfile() else None
                        archive.addfile(member, data)


if __name__ == "__main__":
    main()
