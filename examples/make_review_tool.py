#!/usr/bin/env python3
"""Turn a pairs JSONL into a self-contained HTML review tool (no server, no deps).
Open the HTML in a browser, review each pair fast (keyboard: a/r/e approve/reject/
edit, j/k or arrows to move), leave notes / edit the code inline, and Export your
decisions as JSON. Decisions persist in localStorage so you can resume.

  python3 examples/make_review_tool.py <pairs.jsonl> [out.html]
"""
import json, os, sys, html

src = sys.argv[1]
out = sys.argv[2] if len(sys.argv) > 2 else os.path.splitext(src)[0] + "_review.html"

pairs = []
for i, line in enumerate(open(src)):
    line = line.strip()
    if not line:
        continue
    d = json.loads(line)
    pairs.append({
        "id": i,
        "prompt": d.get("prompt", ""),
        "completion": d.get("completion", ""),
        "category": d.get("category", d.get("topic", "")),
        "kind_of": d.get("kind_of", ""),
    })

DATA = json.dumps(pairs)
DATASET_ID = os.path.basename(src)

TEMPLATE = r"""<!doctype html><html><head><meta charset="utf-8">
<title>Crystal corpus review — __DATASET__</title>
<style>
 :root{--bg:#0f1115;--panel:#171a21;--ink:#e6e6e6;--muted:#9aa4b2;--green:#2e9e5b;--red:#cf3b3b;--amber:#d99a2b;--blue:#3b6fcf}
 *{box-sizing:border-box} body{margin:0;font:14px/1.5 -apple-system,Helvetica,Arial,sans-serif;background:var(--bg);color:var(--ink)}
 header{position:sticky;top:0;background:var(--panel);padding:10px 16px;display:flex;gap:14px;align-items:center;border-bottom:1px solid #262b36;flex-wrap:wrap}
 header b{font-size:15px} .counts span{margin-right:10px;font-size:12px}
 .pill{padding:2px 8px;border-radius:10px;font-size:12px} .a{background:#16331f;color:#7fd6a0} .r{background:#3a1a1a;color:#e89090} .e{background:#3a2f12;color:#e8c879} .u{background:#23262e;color:var(--muted)}
 button{font:13px inherit;background:#23262e;color:var(--ink);border:1px solid #333a47;border-radius:6px;padding:6px 10px;cursor:pointer}
 button:hover{border-color:#4a5568} .grow{flex:1}
 main{max-width:1000px;margin:18px auto;padding:0 16px}
 .meta{color:var(--muted);font-size:12px;margin-bottom:6px}
 .directive{background:var(--panel);border-left:3px solid var(--blue);padding:12px 14px;border-radius:6px;white-space:pre-wrap;font-size:15px}
 .label{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.05em;margin:16px 0 6px}
 textarea{width:100%;background:#0b0d11;color:#d7e0ea;border:1px solid #262b36;border-radius:6px;padding:12px;font:13px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;tab-size:2}
 .code{min-height:240px} .notes{min-height:70px;font-family:inherit}
 .bar{display:flex;gap:8px;margin:14px 0;align-items:center;flex-wrap:wrap}
 .verdict{font-weight:bold} kbd{background:#262b36;border-radius:4px;padding:1px 6px;font-size:11px;color:var(--muted)}
 .nav{margin-left:auto}
</style></head><body>
<header>
 <b>Crystal corpus review</b><span class="meta">__DATASET__</span>
 <div class="counts" id="counts"></div>
 <div class="nav">
   <button onclick="exportJSON()">⬇ Export decisions</button>
   <button onclick="jump('next-unreviewed')">Next unreviewed</button>
 </div>
</header>
<main>
 <div class="meta" id="pos"></div>
 <div class="label">Directive (prompt)</div>
 <div class="directive" id="prompt"></div>
 <div class="bar">
   <button onclick="setVerdict('approve')" style="border-color:var(--green)">✓ Approve <kbd>a</kbd></button>
   <button onclick="setVerdict('reject')" style="border-color:var(--red)">✗ Reject <kbd>r</kbd></button>
   <button onclick="setVerdict('edit')" style="border-color:var(--amber)">✎ Needs edit <kbd>e</kbd></button>
   <span class="verdict pill u" id="verdict">unreviewed</span>
   <span class="nav"><button onclick="jump(-1)">◀ <kbd>k</kbd></button> <button onclick="jump(1)"><kbd>j</kbd> ▶</button></span>
 </div>
 <div class="label">Completion (editable — your fixes are saved)</div>
 <textarea class="code" id="code" spellcheck="false" oninput="onEdit()"></textarea>
 <div class="label">Notes / change recommendations</div>
 <textarea class="notes" id="notes" oninput="onNote()" placeholder="What to change, why reject, anything for the next round..."></textarea>
</main>
<script>
const PAIRS = __DATA__;
const KEY = "crystalreview:" + "__DATASET__";
let state = JSON.parse(localStorage.getItem(KEY) || "{}");   // id -> {verdict, notes, edited}
let i = state.__pos__ || 0;
function save(){ state.__pos__ = i; localStorage.setItem(KEY, JSON.stringify(state)); }
function cur(){ return PAIRS[i]; }
function rec(){ const p=cur(); return state[p.id] || (state[p.id]={verdict:"unreviewed",notes:"",edited:null}); }
function render(){
  const p=cur(), r=rec();
  document.getElementById('pos').textContent = `Pair ${i+1} / ${PAIRS.length}  ·  ${p.category||''} ${p.kind_of?('· '+p.kind_of):''}  ·  id ${p.id}`;
  document.getElementById('prompt').textContent = p.prompt;
  document.getElementById('code').value = (r.edited!=null? r.edited : p.completion);
  document.getElementById('notes').value = r.notes||"";
  const v=document.getElementById('verdict'); v.textContent=r.verdict;
  v.className = "verdict pill " + ({approve:"a",reject:"r",edit:"e"}[r.verdict]||"u");
  renderCounts(); save();
}
function renderCounts(){
  let a=0,rj=0,e=0,u=0;
  PAIRS.forEach(p=>{const v=(state[p.id]||{}).verdict; if(v=="approve")a++;else if(v=="reject")rj++;else if(v=="edit")e++;else u++;});
  document.getElementById('counts').innerHTML =
    `<span class="pill a">✓ ${a}</span><span class="pill r">✗ ${rj}</span><span class="pill e">✎ ${e}</span><span class="pill u">· ${u} left</span>`;
}
function setVerdict(v){ rec().verdict=v; if(v=="approve"||v=="reject"){jump(1);} else {render();} }
function onNote(){ rec().notes=document.getElementById('notes').value; save(); renderCounts(); }
function onEdit(){ const p=cur(); const val=document.getElementById('code').value; rec().edited = (val==p.completion? null : val); save(); }
function jump(d){
  if(d=='next-unreviewed'){ for(let k=1;k<=PAIRS.length;k++){const j=(i+k)%PAIRS.length; if(((state[PAIRS[j].id]||{}).verdict||'unreviewed')=='unreviewed'){i=j;break;}} }
  else { i=Math.max(0,Math.min(PAIRS.length-1,i+d)); }
  render();
}
function exportJSON(){
  const dec=PAIRS.map(p=>{const r=state[p.id]||{}; return {id:p.id,category:p.category,prompt:p.prompt,verdict:r.verdict||"unreviewed",notes:r.notes||"",edited_completion:r.edited||null};});
  const blob=new Blob([JSON.stringify(dec,null,2)],{type:"application/json"});
  const a=document.createElement('a'); a.href=URL.createObjectURL(blob); a.download="review_decisions.json"; a.click();
}
document.addEventListener('keydown',ev=>{
  if(['TEXTAREA','INPUT'].includes(ev.target.tagName)) return;
  if(ev.key=='a')setVerdict('approve'); else if(ev.key=='r')setVerdict('reject'); else if(ev.key=='e')setVerdict('edit');
  else if(ev.key=='j'||ev.key=='ArrowRight')jump(1); else if(ev.key=='k'||ev.key=='ArrowLeft')jump(-1);
});
render();
</script></body></html>"""

doc = (TEMPLATE.replace("__DATA__", DATA).replace("__DATASET__", html.escape(DATASET_ID)))
open(out, "w").write(doc)
print(f"wrote {out} ({len(pairs)} pairs)")
