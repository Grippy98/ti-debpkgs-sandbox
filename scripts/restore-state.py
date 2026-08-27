#!/usr/bin/env python3

"""Safely restore and verify one archive-state snapshot."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import sys
import tarfile
from pathlib import Path, PurePosixPath


ALLOWED_ROOTS = {"audit", "db", "dists", "pool"}


class SnapshotError(ValueError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_name(name: str) -> bool:
    path = PurePosixPath(name)
    return (
        bool(name)
        and not path.is_absolute()
        and name == str(path)
        and all(part not in {"", ".", ".."} for part in path.parts)
        and (
            name == "ARCHIVE-SHA256SUMS"
            or (path.parts and path.parts[0] in ALLOWED_ROOTS)
        )
    )


def extract(
    snapshot: Path,
    destination: Path,
    compressed_limit: int,
    member_limit: int,
    expanded_limit: int,
) -> None:
    if destination.exists():
        raise SnapshotError(f"destination already exists: {destination}")
    if snapshot.stat().st_size > compressed_limit:
        raise SnapshotError("snapshot exceeds the compressed-size limit")
    destination.mkdir(parents=True, mode=0o700)

    seen: set[str] = set()
    member_count = 0
    total_size = 0
    with tarfile.open(snapshot, mode="r:gz") as archive:
        members = archive.getmembers()
        for member in members:
            member_count += 1
            if member_count > member_limit:
                raise SnapshotError("snapshot contains too many members")
            if not safe_name(member.name):
                raise SnapshotError(f"unsafe snapshot member: {member.name!r}")
            if member.name in seen:
                raise SnapshotError(f"duplicate snapshot member: {member.name}")
            seen.add(member.name)
            if member.isdir():
                continue
            if not member.isreg():
                raise SnapshotError(f"non-regular snapshot member: {member.name}")
            total_size += member.size
            if total_size > expanded_limit:
                raise SnapshotError("snapshot exceeds extraction limits")

        if "ARCHIVE-SHA256SUMS" not in seen:
            raise SnapshotError("snapshot lacks ARCHIVE-SHA256SUMS")

        for member in members:
            target = destination.joinpath(*PurePosixPath(member.name).parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True, mode=0o700)
                continue
            source = archive.extractfile(member)
            if source is None:
                raise SnapshotError(f"could not read snapshot member: {member.name}")
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            with target.open("xb") as output:
                shutil.copyfileobj(source, output, length=1024 * 1024)
            os.chmod(target, 0o600)


def verify_manifest(destination: Path) -> None:
    manifest = destination / "ARCHIVE-SHA256SUMS"
    expected: dict[str, str] = {}
    for line_number, line in enumerate(manifest.read_text().splitlines(), 1):
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if match is None:
            raise SnapshotError(f"invalid snapshot checksum at line {line_number}")
        digest, relative = match.groups()
        if not safe_name(relative) or relative == "ARCHIVE-SHA256SUMS":
            raise SnapshotError(f"unsafe snapshot checksum path: {relative!r}")
        if relative in expected:
            raise SnapshotError(f"duplicate snapshot checksum path: {relative}")
        expected[relative] = digest

    actual = {
        str(path.relative_to(destination)): path
        for root in ALLOWED_ROOTS
        if (destination / root).exists()
        for path in (destination / root).rglob("*")
        if path.is_file()
    }
    if set(expected) != set(actual):
        raise SnapshotError("snapshot checksum manifest does not exactly cover state")
    for relative, path in actual.items():
        if sha256(path) != expected[relative]:
            raise SnapshotError(f"snapshot checksum mismatch: {relative}")


def main() -> int:
    if len(sys.argv) != 4:
        print(
            f"Usage: {sys.argv[0]} <archive-state.tar.gz> <policy.json> <destination>",
            file=sys.stderr,
        )
        return 2
    destination = Path(sys.argv[3])
    try:
        policy = json.loads(Path(sys.argv[2]).read_text())
        limits = policy["limits"]
        compressed_limit = limits["snapshot_bytes"]
        member_limit = limits["snapshot_members"]
        expanded_limit = limits["snapshot_expanded_bytes"]
        if any(
            isinstance(limit, bool) or not isinstance(limit, int) or limit < 1
            for limit in (compressed_limit, member_limit, expanded_limit)
        ):
            raise SnapshotError("snapshot limits are invalid")
        extract(
            Path(sys.argv[1]),
            destination,
            compressed_limit,
            member_limit,
            expanded_limit,
        )
        verify_manifest(destination)
    except (
        KeyError,
        json.JSONDecodeError,
        OSError,
        SnapshotError,
        tarfile.TarError,
        UnicodeError,
    ) as error:
        shutil.rmtree(destination, ignore_errors=True)
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
