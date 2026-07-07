#!/usr/bin/env python3
"""Per-field audit of what unconstrained arms actually emitted (medium task).

Reads the checked-in raw attempt contents (attempt_log[].content) and reports,
for every unconstrained medium attempt: did the extracted JSON contain each
declared key, and did each oracle predicate hold individually. This is the
evidence behind the 'unconstrained omits the email key' claim - rerun it
yourself against runs.jsonl.
"""
import json
import re
import sys
from collections import Counter

path = sys.argv[1] if len(sys.argv) > 1 else "results/runs.jsonl"
rows = [json.loads(l) for l in open(path) if l.strip()]


def extract_json(text):
    """Mirror of the harness/product lenient extraction."""
    text = text.strip()
    m = re.search(r"```(?:json)?\s*(.+?)```", text, re.S)
    if m:
        text = m.group(1).strip()
    s, e = text.find("{"), text.rfind("}")
    if s != -1 and e > s:
        text = text[s : e + 1]
    return text


keys = ["name", "age", "email", "address", "tags"]
pred_names = ["name~keller", "age==41", "email exact", "country~german"]

for arm in ["base-unconstrained", "tuned-unconstrained"]:
    key_present = Counter()
    preds = Counter()
    n_attempts = 0
    parse_fail = 0
    for r in rows:
        if r["task"] != "medium" or r["arm"] != arm:
            continue
        for att in r.get("attempt_log", []):
            n_attempts += 1
            try:
                obj = json.loads(extract_json(att["content"]))
            except Exception:
                parse_fail += 1
                continue
            if not isinstance(obj, dict):
                parse_fail += 1
                continue
            for k in keys:
                if k in obj:
                    key_present[k] += 1
            if "keller" in str(obj.get("name", "")).lower():
                preds["name~keller"] += 1
            if obj.get("age") == 41:
                preds["age==41"] += 1
            if obj.get("email") == "anna.keller@example.com":
                preds["email exact"] += 1
            addr = obj.get("address") or {}
            if isinstance(addr, dict) and str(addr.get("country", "")).lower().startswith("german"):
                preds["country~german"] += 1
    print(f"\n== medium / {arm}: {n_attempts} attempts, {parse_fail} raw-JSON parse failures ==")
    print("key present in emitted JSON:")
    for k in keys:
        print(f"  {k:8s} {key_present[k]}/{n_attempts - parse_fail}")
    print("oracle predicates held individually:")
    for p in pred_names:
        print(f"  {p:16s} {preds[p]}/{n_attempts - parse_fail}")
