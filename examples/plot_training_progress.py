#!/usr/bin/env python3
"""Render honesty-training run metrics (training_data/metrics/honesty_runs.jsonl)
to an SVG so progress is visually explainable. Stdlib only (no matplotlib).

  python3 examples/plot_training_progress.py [out.svg]
"""
import json, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MDIR = os.path.join(ROOT, "training_data", "metrics")
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(MDIR, "honesty_progress.svg")

runs = []
for log in ("honesty_runs.jsonl", "crystal_runs.jsonl"):
    p = os.path.join(MDIR, log)
    if os.path.exists(p):
        runs += [json.loads(l) for l in open(p) if l.strip()]

W, H = 1040, 560
PANEL_X, PANEL_Y, PANEL_W, PANEL_H = 60, 70, 770, 360
y0, y1 = PANEL_Y + PANEL_H, PANEL_Y           # reward 0 .. 1 maps y0 .. y1
COLORS = {"good": "#2e9e5b", "bad": "#cf3b3b", "neutral": "#3b6fcf"}

def yv(r):  # reward -> y
    return y0 - (y0 - y1) * max(0.0, min(1.0, r))

parts = []
def add(s): parts.append(s)

add(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" font-family="Helvetica,Arial,sans-serif">')
add(f'<rect width="{W}" height="{H}" fill="#ffffff"/>')
add(f'<text x="30" y="38" font-size="22" font-weight="bold">Honesty training progress — mean FSDD reward per stage</text>')

# --- left panel: reward trajectories ---
# gridlines + y labels
for g in (0.0, 0.25, 0.5, 0.75, 1.0):
    gy = yv(g)
    add(f'<line x1="{PANEL_X}" y1="{gy:.0f}" x2="{PANEL_X+PANEL_W}" y2="{gy:.0f}" stroke="#e6e6e6"/>')
    add(f'<text x="{PANEL_X-10}" y="{gy+4:.0f}" font-size="11" fill="#888" text-anchor="end">{g:.2f}</text>')
# reward-ladder bands on the right edge of panel
bands = [(0.0,0.1,"foreign/syntax (lying)","#f3dada"),(0.1,0.5,"fabricated / wrong","#f7eede"),
         (0.5,0.7,"honest scaffold","#dff0e4"),(0.7,1.0,"grounded + compiles","#cfe8d6")]
for lo,hi,lab,col in bands:
    add(f'<rect x="{PANEL_X+PANEL_W+6}" y="{yv(hi):.0f}" width="14" height="{yv(lo)-yv(hi):.0f}" fill="{col}"/>')

xstep = PANEL_W / (len(runs) + 1)
for i, run in enumerate(runs):
    cx = PANEL_X + xstep * (i + 1)
    col = COLORS["good" if "improv" in run.get("outcome", "") else "bad"]
    stages = run["stages"]
    sw = min(120, xstep * 0.7)
    xs = [cx - sw/2 + sw * (j/(len(stages)-1)) for j in range(len(stages))]
    # connecting line
    pts = " ".join(f"{xs[j]:.0f},{yv(stages[j]['reward']):.0f}" for j in range(len(stages)))
    add(f'<polyline points="{pts}" fill="none" stroke="{col}" stroke-width="2.5"/>')
    for j, st in enumerate(stages):
        px, py = xs[j], yv(st["reward"])
        add(f'<circle cx="{px:.0f}" cy="{py:.0f}" r="5" fill="{col}"/>')
        add(f'<text x="{px:.0f}" y="{py-9:.0f}" font-size="10" fill="#333" text-anchor="middle">{st["reward"]:.2f}</text>')
        add(f'<text x="{px:.0f}" y="{y0+14+(j%2)*13:.0f}" font-size="9" fill="#666" text-anchor="middle">{st["name"]}</text>')
    add(f'<text x="{cx:.0f}" y="{y0+42:.0f}" font-size="12" font-weight="bold" fill="{col}" text-anchor="middle">{run["run"]}</text>')
    add(f'<text x="{cx:.0f}" y="{y0+56:.0f}" font-size="9" fill="#888" text-anchor="middle">{run["outcome"][:34]}</text>')

add(f'<text x="{PANEL_X+PANEL_W-14}" y="{PANEL_Y-12}" font-size="11" fill="#555" text-anchor="end">reward bands →</text>')
for lo, hi, lab, col in bands:
    add(f'<text x="{PANEL_X+PANEL_W+24}" y="{(yv(lo)+yv(hi))/2+3:.0f}" font-size="8.5" fill="#777">{lab}</text>')

add(f'<text x="30" y="{H-30}" font-size="11" fill="#777">Green = the monotonic guard kept the model improving; red = collapsed (no guard / re-quant drift). The guard rolls back any regressing stage.</text>')
add(f'<text x="30" y="{H-15}" font-size="11" fill="#777">crystal@1.20 filter: unsupervised stdlib stage KEPT (compile 3/6&#8594;5/6, reward 0.5&#8594;0.83); SFT + GRPO regressed and were dropped.</text>')
add('</svg>')

open(OUT, "w").write("\n".join(parts))
print("wrote", OUT)
