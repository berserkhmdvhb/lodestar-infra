#!/usr/bin/env python3
"""Safely extract a tar archive: safe_extract.py <archive> <dest>.

Zip archives (tflint publishes zips) are checked member by member: no absolute names, no "..",
no symlink or special entries; then the same tree check runs.
Uses tarfile's "data" filter (PEP 706), which refuses absolute names, ".." escapes, links and
hardlinks pointing outside dest, and device or special files, and strips setuid/setgid bits.
After extraction it re-checks, as a second layer, that every symlink resolves inside dest and that
no regular file shares an inode with a path outside dest.
Exits non-zero on any problem. Needs Python 3.12 or newer (tools.sh picks the interpreter).
"""

from __future__ import annotations

import os
import stat
import sys
import tarfile
import zipfile
from pathlib import Path

ARGC = 3


class UnsafeTreeError(Exception):
    """The extracted tree has a link that leads outside the destination."""


def check_tree(dest: Path) -> None:
    root = os.path.realpath(dest)
    inodes: dict[int, int] = {}
    links: dict[int, int] = {}
    for base, dirs, files in os.walk(dest):
        for name in (*dirs, *files):
            path = Path(base, name)
            if path.is_symlink():
                real = os.path.realpath(path)
                if real != root and not real.startswith(root + os.sep):
                    msg = f"symlink {path.relative_to(dest)} resolves outside {dest}"
                    raise UnsafeTreeError(msg)
            elif path.is_file():
                st = path.stat()
                inodes[st.st_ino] = inodes.get(st.st_ino, 0) + 1
                links[st.st_ino] = st.st_nlink
    for ino, nlink in links.items():
        if nlink > inodes[ino]:
            msg = f"a file in {dest} is hard-linked to a path outside it (inode {ino})"
            raise UnsafeTreeError(msg)


def extract_zip(archive: Path, dest: Path) -> None:
    root = os.path.realpath(dest)
    with zipfile.ZipFile(archive) as zf:
        for info in zf.infolist():
            target = os.path.realpath(Path(dest, info.filename))
            mode = info.external_attr >> 16
            if target != root and not target.startswith(root + os.sep):
                msg = f"member {info.filename} escapes {dest}"
                raise UnsafeTreeError(msg)
            if mode and not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
                msg = f"member {info.filename} is not a regular file or directory"
                raise UnsafeTreeError(msg)
        zf.extractall(dest)


def main(argv: list[str]) -> int:
    if len(argv) != ARGC:
        sys.stderr.write("usage: safe_extract.py <archive> <dest>\n")
        return 2
    archive, dest = Path(argv[1]), Path(argv[2])
    try:
        if archive.suffix == ".zip":
            extract_zip(archive, dest)
        else:
            with tarfile.open(archive) as tf:
                tf.extractall(dest, filter="data")
        check_tree(dest)
    except (tarfile.TarError, zipfile.BadZipFile, OSError, UnsafeTreeError, TypeError) as exc:
        # TypeError: Python without the data filter (before 3.12): refuse rather than extract.
        sys.stderr.write(f"safe_extract: refusing {archive.name}: {exc}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
