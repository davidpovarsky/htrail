#!/usr/bin/env python3
"""Validate frozen outputs and independently aggregate audit exclusions."""
import hashlib, importlib.util, json, math
from collections import Counter
from pathlib import Path
from PIL import Image
HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location("quality_runner",HERE/"run_quality.py")
mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def wilson(k,n):
    if not n:return None
    z=1.959963984540054;p=k/n;d=1+z*z/n
    c=(p+z*z/(2*n))/d
    h=z*math.sqrt(p*(1-p)/n+z*z/(4*n*n))/d
    return [round(100*(c-h),3),round(100*(c+h),3)]
audit=json.loads((HERE/"composition-audit.json").read_text())
excluded={r["id"]for r in audit["excluded"]}
manifest=json.loads((HERE/".data/manifest.json").read_text())
by_sha={}
for r in manifest["rows"]:
    if r["sha256"]in by_sha:raise AssertionError("Duplicate original in corpus")
    by_sha[r["sha256"]]=r
report={"manifest_sha256":digest(HERE/".data/manifest.json"),"audit_sha256":digest(HERE/"composition-audit.json"),"unique_originals":len(by_sha),"composition_exclusions":len(excluded),"source_group_overlap_between_splits":len({r["source_group"]for r in manifest["rows"]if r["split"]=="calibration"}&{r["source_group"]for r in manifest["rows"]if r["split"]=="holdout"}),"runs":{}}
assert report["source_group_overlap_between_splits"]==0
for name in ["official-calibration-v2","official-holdout-frozen-v1","supplemental-calibration-v1"]:
    p=HERE/"results"/name
    rows=[json.loads(l)for l in(p/"results.jsonl").read_text().splitlines()]
    counted=[r for r in rows if r["id"]not in excluded]
    s=mod.summary(counted)
    rewrites=unchanged=0
    for r in rows:
        assert not r.get("error"),(r["id"],r.get("error"))
        assert r["model_evidence_complete"],r["id"]
        if r["action"] in {"blur","replace"}:
            assert r["replacement_exists"] and r["replacement_differs"],r["id"]
            f=p/"processed"/(r["id"]+".jpg")
            assert digest(f)==r["replacement_sha256"],r["id"]
            with Image.open(f)as im:im.verify()
            rewrites+=1
        else:
            assert r["action"]=="allow"and not r["replacement_exists"],r["id"]
            unchanged+=1
    if not name.startswith("supplemental"):
        s["block_recall_wilson_95_pct"]=wilson(s["TP"],s["TP"]+s["FN"])
        s["allow_specificity_wilson_95_pct"]=wilson(s["TN"],s["TN"]+s["FP"])
    else:s["confidence_interval_omitted"]="Correlated transforms of eight originals"
    report["runs"][name]={"raw_result_rows":len(rows),"audited_metrics":s,"changed_decodable_replacements_verified":rewrites,"allow_passthrough_verified":unchanged,"result_sha256":digest(p/"results.jsonl"),"receipt_sha256":digest(p/"receipt.json"),"detector_sources":dict(Counter(x["detection"]["source"]for r in rows for x in r["people"])),"mismatches":[{"id":r["id"],"expected":r["expected"],"action":r["action"],"reasons":r["reasons"]}for r in counted if (r["action"]=="allow")!=(r["expected"]=="allow")]}
target=HERE/"verification-report.json";target.write_text(json.dumps(report,indent=2)+"\n")
print(json.dumps(report,indent=2))
