#!/usr/bin/env python3
"""Restore public fixtures by pinned SHA; never substitute model-generated labels."""
import argparse, hashlib, io, json, shutil
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.parse import urlparse
from PIL import Image
HERE=Path(__file__).resolve().parent
p=argparse.ArgumentParser()
p.add_argument("--manifest",type=Path,default=HERE/"corpus/main.json")
p.add_argument("--dest",type=Path,default=HERE/".data")
args=p.parse_args()
args.dest.mkdir(parents=True,exist_ok=True)
manifest_bytes=args.manifest.read_bytes();manifest=json.loads(manifest_bytes)
main=json.loads((HERE/"corpus/main.json").read_text())
by_id={r["id"]:r for r in main["rows"]}
def restore(r):
    target=(args.dest/r["path"]).resolve()
    if not target.is_relative_to(args.dest.resolve()):raise ValueError("Fixture path escapes destination")
    if target.exists():
        if hashlib.sha256(target.read_bytes()).hexdigest()==r["sha256"]:return None
        return {"id":r["id"],"error":"Existing fixture differs; use a fresh destination"}
    try:
        if "transform"in r:
            original=by_id[r["original_id"]]
            source=args.dest/original["path"]
            if not source.exists() or hashlib.sha256(source.read_bytes()).hexdigest()!=original["sha256"]:
                raise ValueError("Restore the main corpus first")
            t=r["transform"]
            im=Image.open(source).convert("RGB").resize((t["size"],t["size"]),Image.Resampling.LANCZOS)
            buffer=io.BytesIO();im.save(buffer,format=t["format"],quality=t["quality"]);data=buffer.getvalue()
        else:
            if urlparse(r["source_url"]).scheme!="https":raise ValueError("Expected a public HTTPS fixture URL")
            data=urlopen(Request(r["source_url"],headers={"User-Agent":"PurelineQA/1.0 public-fixture-replay"}),timeout=25).read()
        if hashlib.sha256(data).hexdigest()!=r["sha256"]:raise ValueError("Pinned SHA mismatch; do not silently replace original")
        target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
        return None
    except Exception as e:return {"id":r["id"],"error":type(e).__name__+": "+str(e)}
with ThreadPoolExecutor(max_workers=3)as pool:errors=[x for x in pool.map(restore,manifest["rows"])if x]
name="supplemental-calibration.json"if any("transform"in r for r in manifest["rows"])else"manifest.json"
out=args.dest/name
if out.exists()and out.read_bytes()!=manifest_bytes:raise SystemExit("Destination manifest differs; preserve old evidence and use a fresh directory")
if not errors:out.write_bytes(manifest_bytes)
(args.dest/"restore-errors.json").write_text(json.dumps(errors,indent=2)+"\n")
print(json.dumps({"count":len(manifest["rows"]),"errors":len(errors),"manifest_written":not errors}))
raise SystemExit(bool(errors))
