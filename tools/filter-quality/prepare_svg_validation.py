#!/usr/bin/env python3
"""Prepare bounded public SVG controls and derived high-resolution fixtures."""
import base64,hashlib,json
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.request import Request,urlopen
from PIL import Image
HERE=Path(__file__).resolve().parent
svg=HERE/"results/svg/fixtures";svg.mkdir(parents=True,exist_ok=True)
public=json.loads((HERE/"evidence/svg-source-urls.json").read_text())["svg_candidate_urls"]
def fetch(pair):
 i,url=pair;target=svg/("wiki-svg-"+str(i).zfill(2)+".svg")
 blob=urlopen(Request(url,headers={"User-Agent":"PurelineQA/1.0 public UI fixture"}),timeout=25).read(1048577)
 target.write_bytes(blob)
 return dict(id=target.stem,path=str(target),source_url=url,expected="allow",source="Wikipedia UI icon/wordmark",sha256=hashlib.sha256(blob).hexdigest())
with ThreadPoolExecutor(max_workers=3)as pool:rows=list(pool.map(fetch,enumerate(public)))
main=json.loads((HERE/"corpus/main.json").read_text())
supp=json.loads((HERE/"corpus/supplemental.json").read_text())
original_ids=sorted({r["original_id"]for r in supp["rows"]if "original_id"in r})
for identifier in original_ids:
 r=next(r for r in main["rows"]if r["id"]==identifier)
 image=(HERE/".data"/r["path"]).read_bytes()
 uri="data:"+r["mime"]+";base64,"+base64.b64encode(image).decode()
 data=('<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128"><image width="128" height="128" href="'+uri+'"/></svg>').encode()
 target=svg/(identifier+".svg");target.write_bytes(data)
 rows.append(dict(id=identifier+"-svg",path=str(target),source_url=r["source_url"],expected=r["expected"],source="embedded calibration portrait",original_id=identifier,sha256=hashlib.sha256(data).hexdigest()))
(HERE/"corpus/svg-validation.json").write_text(json.dumps({"classification_samples_independent":False,"rows":rows},indent=2)+"\n")
pres=HERE/"results/presentation/fixtures";pres.mkdir(parents=True,exist_ok=True)
excluded={r["id"]for r in json.loads((HERE/"composition-audit.json").read_text())["excluded"]}
p_rows=[]
for expected in ["block","allow"]:
 candidates=[r for r in main["rows"]if r["source"]=="wikipedia"and r["split"]=="calibration"and r["expected"]==expected and r["id"]not in excluded]
 r=sorted(candidates,key=lambda r:r["id"])[0]
 image=Image.open(HERE/".data"/r["path"]).convert("RGB")
 for maximum in [1024,1536]:
  ratio=maximum/max(image.size);im=image.resize(tuple(round(d*ratio)for d in image.size),Image.Resampling.LANCZOS)
  name=r["id"]+"-"+str(maximum);target=pres/(name+".jpg");im.save(target,quality=95)
  p_rows.append(dict(id=name,path=str(target),expected=expected,width=im.width,height=im.height,original_id=r["id"],source_url=r["source_url"],sha256=hashlib.sha256(target.read_bytes()).hexdigest()))
(HERE/"corpus/presentation-validation.json").write_text(json.dumps({"derived_originals":2,"rows":p_rows},indent=2)+"\n")
print(json.dumps({"svg_cases":len(rows),"presentation_cases":len(p_rows)}))
