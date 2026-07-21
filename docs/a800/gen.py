#!/usr/bin/env python3
"""Generate docs/a800/index.html — the ACID800 fidelity-core conformance dashboard.

Data-driven and self-contained:
  * tests.json         — the test catalog (ordered, grouped, human titles)
  * runs/*.json        — one file per sweep; named <date>.json or <date>-<seq>.json
  * index.html (out)   — a single self-contained page (works from file:// and as an Artifact)

Each run file:
  { "date": "2026-07-20", "seq": 1, "core": "fid",
    "bitstream": "...", "note": "...",
    "results": { "cpu_decimal": {"s":"pass"},
                 "antic_vcount": {"s":"fail","d":"VCOUNT #3 wrong: $02 != $03"}, ... } }
  s ∈ pass | fail | error | na     d = optional failure detail

Regenerate:  python3 docs/a800/gen.py
"""
import json, os, glob, html

HERE = os.path.dirname(os.path.abspath(__file__))

def load():
    with open(os.path.join(HERE, "tests.json")) as f:
        cat = json.load(f)
    runs = []
    for p in sorted(glob.glob(os.path.join(HERE, "runs", "*.json"))):
        with open(p) as f:
            runs.append(json.load(f))
    # newest first; within a date, higher seq first
    runs.sort(key=lambda r: (r["date"], r.get("seq", 1)), reverse=True)
    for r in runs:
        date_runs = [x for x in runs if x["date"] == r["date"]]
        r["_label"] = r["date"] + (f" #{r.get('seq',1)}" if len(date_runs) > 1 else "")
    return cat, runs

def main():
    cat, runs = load()
    payload = {
        "groups": cat["groups"],
        "tests": cat["tests"],
        "runs": [
            {"id": i, "label": r["_label"], "date": r["date"], "seq": r.get("seq", 1),
             "core": r.get("core", "?"), "bitstream": r.get("bitstream", ""),
             "note": r.get("note", ""), "results": r.get("results", {})}
            for i, r in enumerate(runs)
        ],
    }
    data_json = json.dumps(payload, separators=(",", ":"))
    out = TEMPLATE.replace("/*DATA*/", data_json)
    with open(os.path.join(HERE, "index.html"), "w") as f:
        f.write(out)
    print(f"wrote index.html — {len(runs)} run(s), {len(cat['tests'])} tests")

TEMPLATE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ACID800 — fidelity-core conformance</title>
<style>
  :root{
    --bg:#f6f7f9; --panel:#fff; --ink:#1a1d21; --muted:#5b6570; --line:#dfe3e8;
    --pass:#1f9d55; --passbg:#e7f6ec; --fail:#d64545; --failbg:#fbeaea;
    --na:#9aa4ad; --nabg:#eef1f4; --accent:#2d6cdf; --accentbg:#e8f0ff;
  }
  @media (prefers-color-scheme:dark){
    :root{ --bg:#0f1216; --panel:#161b22; --ink:#e6edf3; --muted:#8b949e; --line:#2b333d;
      --pass:#3fb950; --passbg:#12251a; --fail:#f85149; --failbg:#2a1416;
      --na:#6e7681; --nabg:#1b2027; --accent:#589bff; --accentbg:#132238; }
  }
  :root[data-theme=light]{ --bg:#f6f7f9; --panel:#fff; --ink:#1a1d21; --muted:#5b6570; --line:#dfe3e8;
    --pass:#1f9d55; --passbg:#e7f6ec; --fail:#d64545; --failbg:#fbeaea; --na:#9aa4ad; --nabg:#eef1f4;
    --accent:#2d6cdf; --accentbg:#e8f0ff; }
  :root[data-theme=dark]{ --bg:#0f1216; --panel:#161b22; --ink:#e6edf3; --muted:#8b949e; --line:#2b333d;
    --pass:#3fb950; --passbg:#12251a; --fail:#f85149; --failbg:#2a1416; --na:#6e7681; --nabg:#1b2027;
    --accent:#589bff; --accentbg:#132238; }
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--ink);
    font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;}
  header{padding:18px 22px;border-bottom:1px solid var(--line);}
  header h1{margin:0 0 3px;font-size:18px;letter-spacing:.2px}
  header .sub{color:var(--muted);font-size:13px}
  .wrap{display:flex;align-items:flex-start;gap:0;min-height:calc(100vh - 62px)}
  aside{width:210px;flex:0 0 210px;border-right:1px solid var(--line);padding:14px 0;}
  aside h2{font-size:11px;text-transform:uppercase;letter-spacing:.7px;color:var(--muted);
    margin:0 0 8px;padding:0 16px}
  .run{display:block;width:100%;text-align:left;border:0;background:transparent;color:inherit;
    cursor:pointer;padding:8px 16px;border-left:3px solid transparent;font:inherit}
  .run:hover{background:var(--nabg)}
  .run.active{background:var(--accentbg);border-left-color:var(--accent)}
  .run .d{font-weight:600}
  .run .m{font-size:11.5px;color:var(--muted);margin-top:1px}
  .run .core{display:inline-block;font-size:10px;padding:0 5px;border-radius:8px;
    border:1px solid var(--line);margin-left:6px;vertical-align:1px}
  main{flex:1 1 auto;padding:16px 22px 40px;min-width:0}
  .meta{display:flex;flex-wrap:wrap;gap:10px 20px;align-items:baseline;margin-bottom:14px}
  .meta .big{font-size:22px;font-weight:700}
  .meta .pill{font-size:12px;color:var(--muted)}
  .bar{height:8px;border-radius:5px;background:var(--nabg);overflow:hidden;min-width:160px;flex:1 1 200px;max-width:340px}
  .bar > i{display:block;height:100%;background:var(--pass)}
  .group{margin:20px 0 6px}
  .group h3{font-size:13.5px;margin:0 0 2px;display:flex;align-items:baseline;gap:8px}
  .group h3 .cnt{font-size:12px;color:var(--muted);font-weight:400}
  .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(196px,1fr));gap:7px;margin-top:8px}
  .cell{display:flex;align-items:center;gap:8px;padding:7px 9px;border:1px solid var(--line);
    border-radius:7px;background:var(--panel);min-width:0}
  .cell .ic{flex:0 0 18px;width:18px;height:18px;border-radius:50%;display:grid;place-items:center;
    font-size:12px;font-weight:700;color:#fff}
  .cell.pass .ic{background:var(--pass)} .cell.pass{background:var(--passbg)}
  .cell.fail .ic{background:var(--fail)} .cell.fail{background:var(--failbg)}
  .cell.na .ic{background:var(--na)}     .cell.na{background:var(--nabg)}
  .cell .nm{min-width:0}
  .cell .t{font-weight:600;font-size:12.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .cell .n{font-size:10.5px;color:var(--muted);font-family:ui-monospace,Menlo,Consolas,monospace}
  .cell .d{font-size:11px;color:var(--fail);margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .legend{display:flex;gap:16px;flex-wrap:wrap;color:var(--muted);font-size:12px;margin:6px 0 2px}
  .legend span{display:inline-flex;align-items:center;gap:6px}
  .dot{width:11px;height:11px;border-radius:50%;display:inline-block}
  .toggle{float:right;font-size:12px;color:var(--muted);cursor:pointer;border:1px solid var(--line);
    background:transparent;border-radius:6px;padding:3px 9px}
  @media (max-width:720px){ .wrap{flex-direction:column} aside{width:100%;flex-basis:auto;
    border-right:0;border-bottom:1px solid var(--line)} }
</style>
</head>
<body>
<header>
  <button class="toggle" id="themebtn">theme</button>
  <h1>ACID800 conformance — fidelity 6502 core</h1>
  <div class="sub">Avery Lee's Altirra hardware-conformance suite, run on the fpga-xt fabric CPU. Green = pass, red = fail. Pick a dated run on the left to see progress over time.</div>
</header>
<div class="wrap">
  <aside>
    <h2>Runs</h2>
    <div id="runlist"></div>
  </aside>
  <main id="main"></main>
</div>
<script id="data" type="application/json">/*DATA*/</script>
<script>
const DATA = JSON.parse(document.getElementById('data').textContent);
const GROUPS = DATA.groups, TESTS = DATA.tests, RUNS = DATA.runs;
const ICON = {pass:'✓', fail:'✗', na:'–', error:'✗'};
function norm(s){ return s==='error'?'fail':(s||'na'); }

function renderList(active){
  const el = document.getElementById('runlist'); el.innerHTML='';
  RUNS.forEach(r=>{
    let pass=0,tot=0;
    TESTS.forEach(t=>{ const s=norm((r.results[t.name]||{}).s); if(s!=='na'){tot++; if(s==='pass')pass++;} });
    const b=document.createElement('button');
    b.className='run'+(r.id===active?' active':'');
    b.onclick=()=>select(r.id);
    b.innerHTML=`<div class="d">${r.label}<span class="core">${r.core}</span></div>`+
                `<div class="m">${pass}/${tot||TESTS.length} pass${r.note?' · '+escapeHtml(r.note):''}</div>`;
    el.appendChild(b);
  });
}

function render(run){
  const m=document.getElementById('main'); m.innerHTML='';
  let pass=0,fail=0,na=0;
  TESTS.forEach(t=>{ const s=norm((run.results[t.name]||{}).s);
    if(s==='pass')pass++; else if(s==='fail')fail++; else na++; });
  const tot=pass+fail;
  const pct=tot?Math.round(100*pass/tot):0;
  const meta=document.createElement('div'); meta.className='meta';
  meta.innerHTML=`<span class="big">${pass}/${tot}</span>`+
    `<span class="pill">passing (${pct}%)</span>`+
    `<div class="bar"><i style="width:${pct}%"></i></div>`+
    `<span class="pill">core: <b>${run.core}</b></span>`+
    (run.bitstream?`<span class="pill">bitstream: ${escapeHtml(run.bitstream)}</span>`:'')+
    (run.note?`<span class="pill">${escapeHtml(run.note)}</span>`:'');
  m.appendChild(meta);
  const lg=document.createElement('div'); lg.className='legend';
  lg.innerHTML=`<span><i class="dot" style="background:var(--pass)"></i>pass</span>`+
    `<span><i class="dot" style="background:var(--fail)"></i>fail</span>`+
    `<span><i class="dot" style="background:var(--na)"></i>not run</span>`;
  m.appendChild(lg);
  GROUPS.forEach(g=>{
    const gt=TESTS.filter(t=>t.group===g.key); if(!gt.length) return;
    let gp=0,gtot=0;
    gt.forEach(t=>{const s=norm((run.results[t.name]||{}).s); if(s!=='na'){gtot++; if(s==='pass')gp++;}});
    const gd=document.createElement('div'); gd.className='group';
    gd.innerHTML=`<h3>${escapeHtml(g.name)} <span class="cnt">${gp}/${gtot||gt.length}</span></h3>`;
    const grid=document.createElement('div'); grid.className='grid';
    gt.forEach(t=>{
      const r=run.results[t.name]||{}; const s=norm(r.s);
      const c=document.createElement('div'); c.className='cell '+s;
      c.title=t.title+(r.d?'\n'+r.d:'')+'  ['+t.name+']';
      c.innerHTML=`<span class="ic">${ICON[s]||ICON.na}</span>`+
        `<span class="nm"><div class="t">${escapeHtml(t.title)}</div>`+
        `<div class="n">${t.name}</div>`+
        (s==='fail'&&r.d?`<div class="d">${escapeHtml(r.d)}</div>`:'')+`</span>`;
      grid.appendChild(c);
    });
    gd.appendChild(grid); m.appendChild(gd);
  });
}

function select(id){ const run=RUNS.find(r=>r.id===id)||RUNS[0]; renderList(id); render(run);
  location.hash=encodeURIComponent(run.label); }
function escapeHtml(s){ return (s+'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c])); }

// theme toggle
const rootEl=document.documentElement;
document.getElementById('themebtn').onclick=()=>{
  const cur=rootEl.getAttribute('data-theme')||
    (matchMedia('(prefers-color-scheme:dark)').matches?'dark':'light');
  rootEl.setAttribute('data-theme', cur==='dark'?'light':'dark');
};

if(RUNS.length){
  const want=decodeURIComponent(location.hash.slice(1));
  const r=RUNS.find(x=>x.label===want);
  select(r?r.id:RUNS[0].id);
}else{
  document.getElementById('main').innerHTML='<p style="color:var(--muted)">No runs yet. Add a docs/a800/runs/&lt;date&gt;.json and regenerate.</p>';
}
</script>
</body>
</html>
"""

if __name__ == "__main__":
    main()
