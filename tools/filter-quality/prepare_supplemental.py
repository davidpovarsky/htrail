#!/usr/bin/env python3
"""Supplemental control fixtures, independent of holdout predictions."""
import hashlib, json, time
from pathlib import Path
from urllib.request import urlopen, Request
from PIL import Image
HERE=Path(__file__).resolve().parent
DATA=HERE/".data"
out=DATA/"supplemental"
out.mkdir(exist_ok=True)
manifest=json.loads((DATA/"manifest.json").read_text())
excluded={r["id"] for r in json.loads((HERE/"composition-audit.json").read_text())["excluded"]}
rows=[]
for label in ("block","allow"):
    candidates=[r for r in manifest["rows"] if r["expected"]==label and r["split"]=="calibration" and r["source"]=="randomuser" and r["id"] not in excluded]
    selected=sorted(candidates,key=lambda r:hashlib.sha256(("supplemental-v1:"+r["id"]).encode()).hexdigest())[:4]
    for original in selected:
        for size in (64,96,128):
            for fmt,ext in (("JPEG","jpg"),("PNG","png"),("WEBP","webp")):
                im=Image.open(DATA/original["path"]).convert("RGB").resize((size,size),Image.Resampling.LANCZOS)
                identifier=original["id"]+"-"+str(size)+"-"+fmt.lower()
                target=out/(identifier+"."+ext)
                im.save(target,format=fmt,quality=85)
                row=dict(original)
                row.update(id=identifier,path=str(target.relative_to(DATA)),source="thumbnail/"+str(size)+"/"+fmt,split="calibration",source_group=original["source_group"],original_id=original["id"],transform={"size":size,"format":fmt,"quality":85},sha256=hashlib.sha256(target.read_bytes()).hexdigest(),width=size,height=size,mime=Image.MIME[fmt],bytes=target.stat().st_size)
                rows.append(row)
checks={
"brick.png":"7966caf324f6ba843118d98f7a07746d22f6a343430add0233eca5f6eaaa8fcf",
"chelsea.png":"596aa1e7cb875eb79f437e310381d26b338a81c2da23439704a73c4651e8c4bb",
"clock_motion.png":"f029226b28b642e80113d86622e9b215ee067a0966feaf5e60604a1e05733955",
"coffee.png":"cc02f8ca188b167c775a7101b5d767d1e71792cf762c33d6fa15a4599b5a8de7",
"coins.png":"f8d773fc9cfa6f4d8e5942dc34d0a0788fcaed2a4fefbbed0aef5398d7ef4cba",
"grass.png":"b6b6022426b38936c43a4ac09635cd78af074e90f42ffa8227ac8b7452d39f89",
"hubble_deep_field.jpg":"3a19c5dd8a927a9334bb1229a6d63711b1c0c767fb27e2286e7c84a3e2c2f5f4",
"moon.png":"78739619d11f7eb9c165bb5d2efd4772cee557812ec847532dbb1d92ef71f577",
"rocket.jpg":"c2dd0de7c538df8d111e479619b129464d0269d0ae5fd18ca91d33a7fdfea95c"}
errors=[]
for name,sha in checks.items():
    url="https://raw.githubusercontent.com/scikit-image/scikit-image/v0.25.2/skimage/data/"+name
    try:
        blob=urlopen(Request(url,headers={"User-Agent":"PurelineQA/1.0"}),timeout=20).read()
        if hashlib.sha256(blob).hexdigest()!=sha:raise ValueError("publisher registry SHA mismatch")
        target=out/("skimage-"+name);target.write_bytes(blob)
        im=Image.open(target)
        rows.append(dict(id="skimage-"+name,source="skimage-nonperson",source_group=name,source_url=url,label_source="https://scikit-image.org/docs/0.26.x/api/skimage.data.html",expected="allow",category="nonperson-control",sha256=sha,width=im.width,height=im.height,mime=Image.MIME[im.format],bytes=len(blob),path=str(target.relative_to(DATA)),split="calibration"))
    except Exception as exc:errors.append(dict(name=name,error=type(exc).__name__+": "+str(exc)))
payload=dict(created_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime()),label_method="Publisher labels inherited before inference; nonperson controls described by scikit-image docs and publisher registry hashes. Transforms do not increase independent-original sample size.",rows=rows,download_errors=errors)
target=DATA/"supplemental-calibration.json"
if target.exists():raise SystemExit("Manifest already exists")
target.write_text(json.dumps(payload,indent=2)+"\n")
print(json.dumps({"rows":len(rows),"independent_originals":len({r["source_group"] for r in rows}),"download_errors":errors,"sha256":hashlib.sha256(target.read_bytes()).hexdigest()}))
