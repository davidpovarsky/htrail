#!/usr/bin/env python3
"""Create finite browser QA galleries from previously labeled public originals."""
import hashlib, html, json
from pathlib import Path
HERE=Path(__file__).resolve().parent
manifest=json.loads((HERE/".data/manifest.json").read_text())
excluded={r["id"] for r in json.loads((HERE/"composition-audit.json").read_text())["excluded"]}
eligible=[r for r in manifest["rows"] if r["id"]not in excluded]
def pick(label,source,count):
    return sorted([r for r in eligible if r["expected"]==label and r["source"]==source and r["split"]=="holdout"],key=lambda r:hashlib.sha256(("gallery-v1:"+r["id"]).encode()).hexdigest())[:count]
allows=pick("allow","randomuser",6)+pick("allow","wikipedia",4)
blocks=pick("block","randomuser",6)+pick("block","wikipedia",4)
supp=json.loads((HERE/".data/supplemental-calibration.json").read_text())
objects=[r for r in supp["rows"] if r["source"]=="skimage-nonperson"]
groups=[r for r in eligible if r["id"] in {"wikipedia-105969","wikipedia-63005541"}]
cal={}
for r in supp["rows"]:
    if r["source"].startswith("thumbnail/"):
        cal.setdefault(r["original_id"],next(x for x in eligible if x["id"]==r["original_id"]))
thumbs=[]
for orig in cal.values():
    for directory in ("med","thumb"):
        r=dict(orig)
        r["id"] += "-published-"+directory
        r["source_url"]=orig["source_url"].replace("/portraits/","/portraits/"+directory+"/")
        r["category"]="published-"+directory+"-thumbnail"
        thumbs.append(r)
pages={"allow":allows,"block":blocks,"mixed":[x for pair in zip(allows,blocks) for x in pair],"objects":objects,"groups":groups,"thumbnails":thumbs}
dest=HERE/"gallery";dest.mkdir(exist_ok=True)
nav=' '.join('<a href="'+key+'.html">'+key+'</a>' for key in pages)
style='body{font:16px system-ui;background:#f4f7fb;color:#112134;margin:24px}nav{display:flex;gap:18px;flex-wrap:wrap}a{color:#1454b5}h1{margin-bottom:8px}.note{max-width:950px;line-height:1.5}.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));gap:16px;margin-top:24px}figure{background:white;margin:0;border:1px solid #d3ddea;border-radius:12px;padding:12px}img{display:block;width:100%;height:210px;object-fit:contain;background:#e9edf3}figcaption{font-size:13px;margin-top:10px;overflow-wrap:anywhere}.allow{color:#166534}.block{color:#9f1239}#loaded{font-weight:700}'
for name,rows in pages.items():
    cards=[]
    for r in rows:
        url=r["source_url"]+("&" if "?" in r["source_url"] else "?")+"pureline_qa=20261127_gallery_v1"
        cards.append('<figure><img loading="eager" src="'+html.escape(url,quote=True)+'" alt="'+html.escape(r["id"],quote=True)+'"><figcaption><strong class="'+r["expected"]+'">Expected '+r["expected"].upper()+'</strong><br>'+html.escape(r["id"])+'<br>'+html.escape(r.get("category",r["source"]))+'</figcaption></figure>')
    doc='<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Pureline QA — '+name+'</title><style>'+style+'</style><nav>'+nav+'</nav><h1>Pureline browser QA: '+name+'</h1><p class="note">Public, prelabelled fixtures for the configured policy. Required blocks should show a rewritten image; allowed images should remain visible. These pages reuse benchmark originals and do not add independent holdout samples. The thumbnail page deliberately tests published small images.</p><p id="loaded">Loading...</p><main class="grid">'+''.join(cards)+'</main><script>let ok=0,errors=0;const seen=new WeakSet;const imgs=[...document.images];function count(){document.querySelector("#loaded").textContent=ok+" / "+imgs.length+" loaded; "+errors+" errors"}function done(i,success){if(seen.has(i))return;seen.add(i);if(success){ok++;i.dataset.natural=i.naturalWidth+"x"+i.naturalHeight}else errors++;count()}for(const i of imgs){i.addEventListener("load",()=>done(i,true));i.addEventListener("error",()=>done(i,false));if(i.complete)done(i,!!i.naturalWidth)}count();</script></html>'
    (dest/(name+".html")).write_text(doc)
(dest/"index.html").write_text('<!doctype html><meta charset="utf-8"><title>Pureline public browser QA</title><style>'+style+'</style><h1>Pureline public browser QA</h1><nav>'+nav+'</nav><p>Use each finite gallery through the actual WireGuard proxy. No fixture is independent of the corpus described in the manifest.</p>')
(dest/"manifest.json").write_text(json.dumps({"purpose":"Real browser transport/rewrite checks, not independent quality sample","pages":{k:[{key:r[key] for key in ["id","expected","source_url","source_group"]} for r in rs]for k,rs in pages.items()}},indent=2)+"\n")
print(json.dumps({name:len(rows)for name,rows in pages.items()}))
