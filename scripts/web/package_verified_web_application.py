"""Create and read back the ZIP for sources already verified by the Web runner."""

import hashlib
import io
import json
import re
import sys
import zipfile


PATH = re.compile(r'(?:[a-z0-9][a-z0-9_-]*/){0,3}[a-z0-9][a-z0-9_-]*\.(?:html|css|js|mjs|json|txt|md)')
MAX_SOURCE_BYTES = 65_536


def package(data):
    files = data['files']
    if not isinstance(files, list) or not 1 <= len(files) <= 12:
        raise ValueError('Invalid source files')
    entries = {}
    for file in files:
        path = file['path']
        if len(path) > 100 or not PATH.fullmatch(path) or path in entries:
            raise ValueError('Invalid source path')
        entries[path] = file['content'].encode('utf-8')
    if 'index.html' not in entries or sum(map(len, entries.values())) > MAX_SOURCE_BYTES:
        raise ValueError('Invalid application source')

    archive = io.BytesIO()
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_STORED) as output:
        for path, source in sorted(entries.items()):
            output.writestr(zipfile.ZipInfo(path), source)
    with zipfile.ZipFile(archive, 'r') as output:
        if output.namelist() != sorted(entries) or output.testzip() is not None:
            raise ValueError('Archive integrity check failed')
        for path, source in entries.items():
            if hashlib.sha256(output.read(path)).digest() != hashlib.sha256(source).digest():
                raise ValueError('Archived source digest does not match')
    return archive.getvalue()


def main():
    raw = sys.stdin.buffer.read(MAX_SOURCE_BYTES + 1)
    if len(raw) > MAX_SOURCE_BYTES:
        raise ValueError('Source exceeds package limits')
    sys.stdout.buffer.write(package(json.loads(raw)))


if __name__ == '__main__':
    main()
