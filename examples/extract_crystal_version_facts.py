#!/usr/bin/env python3
"""Extract version-aware Crystal facts by diffing the stdlib source between two
release tags (default 1.14.0 -> 1.20.0) in a local crystal checkout. Produces a
kind-tagged JSONL corpus of Q/A pairs the model can learn so it answers version
questions instead of guessing. Stdlib only (git + regex).

  python3 examples/extract_crystal_version_facts.py [CRYSTAL_REPO] [OLD_TAG] [NEW_TAG]
"""
import json, os, re, subprocess, sys

REPO = sys.argv[1] if len(sys.argv) > 1 else "/Users/crimsonknight/open_source_coding_projects/crystal"
OLD = sys.argv[2] if len(sys.argv) > 2 else "1.14.0"
NEW = sys.argv[3] if len(sys.argv) > 3 else "1.20.0"
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "training_data", "crystal", "version_facts.jsonl")

def git(*args):
    return subprocess.run(["git", "-C", REPO, *args], capture_output=True, text=True).stdout

DEP_RE = re.compile(r'@\[Deprecated\((?:"([^"]*)")?')
SYM_RE = re.compile(r'^\s*(?:def|macro|class|struct|module|enum|abstract def|abstract class)\s+([A-Za-z_][\w:.#?!=]*)')

def deprecations(tag):
    """ {symbol: message} for @[Deprecated] annotations in src/ at `tag`. """
    out = git("grep", "-n", "-A1", "-e", r"@\[Deprecated", tag, "--", "src/*.cr")
    found = {}
    lines = out.splitlines()
    for i, ln in enumerate(lines):
        m = DEP_RE.search(ln)
        if not m:
            continue
        msg = m.group(1) or ""
        # the symbol is on a following context line (prefixed `tag-file-lineno-` or `tag:file:lineno:`)
        for j in range(i + 1, min(i + 4, len(lines))):
            body = re.sub(r'^[^:]+[:\-][^:]+[:\-]\d+[:\-]', '', lines[j])
            sm = SYM_RE.match(body)
            if sm:
                found[sm.group(1)] = msg
                break
    return found

def dirs_at(tag):
    """ set of directories under src/ present at `tag` (so we can find NEW ones). """
    out = git("ls-tree", "-r", "--name-only", tag, "--", "src/")
    ds = set()
    for path in out.splitlines():
        parts = path.split("/")
        for i in range(2, len(parts)):           # src/a, src/a/b, ...
            ds.add("/".join(parts[:i]))
    return ds

def new_subsystems(old, new):
    """ directories that EXIST at `new` but did NOT exist at `old` (genuinely new). """
    return sorted(dirs_at(new) - dirs_at(old))

def example_file(tag, d):
    out = git("ls-tree", "-r", "--name-only", tag, "--", d + "/")
    files = [l for l in out.splitlines() if l.endswith(".cr")]
    return files[0] if files else d

pairs = []
def add(prompt, completion, kind="pair"):
    pairs.append({"kind": kind, "prompt": prompt, "completion": completion})

dep_old, dep_new = deprecations(OLD), deprecations(NEW)
newly_deprecated = {s: m for s, m in dep_new.items() if s not in dep_old}

for sym, msg in sorted(newly_deprecated.items()):
    hint = f" {msg}" if msg else ""
    add(f"Is `{sym}` deprecated in Crystal {NEW}?",
        f"Yes — `{sym}` is deprecated as of Crystal {NEW} (it was not deprecated in {OLD}).{(' ' + msg) if msg else ''}".strip())

# Genuinely-new subsystems: directories present at NEW but absent at OLD.
new_dirs = new_subsystems(OLD, NEW)
for d in new_dirs:
    sample = example_file(NEW, d)
    add(f"Is `{d}` available in Crystal {OLD}?",
        f"No — `{d}/` was added after Crystal {OLD} and is present in {NEW} (e.g. `{sample}`). It is not available in {OLD}.")

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w") as f:
    for p in pairs:
        f.write(json.dumps(p) + "\n")

print(f"crystal {OLD} -> {NEW}")
print(f"  newly-deprecated symbols: {len(newly_deprecated)}")
print(f"  new src subsystems: {len(new_dirs)} -> {new_dirs[:12]}")
print(f"  wrote {len(pairs)} version-fact pairs -> {OUT}")
# show the two flagship examples if present
for s in ("monotonic", "ExecutionContext"):
    hits = [p for p in pairs if s.lower() in (p['prompt'] + p['completion']).lower()]
    if hits:
        print(f"  [{s}] {hits[0]['completion'][:120]}")
