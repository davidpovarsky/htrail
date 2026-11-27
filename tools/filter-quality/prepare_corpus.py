#!/usr/bin/env python3
"""Fetch public, publisher-labelled fixtures; freeze split before model inference.

Labels describe publisher categories and the configured image policy, not a claim
about anyone's identity. RandomUser portraits and Wikipedia biographical categories
are a narrow, weakly labelled benchmark, not a representative whole-web sample.
"""
from __future__ import annotations
import argparse, concurrent.futures, hashlib, io, json, random, time, urllib.parse, urllib.request
from pathlib import Path
from collections import Counter
from PIL import Image

AGENT = "Pureline-QA/1.0 (bounded public image-filter evaluation)"
def fetch(url):
    for attempt in range(2):
        try:
            request=urllib.request.Request(url, headers={"User-Agent":AGENT})
            with urllib.request.urlopen(request, timeout=25) as r:
                if r.status != 200: raise RuntimeError(f"HTTP {r.status}")
                return r.read()
        except Exception:
            if attempt: raise
            time.sleep(.8)

def wikipedia(category, target=75):
    rows=[]; cont={}; seen=set()
    for _ in range(5):
        args=dict(action="query",format="json",generator="categorymembers",
                  gcmtitle="Category:"+category,gcmtype="page",gcmnamespace=0,gcmlimit=100,
                  prop="pageimages",pithumbsize=480,pilicense="free",**cont)
        data=json.loads(fetch("https://en.wikipedia.org/w/api.php?"+urllib.parse.urlencode(args)))
        for page in data.get("query",{}).get("pages",{}).values():
            title=page.get("title","")
            if not page.get("thumbnail") or title.startswith(("List of ","Category:")): continue
            file_id=page.get("pageimage","")
            if file_id in seen: continue
            seen.add(file_id)
            rows.append(dict(id=f"wikipedia-{page['pageid']}",source="wikipedia",source_group=file_id,
                             source_url=page["thumbnail"]["source"],
                             label_source="https://en.wikipedia.org/wiki/Category:"+category,
                             subject=title,publisher_category=category))
            if len(rows)>=target:return rows
        cont=data.get("continue")
        if not cont:break
    return rows

def main():
    ap=argparse.ArgumentParser();ap.add_argument("--data",type=Path,required=True);args=ap.parse_args()
    root=args.data; (root/"images").mkdir(parents=True,exist_ok=True)
    manifest=root/"manifest.json"
    if manifest.exists():raise SystemExit("Manifest already frozen; do not rewrite an evaluated split.")
    records=[]
    for category,expected in [("women","block"),("men","allow")]:
        for i in range(100):
            records.append(dict(id=f"randomuser-{category}-{i:02d}",source="randomuser",
              source_group=f"randomuser-{category}-{i}",source_url=f"https://randomuser.me/api/portraits/{category}/{i}.jpg",
              expected=expected,category="portrait",publisher_category=category,
              label_source="https://randomuser.me/photos/"))
    for category,expected in [("American_film_actresses","block"),("American_male_film_actors","allow")]:
        try:
            rows=wikipedia(category)
            for row in rows:row.update(expected=expected,category="biographical-photo")
            records.extend(rows)
            print(json.dumps({"category":category,"discovered":len(rows)}),flush=True)
        except Exception as exc:print(json.dumps({"category":category,"error":str(exc)}),flush=True)
    old_hashes={hashlib.sha256(p.read_bytes()).hexdigest() for p in Path("/srv/pureline-poc/official-candidate/fixtures").glob("*.jpg")}
    def download(row):
        row=dict(row)
        try:
            content=fetch(row["source_url"]); image=Image.open(io.BytesIO(content));image.verify()
            image=Image.open(io.BytesIO(content))
            row.update(sha256=hashlib.sha256(content).hexdigest(),width=image.width,height=image.height,
                       mime=Image.MIME.get(image.format,"image/jpeg"),bytes=len(content))
            if image.width<90 or image.height<90:raise ValueError("source too small for main evaluation")
            row["path"]=f"images/{row['id']}.jpg";(root/row["path"]).write_bytes(content)
            row["historical_fixture"]=row["sha256"] in old_hashes
            return row
        except Exception as exc:
            return {"id":row["id"],"source_url":row["source_url"],"error":str(exc)}
    good=[];errors=[]
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        for row in pool.map(download, records):
            (errors if "error" in row else good).append(row)
            if (len(good)+len(errors))%25==0:print(json.dumps({"downloaded":len(good),"failed":len(errors)}),flush=True)
    unique=[]; seen={}
    for row in good:
        if row["sha256"] in seen:
            row["duplicate_of"]=seen[row["sha256"]];errors.append(row);continue
        seen[row["sha256"]]=row["id"];unique.append(row)
    # Immutable randomized split with fixed source-stratification, before any scores.
    for source in sorted({r["source"] for r in unique}):
        for expected in ["allow","block"]:
            group=[r for r in unique if r["source"]==source and r["expected"]==expected]
            group.sort(key=lambda r:hashlib.sha256(("pureline-v1:"+r["source_group"]).encode()).hexdigest())
            ncal=max(1,round(len(group)*.25))
            for i,row in enumerate(group):
                row["split"]="calibration" if i<ncal or row["historical_fixture"] else "holdout"
    payload=dict(version=1,created_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime()),
      label_method="Publisher-category labels, frozen before inference; biographical photos require manual group/ambiguity audit.",
      limitations=["Portrait/biographical-photo benchmark; no explicit nudity data.","Does not measure whole-web or app coverage.",
        "Category membership labels subject, so photos may require mixed-group ambiguity review.","No model-generated labels."],
      rows=unique,download_errors=errors)
    manifest.write_text(json.dumps(payload,ensure_ascii=False,indent=2)+"\n")
    digest=hashlib.sha256(manifest.read_bytes()).hexdigest()
    (root/"manifest.sha256").write_text(digest+"\n")
    print(json.dumps({"manifest":str(manifest),"sha256":digest,"counts":dict(Counter((r["split"]+":"+r["expected"]) for r in unique)),
                      "sources":dict(Counter(r["source"] for r in unique)),"errors":len(errors),"bytes":sum(r["bytes"] for r in unique)}),flush=True)
if __name__=="__main__":main()
