#!/usr/bin/env python3
"""Restore the byte-identical 109-file icon archive from an approved GitHub upload.

An original ZIP is 25,697,283 bytes (too large for a 25 MB GitHub comment).
The transport ZIP stores an XZ-compressed copy of the exact original ZIP and
fits below 25 MB. Both formats are permitted, with pinned SHA-256 hashes.
Nothing is extracted from the nested archive until the original ZIP SHA matches.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import lzma
from pathlib import Path
import zipfile

ORIGINAL_NAME = "AI-Orchestrator-Platform-Icons-v1.zip"
TRANSPORT_NAME = "AI-Orchestrator-Platform-Icons-v1-GitHub.zip"
INNER_NAME = ORIGINAL_NAME + ".xz"
ORIGINAL_SHA256 = "c4355dd078a26861f98f8f643c9a88aa947d8a13b95c14e2dd292e21e84bd414"
TRANSPORT_SHA256 = "c091e2bdffd483b6bd4830fb6e59aa39056f7dde6da601680f152c41a1849803"
MAX_UPLOAD_BYTES = 30_000_000
MAX_ORIGINAL_BYTES = 35_000_000


def unpack_icons(
    source: Path,
    dest: Path,
    *,
    original_sha: str = ORIGINAL_SHA256,
    transport_sha: str = TRANSPORT_SHA256,
) -> str:
    if source.name not in (ORIGINAL_NAME, TRANSPORT_NAME):
        raise ValueError("Unexpected archive name")
    if source.stat().st_size > MAX_UPLOAD_BYTES:
        raise ValueError("Icon archive upload exceeds size cap")
    data = source.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if source.name == TRANSPORT_NAME:
        if digest != transport_sha:
            raise ValueError("Compact transport ZIP checksum mismatch")
        with zipfile.ZipFile(io.BytesIO(data)) as pack:
            if sorted(pack.namelist()) != [INNER_NAME, "README-GITHUB-TRANSFER.txt"]:
                raise ValueError("Unexpected files inside approved transport ZIP")
            data = lzma.decompress(pack.read(INNER_NAME), format=lzma.FORMAT_XZ)
    if len(data) > MAX_ORIGINAL_BYTES:
        raise ValueError("Restored icon archive exceeds size cap")
    if hashlib.sha256(data).hexdigest() != original_sha:
        raise ValueError("Restored original icon archive SHA256 mismatch")
    with zipfile.ZipFile(io.BytesIO(data)) as icon_zip:
        if icon_zip.testzip() is not None:
            raise ValueError("Original icon archive has corrupt entries")
        if len(icon_zip.namelist()) != 109:
            raise ValueError("Original icon archive expected 109 entries")
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(data)
    return original_sha


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("upload", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    print("Restored approved icon archive SHA256:", unpack_icons(args.upload, args.output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
