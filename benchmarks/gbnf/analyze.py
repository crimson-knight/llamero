#!/usr/bin/env python3
"""Aggregate bench runs.jsonl into medians+IQR tables (markdown).

Honesty rules baked in (audit round 1):
- "oracle pass" not "success"/"correct": the oracle checks a calibrated SUBSET
  of fields (see BENCH_RESULTS.md deviations), not full schema correctness.
- wall-to-pass medians are computed over passing runs only; a headline delta is
  printed ONLY when both arms pass 25/25 - otherwise the cells are declared
  not comparable on time and pass rates are the result.
- temp0 label means: attempt 1 at temp 0; retries (if any) at temp 0.8.
"""
import json
import statistics as st
import sys
from collections import defaultdict

path = sys.argv[1] if len(sys.argv) > 1 else "results/runs.jsonl"
rows = [json.loads(l) for l in open(path) if l.strip()]

ARMS = ["base-unconstrained", "base-grammar", "tuned-unconstrained", "tuned-grammar"]
TASKS = ["flat", "medium", "cliff"]


def q(vals, p):
    if not vals:
        return float("nan")
    vs = sorted(vals)
    idx = (len(vs) - 1) * p
    lo, hi = int(idx), min(int(idx) + 1, len(vs) - 1)
    frac = idx - lo
    return vs[lo] * (1 - frac) + vs[hi] * frac


def fmt_ms(v):
    return f"{v:,.0f}"


groups = defaultdict(list)
for r in rows:
    groups[(r["task"], r["arm"], r["temp_label"])].append(r)

print("Cell label temp0 = attempt 1 at temp 0; retry attempts (unconstrained arms only in practice) resample at temp 0.8.")
for task in TASKS:
    print(f"\n### Task: {task}\n")
    print("| arm | N | oracle pass rate | median wall-to-pass (ms, passing runs only) | IQR (ms) | p90 (ms) | median tokens | first-attempt oracle fail rate | median attempts | sampler us/token (median, last attempt) |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for arm in ARMS:
        rs = groups.get((task, arm, "temp0"), [])
        if not rs:
            continue
        n = len(rs)
        succ = [r for r in rs if r["success"]]
        sr = len(succ) / n
        walls = [r["wall_ms"] for r in succ]
        med = q(walls, 0.5) if walls else float("nan")
        iqr = (q(walls, 0.25), q(walls, 0.75)) if walls else (float("nan"),) * 2
        p90 = q(walls, 0.9) if walls else float("nan")
        toks = [r["gen_tokens_total"] for r in succ] or [r["gen_tokens_total"] for r in rs]
        medt = q(toks, 0.5)
        first_fail = sum(1 for r in rs if not r["first_attempt_correct"]) / n
        attempts = q([r["attempts"] for r in rs], 0.5)
        smp = q([r["sampler_ms_per_token_last"] for r in rs], 0.5) * 1000  # us/token
        wall_cell = fmt_ms(med) if walls else "n/a (0 passes)"
        iqr_cell = f"{fmt_ms(iqr[0])}–{fmt_ms(iqr[1])}" if walls else "n/a"
        p90_cell = fmt_ms(p90) if walls else "n/a"
        print(f"| {arm} | {n} | {len(succ)}/{n} | {wall_cell} | {iqr_cell} | {p90_cell} | {medt:.0f} | {first_fail:.0%} | {attempts:.0f} | {smp:.1f} |")

print("\n### Headline deltas (median wall-to-pass; printed only where BOTH arms pass N/N)\n")
for task in TASKS:
    for model in ["base", "tuned"]:
        un_all = groups.get((task, f"{model}-unconstrained", "temp0"), [])
        gr_all = groups.get((task, f"{model}-grammar", "temp0"), [])
        un = [r["wall_ms"] for r in un_all if r["success"]]
        gr = [r["wall_ms"] for r in gr_all if r["success"]]
        if un_all and gr_all and len(un) == len(un_all) and len(gr) == len(gr_all):
            mu, mg = q(un, 0.5), q(gr, 0.5)
            print(f"- {task} / {model}: unconstrained {mu:,.0f} ms -> grammar {mg:,.0f} ms  ({(1 - mg / mu) * 100:+.0f}%), both arms {len(gr)}/{len(gr_all)}")
        else:
            line = (f"- {task} / {model}: NOT comparable on time (oracle passes: "
                    f"unconstrained {len(un)}/{len(un_all)}, grammar {len(gr)}/{len(gr_all)}); "
                    f"pass rate is the result.")
            if un:
                line += f" Conditional-on-pass unconstrained median: {q(un, 0.5):,.0f} ms over {len(un)} passing runs."
            print(line)
