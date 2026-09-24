#!/usr/bin/env python3
"""Verify the cached Gemma 3 4B model against its pinned Hub revision."""

import argparse
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PIN = ROOT / "training_data" / "amber" / "gemma3_4b_model_pin.json"


def sha256(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def git_blob_sha1(content: bytes) -> str:
    header = f"blob {len(content)}\0".encode()
    return hashlib.sha1(header + content).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", type=Path, help="local cache directory to verify")
    args = parser.parse_args()

    pin = json.loads(PIN.read_text(encoding="utf-8"))
    model_dir = args.model_dir or Path.home() / ".llamero" / "models" / pin["local_cache_relative_dir"]
    if pin["pinned_model_id"] != f"{pin['model_id']}@{pin['revision']}":
        raise SystemExit("pinned model id and revision fields disagree")
    if len(pin["revision"]) != 40 or any(char not in "0123456789abcdef" for char in pin["revision"]):
        raise SystemExit("model revision is not a full lowercase commit SHA")

    verified = 0
    for item in pin["files"]:
        path = model_dir / item["source_file"]
        if not path.is_file():
            raise SystemExit(f"missing pinned model file: {path}")
        content = path.read_bytes()
        if len(content) != item["size_bytes"]:
            raise SystemExit(f"size mismatch for {path}: {len(content)} != {item['size_bytes']}")
        if sha256(content) != item["source_sha256"]:
            raise SystemExit(f"source SHA256 mismatch for {path}")
        if lfs_sha256 := item.get("lfs_sha256"):
            if sha256(content) != lfs_sha256:
                raise SystemExit(f"Hub LFS SHA256 mismatch for {path}")
        elif git_blob_sha1(content) != item["git_blob_sha1"]:
            raise SystemExit(f"Hub Git blob SHA1 mismatch for {path}")

        if runtime_file := item.get("runtime_file"):
            runtime_path = model_dir / runtime_file
            if not runtime_path.is_file():
                raise SystemExit(f"missing transformed runtime config: {runtime_path}")
            if sha256(runtime_path.read_bytes()) != item["runtime_sha256"]:
                raise SystemExit(f"runtime config SHA256 mismatch for {runtime_path}")
        verified += 1

    print(f"PASS: {verified}/{len(pin['files'])} model files match {pin['pinned_model_id']}")
    print(f"  local model directory: {model_dir}")
    print(f"  weights SHA256: {next(item['lfs_sha256'] for item in pin['files'] if item['name'] == 'model.safetensors')}")


if __name__ == "__main__":
    main()
