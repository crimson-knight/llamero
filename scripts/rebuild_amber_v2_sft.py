#!/usr/bin/env python3
"""Rebuild the consolidated Amber V2 SFT file from its source JSONL files."""

import argparse
import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "training_data" / "amber"


def read_pairs(path: Path) -> list[dict[str, str]]:
    rows = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        row = json.loads(line)
        if row.get("kind") != "pair" or not row.get("prompt") or not row.get("completion"):
            raise ValueError(f"{path}:{line_number}: expected a complete pair row")
        rows.append({"kind": "pair", "prompt": row["prompt"], "completion": row["completion"]})
    return rows


def prompt_key(prompt: str) -> str:
    return re.sub(r"\s+", " ", prompt.casefold()).strip()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-only", action="store_true", help="rebuild only the original Amber V2 corpus")
    parser.add_argument("--output", type=Path, help="write to this path instead of amber_v2_sft.jsonl")
    args = parser.parse_args()

    source_paths = [DATA / "amber_v2_pairs.jsonl", DATA / "grant_pairs.jsonl"]
    if not args.base_only:
        source_paths.append(DATA / "grant_tenancy_rawsql_pairs.jsonl")

    merged = []
    seen = set()
    dropped = 0
    for source_path in source_paths:
        for row in read_pairs(source_path):
            key = prompt_key(row["prompt"])
            if key in seen:
                dropped += 1
                continue
            seen.add(key)
            merged.append(row)

    expected_base = 212
    if args.base_only and len(merged) != expected_base:
        raise SystemExit(f"base rebuild produced {len(merged)} rows; expected {expected_base}")

    destination = args.output or DATA / "amber_v2_sft.jsonl"
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("w", encoding="utf-8", newline="\n") as stream:
        for row in merged:
            stream.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")

    print(f"wrote {len(merged)} pair rows to {destination} (deduped {dropped}; base_only={args.base_only})")


if __name__ == "__main__":
    main()
