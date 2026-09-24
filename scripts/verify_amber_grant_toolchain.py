#!/usr/bin/env python3
"""Fail closed unless Round 3 sources, tools, dependencies, and bridge match pins."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PIN_PATH = ROOT / "training_data" / "amber" / "round3_toolchain_pin.json"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run_version(path: str, arguments: list[str]) -> str:
    result = subprocess.run([path, *arguments], check=True, text=True, capture_output=True)
    return result.stdout + result.stderr


def verify_git_commit(repository: str, commit: str, label: str) -> None:
    actual = subprocess.run(
        ["/opt/homebrew/bin/git", "-C", repository, "rev-parse", f"{commit}^{{commit}}"],
        check=True,
        text=True,
        capture_output=True,
    ).stdout.strip()
    if actual != commit:
        raise ValueError(f"{label} commit mismatch: expected {commit}, got {actual}")


def verify_file(path_string: str, expected_hash: str, label: str) -> None:
    path = Path(path_string)
    if not path.is_file():
        raise ValueError(f"{label} is missing: {path}")
    actual_hash = sha256(path)
    if actual_hash != expected_hash:
        raise ValueError(f"{label} SHA256 mismatch: expected {expected_hash}, got {actual_hash}")


def main() -> int:
    pin = json.loads(PIN_PATH.read_text(encoding="utf-8"))
    for tool in pin["tools"]:
        verify_file(tool["path"], tool["sha256"], tool["name"])
        output = run_version(tool["path"], tool["version_command"])
        if not output.startswith(tool["version_prefix"]):
            raise ValueError(f"{tool['name']} version mismatch: {output.strip()}")
        print(f"PASS {tool['name']} {tool['version_prefix']}")

    if "--tools-only" in sys.argv:
        return 0

    grant = pin["grant"]
    verify_git_commit(grant["repository"], grant["commit"], "Grant")
    verify_file(
        str(Path(grant["repository"]) / "shard.lock"),
        grant["verified_dependency_lock_sha256"],
        "Grant checksum lock",
    )
    print(f"PASS Grant source {grant['commit']}")

    for label in ("amber", "multi_tenancy_guide"):
        source = pin[label]
        verify_git_commit(source["repository"], source["commit"], label)
        print(f"PASS {label} source {source['commit']}")

    if "--prepare-only" in sys.argv:
        return 0

    for label in ("amber", "multi_tenancy_guide"):
        source = pin[label]
        source_dir = ROOT / source["source_directory"]
        marker_name = source.get("marker", f".{label}-source-commit")
        marker = source_dir / marker_name
        if not marker.is_file() or marker.read_text(encoding="utf-8").strip() != source["commit"]:
            raise ValueError(f"pinned {label} archive is not prepared at {source_dir}")
        if label == "multi_tenancy_guide" and not (source_dir / source["file"]).is_file():
            raise ValueError(f"pinned multi-tenancy guide is missing at {source_dir / source['file']}")

    source_dir = ROOT / grant["source_directory"]
    marker = source_dir / ".grant-source-commit"
    if not marker.is_file() or marker.read_text(encoding="utf-8").strip() != grant["commit"]:
        raise ValueError(f"pinned Grant source is not prepared at {source_dir}")
    print(f"PASS pinned Grant archive {source_dir}")

    critic = pin["critic"]
    verify_file(critic["aed_linter"], critic["aed_linter_sha256"], "AED critic")
    print("PASS AED naming critic")

    bridge = pin["native_mlx_bridge"]
    verify_file(bridge["path"], bridge["sha256"], "MLX bridge")
    print("PASS native MLX bridge")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, subprocess.CalledProcessError, ValueError, KeyError) as error:
        print(f"FAIL {error}", file=sys.stderr)
        raise SystemExit(1)
