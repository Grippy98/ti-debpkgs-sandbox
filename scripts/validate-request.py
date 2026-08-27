#!/usr/bin/env python3

"""Validate one publication request against the sandbox policy.

This intentionally uses only the Python standard library so the same validator
runs locally and in the publishing workflow without fetching code from PyPI.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
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


def string(value: Any, pattern: str, context: str) -> str:
    if not isinstance(value, str) or re.fullmatch(pattern, value) is None:
        raise ValidationError(f"{context}: invalid value")
    return value


def positive_integer(value: Any, context: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise ValidationError(f"{context}: must be a positive integer")
    return value


def validate(request_path: Path, policy_path: Path) -> None:
    request = load_json(request_path)
    policy = load_json(policy_path)

    if request.get("schema") != "ti.debpkgs.request/v1":
        raise ValidationError("unsupported request schema")

    request_id = string(
        request.get("request_id"), r"[a-z0-9][a-z0-9._-]{2,79}", "request_id"
    )
    action = request.get("action")
    if action not in {"include", "remove-source"}:
        raise ValidationError("action must be include or remove-source")

    suite = string(request.get("suite"), r"[a-z0-9][a-z0-9.-]*", "suite")
    component = string(
        request.get("component"), r"[a-z0-9][a-z0-9+.-]*", "component"
    )
    reason = request.get("reason")
    if not isinstance(reason, str) or not 3 <= len(reason) <= 500:
        raise ValidationError("reason must contain between 3 and 500 characters")
    if any(ord(character) < 32 or ord(character) == 127 for character in reason):
        raise ValidationError("reason must not contain control characters")

    suite_policy = policy.get("suites", {}).get(suite)
    if not isinstance(suite_policy, dict):
        raise ValidationError(f"suite is not allowed by policy: {suite}")
    if component not in suite_policy.get("components", []):
        raise ValidationError(
            f"component {component!r} is not allowed for suite {suite!r}"
        )

    base_keys = {"schema", "request_id", "action", "suite", "component", "reason"}
    if action == "include":
        exact_keys(request, base_keys | {"candidate", "source"}, f"request {request_id}")
        candidate = request.get("candidate")
        if not isinstance(candidate, dict):
            raise ValidationError("candidate must be an object")
        candidate_keys = {
            "run_id",
            "run_attempt",
            "artifact_id",
            "artifact_name",
            "artifact_digest",
            "bundle",
            "bundle_sha256",
            "producer_commit",
        }
        exact_keys(candidate, candidate_keys, "candidate")
        for key in ("run_id", "run_attempt", "artifact_id"):
            positive_integer(candidate[key], f"candidate.{key}")
        string(
            candidate["artifact_name"],
            r"[A-Za-z0-9][A-Za-z0-9._-]+",
            "candidate.artifact_name",
        )
        string(
            candidate["artifact_digest"],
            r"sha256:[0-9a-f]{64}",
            "candidate.artifact_digest",
        )
        string(
            candidate["bundle"],
            r"candidate-[A-Za-z0-9._-]+\.tar\.gz",
            "candidate.bundle",
        )
        string(
            candidate["bundle_sha256"],
            r"[0-9a-f]{64}",
            "candidate.bundle_sha256",
        )
        string(
            candidate["producer_commit"],
            r"[0-9a-f]{40}",
            "candidate.producer_commit",
        )
        source = request.get("source")
        if not isinstance(source, dict):
            raise ValidationError("source must be an object")
        exact_keys(
            source,
            {"name", "version", "upstream_repository", "upstream_commit"},
            "source",
        )
        string(source["name"], r"[a-z0-9][a-z0-9+.-]+", "source.name")
        string(source["version"], r"[^\s/]{1,200}", "source.version")
        string(
            source["upstream_repository"],
            r"https://[^\s]+",
            "source.upstream_repository",
        )
        string(
            source["upstream_commit"],
            r"[0-9a-f]{40}",
            "source.upstream_commit",
        )
    else:
        exact_keys(request, base_keys | {"source"}, f"request {request_id}")
        source = request.get("source")
        if not isinstance(source, dict):
            raise ValidationError("source must be an object")
        exact_keys(source, {"name", "version"}, "source")
        string(source["name"], r"[a-z0-9][a-z0-9+.-]+", "source.name")
        string(source["version"], r"[^\s/]{1,200}", "source.version")


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <request.json> <policy.json>", file=sys.stderr)
        return 2
    try:
        validate(Path(sys.argv[1]), Path(sys.argv[2]))
    except ValidationError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
