#!/usr/bin/env python3

"""Safely extract and validate an already-attested build candidate."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import sys
import tarfile
from pathlib import Path, PurePosixPath
from typing import Any


class ValidationError(ValueError):
    pass


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValidationError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(), object_pairs_hook=reject_duplicate_keys)
    except (OSError, json.JSONDecodeError, ValidationError) as error:
        raise ValidationError(f"{path}: {error}") from error
    if not isinstance(value, dict):
        raise ValidationError(f"{path}: top-level value must be an object")
    return value


def exact_keys(value: dict[str, Any], required: set[str], context: str) -> None:
    missing = sorted(required - value.keys())
    unknown = sorted(value.keys() - required)
    if missing:
        raise ValidationError(f"{context}: missing keys: {', '.join(missing)}")
    if unknown:
        raise ValidationError(f"{context}: unknown keys: {', '.join(unknown)}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_member_name(name: str) -> bool:
    path = PurePosixPath(name)
    return (
        bool(name)
        and not path.is_absolute()
        and name == str(path)
        and all(part not in {"", ".", ".."} for part in path.parts)
    )


def extract_safely(bundle: Path, destination: Path, byte_limit: int, file_limit: int) -> None:
    if destination.exists() and any(destination.iterdir()):
        raise ValidationError(f"extraction directory is not empty: {destination}")
    destination.mkdir(parents=True, exist_ok=True)

    seen: set[str] = set()
    total_size = 0
    file_count = 0
    with tarfile.open(bundle, mode="r:gz") as archive:
        members = archive.getmembers()
        for member in members:
            if not safe_member_name(member.name):
                raise ValidationError(f"unsafe archive member path: {member.name!r}")
            if member.name in seen:
                raise ValidationError(f"duplicate archive member: {member.name}")
            seen.add(member.name)

            if member.isdir():
                if member.name != "payload":
                    raise ValidationError(f"unexpected directory in candidate: {member.name}")
                continue
            if not member.isreg():
                raise ValidationError(f"non-regular archive member: {member.name}")

            if member.name not in {"manifest.json", "SHA256SUMS"} and not re.fullmatch(
                r"payload/[A-Za-z0-9][A-Za-z0-9+._~-]*", member.name
            ):
                raise ValidationError(f"unexpected candidate member: {member.name}")

            file_count += 1
            total_size += member.size
            if file_count > file_limit:
                raise ValidationError("candidate contains too many files")
            if total_size > byte_limit:
                raise ValidationError("candidate expands beyond the configured size limit")

        required = {"manifest.json", "SHA256SUMS"}
        if not required.issubset(seen):
            raise ValidationError("candidate lacks manifest.json or SHA256SUMS")

        for member in members:
            if not member.isreg():
                continue
            source = archive.extractfile(member)
            if source is None:
                raise ValidationError(f"could not read archive member: {member.name}")
            target = destination.joinpath(*PurePosixPath(member.name).parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open("xb") as output:
                shutil.copyfileobj(source, output, length=1024 * 1024)
            os.chmod(target, 0o600)


def read_checksums(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for line_number, line in enumerate(path.read_text().splitlines(), 1):
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9+._~/-]*)", line)
        if match is None:
            raise ValidationError(f"{path}:{line_number}: invalid checksum record")
        digest, relative = match.groups()
        if not safe_member_name(relative) or relative == "SHA256SUMS":
            raise ValidationError(f"{path}:{line_number}: unsafe checksum path")
        if relative in result:
            raise ValidationError(f"{path}:{line_number}: duplicate checksum path")
        result[relative] = digest
    return result


def read_deb822(path: Path) -> dict[str, str]:
    fields: dict[str, str] = {}
    current: str | None = None
    for line_number, line in enumerate(path.read_text(errors="strict").splitlines(), 1):
        if line.startswith((" ", "\t")):
            if current is None:
                raise ValidationError(f"{path}:{line_number}: orphan continuation line")
            separator = "\n" if fields[current] else ""
            fields[current] += separator + line[1:]
            continue
        if not line:
            continue
        if ":" not in line:
            raise ValidationError(f"{path}:{line_number}: invalid Debian control field")
        current, value = line.split(":", 1)
        if current in fields:
            raise ValidationError(f"{path}:{line_number}: duplicate field {current}")
        fields[current] = value.lstrip()
    return fields


def deb822_sha256_files(fields: dict[str, str], path: Path) -> dict[str, tuple[str, int]]:
    value = fields.get("Checksums-Sha256")
    if value is None:
        raise ValidationError(f"{path}: missing Checksums-Sha256")
    result: dict[str, tuple[str, int]] = {}
    for line in value.splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})\s+([0-9]+)\s+([^\s/]+)", line.strip())
        if match is None:
            raise ValidationError(f"{path}: malformed Checksums-Sha256 record")
        digest, size, name = match.groups()
        if name in result:
            raise ValidationError(f"{path}: duplicate file in Checksums-Sha256: {name}")
        result[name] = (digest, int(size))
    return result


def validate_manifest(
    root: Path, request: dict[str, Any], policy: dict[str, Any], checksums: dict[str, str]
) -> None:
    manifest = load_json(root / "manifest.json")
    exact_keys(
        manifest,
        {"schema", "producer", "source", "build", "publication", "files"},
        "manifest",
    )
    if manifest["schema"] != "ti.debian.candidate/v1":
        raise ValidationError("unsupported candidate manifest schema")

    producer = manifest["producer"]
    if not isinstance(producer, dict):
        raise ValidationError("manifest producer must be an object")
    exact_keys(
        producer,
        {"repository", "workflow", "ref", "commit", "run_id", "run_attempt"},
        "manifest producer",
    )
    expected_producer = policy["producer"]
    candidate_request = request["candidate"]
    expected_values = {
        "repository": expected_producer["repository"],
        "workflow": expected_producer["workflow"],
        "commit": candidate_request["producer_commit"],
        "run_id": candidate_request["run_id"],
        "run_attempt": candidate_request["run_attempt"],
    }
    for key, expected in expected_values.items():
        if producer.get(key) != expected:
            raise ValidationError(f"manifest producer {key} does not match the request/policy")
    if producer.get("ref") not in expected_producer["allowed_refs"]:
        raise ValidationError("manifest producer ref is not allowed by policy")

    source = manifest["source"]
    if not isinstance(source, dict):
        raise ValidationError("manifest source must be an object")
    exact_keys(
        source,
        {"name", "version", "upstream_repository", "upstream_commit"},
        "manifest source",
    )
    if re.fullmatch(r"[a-z0-9][a-z0-9+.-]+", str(source["name"])) is None:
        raise ValidationError("invalid source package name")
    if not isinstance(source["version"], str) or not source["version"]:
        raise ValidationError("invalid source package version")
    if not isinstance(source["upstream_repository"], str) or not source[
        "upstream_repository"
    ].startswith("https://"):
        raise ValidationError("upstream repository must use HTTPS")
    if re.fullmatch(r"[0-9a-f]{40}", str(source["upstream_commit"])) is None:
        raise ValidationError("upstream commit must be a full Git SHA")
    if source != request["source"]:
        raise ValidationError("manifest source identity does not match publication request")

    build = manifest["build"]
    if not isinstance(build, dict):
        raise ValidationError("manifest build must be an object")
    exact_keys(build, {"suite", "binary_architectures", "changes_distribution"}, "build")
    if build["suite"] != request["suite"]:
        raise ValidationError("build suite does not match publication request")
    allowed_distributions = policy["suites"][request["suite"]].get(
        "changes_distributions", []
    )
    if (
        not isinstance(allowed_distributions, list)
        or build["changes_distribution"] not in allowed_distributions
    ):
        raise ValidationError(".changes distribution is not allowed by policy")
    architectures = build["binary_architectures"]
    if not isinstance(architectures, list) or not architectures:
        raise ValidationError("binary_architectures must be a non-empty array")
    allowed_architectures = policy["suites"][request["suite"]]["architectures"]
    if any(value not in allowed_architectures or value == "source" for value in architectures):
        raise ValidationError("candidate contains a disallowed binary architecture")

    publication = manifest["publication"]
    if not isinstance(publication, dict):
        raise ValidationError("manifest publication must be an object")
    exact_keys(publication, {"suites", "component"}, "publication")
    if publication != {"suites": [request["suite"]], "component": request["component"]}:
        raise ValidationError("manifest publication target does not match request")

    files = manifest["files"]
    if not isinstance(files, list) or not files:
        raise ValidationError("manifest files must be a non-empty array")
    declared: dict[str, tuple[int, str]] = {}
    for index, item in enumerate(files):
        if not isinstance(item, dict):
            raise ValidationError(f"manifest files[{index}] must be an object")
        exact_keys(item, {"path", "size", "sha256"}, f"manifest files[{index}]")
        relative = item["path"]
        if not isinstance(relative, str) or re.fullmatch(
            r"payload/[A-Za-z0-9][A-Za-z0-9+._~-]*", relative
        ) is None:
            raise ValidationError(f"invalid payload path in manifest: {relative!r}")
        if relative in declared:
            raise ValidationError(f"duplicate manifest file: {relative}")
        size = item["size"]
        digest = item["sha256"]
        if isinstance(size, bool) or not isinstance(size, int) or size < 1:
            raise ValidationError(f"invalid size for {relative}")
        if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
            raise ValidationError(f"invalid digest for {relative}")
        declared[relative] = (size, digest)

    payload_files = {
        str(path.relative_to(root)): path
        for path in (root / "payload").iterdir()
        if path.is_file()
    }
    if set(declared) != set(payload_files):
        raise ValidationError("manifest file list does not exactly match payload")
    if set(checksums) != {"manifest.json", *payload_files}:
        raise ValidationError("SHA256SUMS does not exactly cover manifest and payload")
    for relative, path in payload_files.items():
        expected_size, expected_digest = declared[relative]
        if path.stat().st_size != expected_size:
            raise ValidationError(f"size mismatch for {relative}")
        if checksums[relative] != expected_digest or sha256(path) != expected_digest:
            raise ValidationError(f"checksum mismatch for {relative}")

    suffix_counts = {
        ".changes": 0,
        ".buildinfo": 0,
        ".dsc": 0,
        ".deb": 0,
        ".orig": 0,
        ".debian": 0,
    }
    for relative in payload_files:
        name = Path(relative).name
        for suffix in (".changes", ".buildinfo", ".dsc", ".deb"):
            if name.endswith(suffix):
                suffix_counts[suffix] += 1
        if ".orig.tar." in name:
            suffix_counts[".orig"] += 1
        if ".debian.tar." in name:
            suffix_counts[".debian"] += 1
    if suffix_counts[".changes"] != 1 or suffix_counts[".buildinfo"] != 1:
        raise ValidationError("candidate must contain exactly one .changes and .buildinfo")
    if suffix_counts[".dsc"] != 1 or suffix_counts[".orig"] != 1 or suffix_counts[".debian"] != 1:
        raise ValidationError("candidate must contain one complete Debian source package")
    if suffix_counts[".deb"] < 1:
        raise ValidationError("candidate must contain at least one binary package")

    changes_path = next(path for relative, path in payload_files.items() if relative.endswith(".changes"))
    changes = read_deb822(changes_path)
    if changes.get("Source") != source["name"] or changes.get("Version") != source["version"]:
        raise ValidationError(".changes source/version does not match manifest")
    if changes.get("Distribution") != build["changes_distribution"]:
        raise ValidationError(".changes distribution does not match manifest")
    change_files = deb822_sha256_files(changes, changes_path)
    expected_change_names = {Path(relative).name for relative in payload_files if not relative.endswith(".changes")}
    if set(change_files) != expected_change_names:
        raise ValidationError(".changes does not reference the complete payload closure")
    for name, (digest, size) in change_files.items():
        payload_path = root / "payload" / name
        if payload_path.stat().st_size != size or sha256(payload_path) != digest:
            raise ValidationError(f".changes checksum mismatch for {name}")


def verify(bundle: Path, request_path: Path, policy_path: Path, destination: Path) -> None:
    request = load_json(request_path)
    policy = load_json(policy_path)
    if request.get("action") != "include":
        raise ValidationError("candidate verification is only valid for include requests")
    candidate = request.get("candidate")
    if not isinstance(candidate, dict):
        raise ValidationError("include request lacks candidate metadata")
    if bundle.name != candidate.get("bundle"):
        raise ValidationError("candidate bundle filename does not match request")
    if sha256(bundle) != candidate.get("bundle_sha256"):
        raise ValidationError("candidate bundle checksum does not match request")

    limits = policy.get("limits", {})
    byte_limit = limits.get("candidate_bytes")
    file_limit = limits.get("payload_files")
    if not isinstance(byte_limit, int) or not isinstance(file_limit, int):
        raise ValidationError("policy limits are invalid")
    if bundle.stat().st_size > byte_limit:
        raise ValidationError("candidate bundle exceeds the configured size limit")
    extract_safely(bundle, destination, byte_limit, file_limit)

    checksums = read_checksums(destination / "SHA256SUMS")
    for relative, expected in checksums.items():
        path = destination / relative
        if not path.is_file() or sha256(path) != expected:
            raise ValidationError(f"SHA256SUMS mismatch for {relative}")
    validate_manifest(destination, request, policy, checksums)


def main() -> int:
    if len(sys.argv) != 5:
        print(
            f"Usage: {sys.argv[0]} <candidate.tar.gz> <request.json> <policy.json> <output-dir>",
            file=sys.stderr,
        )
        return 2
    try:
        verify(Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4]))
    except (ValidationError, OSError, tarfile.TarError, UnicodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
