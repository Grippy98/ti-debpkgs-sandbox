#!/usr/bin/env python3

"""Extract the one opaque candidate bundle from an Actions artifact ZIP."""

from __future__ import annotations

import hashlib
import sys
import zipfile
from pathlib import Path, PurePosixPath


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    if len(sys.argv) != 6:
        print(
            f"Usage: {sys.argv[0]} <artifact.zip> <bundle-name> <bundle-sha256> "
            "<maximum-bytes> <destination>",
            file=sys.stderr,
        )
        return 2

    archive = Path(sys.argv[1])
    bundle_name = sys.argv[2]
    expected_sha256 = sys.argv[3]
    destination = Path(sys.argv[5])
    try:
        maximum_bytes = int(sys.argv[4])
        if maximum_bytes < 1:
            raise ValueError("maximum bytes must be positive")
        if archive.stat().st_size > maximum_bytes:
            raise ValueError("Actions artifact exceeds the configured size limit")
        if destination.exists():
            raise ValueError(f"destination already exists: {destination}")
        with zipfile.ZipFile(archive) as transport:
            members = transport.infolist()
            if len(members) != 1:
                raise ValueError("Actions artifact must contain exactly one file")
            member = members[0]
            path = PurePosixPath(member.filename)
            if (
                member.is_dir()
                or path.is_absolute()
                or len(path.parts) != 1
                or member.filename != bundle_name
            ):
                raise ValueError("Actions artifact contains an unexpected path")
            if member.file_size < 1 or member.file_size > maximum_bytes:
                raise ValueError("candidate bundle exceeds the configured size limit")
            destination.parent.mkdir(parents=True, exist_ok=True)
            with transport.open(member) as source, destination.open("xb") as output:
                written = 0
                for chunk in iter(lambda: source.read(1024 * 1024), b""):
                    written += len(chunk)
                    if written > maximum_bytes:
                        raise ValueError("candidate bundle exceeds the configured size limit")
                    output.write(chunk)
                if written != member.file_size:
                    raise ValueError("candidate bundle size differs from ZIP metadata")
        if sha256(destination) != expected_sha256:
            destination.unlink(missing_ok=True)
            raise ValueError("candidate bundle checksum does not match request")
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        destination.unlink(missing_ok=True)
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
