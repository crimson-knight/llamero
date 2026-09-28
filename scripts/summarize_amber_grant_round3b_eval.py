#!/usr/bin/env python3
"""Report per-cohort/topic compile, required-symbol, and run-agreement scores."""

import json
import sys
from collections import defaultdict
from pathlib import Path


def load(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def ratio(numerator: int, denominator: int) -> str:
    percentage = 100.0 * numerator / denominator if denominator else 0.0
    return f"{numerator}/{denominator} ({percentage:.1f}%)"


def main() -> int:
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <run-1.jsonl> <run-2.jsonl> [more runs...]", file=sys.stderr)
        return 2

    runs = {Path(raw).stem: load(Path(raw)) for raw in sys.argv[1:]}
    print("| Run | Cohort | Topic | Questions | Compile | Complete cases | Symbol hits |")
    print("| --- | --- | --- | ---: | ---: | ---: | ---: |")
    for run_name, records in runs.items():
        grouped: dict[tuple[str, str], list[dict]] = defaultdict(list)
        for record in records:
            grouped[(record["cohort"], record["topic"])].append(record)
        for (cohort, topic), group in sorted(grouped.items()):
            compiled = sum(record["compiled"] for record in group)
            complete = sum(not record["missing_symbols"] for record in group)
            symbol_hits = sum(len(record["found_symbols"]) for record in group)
            symbol_total = sum(len(record["required_symbols"]) for record in group)
            print(
                f"| {run_name} | {cohort} | {topic} | {len(group)} | "
                f"{ratio(compiled, len(group))} | {ratio(complete, len(group))} | "
                f"{ratio(symbol_hits, symbol_total)} |"
            )

    by_configuration: dict[str, list[tuple[str, list[dict]]]] = defaultdict(list)
    for run_name, records in runs.items():
        configuration = records[0]["phase"].rsplit("-run-", 1)[0]
        by_configuration[configuration].append((run_name, records))

    for configuration, config_runs in sorted(by_configuration.items()):
        if len(config_runs) < 2:
            continue
        (left_name, left_records), (right_name, right_records) = config_runs[:2]
        left = {record["id"]: record for record in left_records}
        right = {record["id"]: record for record in right_records}
        if left.keys() != right.keys():
            print(f"run agreement {configuration}: question IDs differ")
            continue
        same_answers = sum(left[key]["raw_answer"] == right[key]["raw_answer"] for key in left)
        same_scores = sum(
            left[key]["compiled"] == right[key]["compiled"]
            and left[key]["found_symbols"] == right[key]["found_symbols"]
            for key in left
        )
        print(
            f"run agreement {configuration} ({left_name} vs {right_name}): "
            f"answers {ratio(same_answers, len(left))}; "
            f"compile+symbols {ratio(same_scores, len(left))}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
