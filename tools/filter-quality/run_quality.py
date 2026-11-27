#!/usr/bin/env python3
"""Evaluate frozen public fixtures with real CPU model inference, never mock labels."""
from __future__ import annotations
import argparse, copy, hashlib, json, math, statistics, sys, time
from collections import Counter
from pathlib import Path

HERE=Path(__file__).resolve().parent
from runtime_contract import prepare_runtime
prepare_runtime()
from local_image_filter.config import load_settings
from local_image_filter.runtime.container import build_runtime
from downstream.face_fallback import FaceFallbackPersonDetector

def summary(rows):
    counts=Counter()
    for row in rows:
        expected=row["expected"]
        if row.get("error") or not row.get("model_evidence_complete",False):
            counts["errors"]+=1
            counts["FN" if expected=="block" else "FP"]+=1
        else:
            predicted=row["action"] in {"blur","replace"}
            counts[("TP" if predicted else "FN") if expected=="block" else ("FP" if predicted else "TN")]+=1
    tp,tn,fp,fn=(counts[k] for k in ["TP","TN","FP","FN"])
    pct=lambda a,b:round(100*a/b,3) if b else None
    durations=sorted(r["ms"] for r in rows if "ms"in r)
    q=lambda v:round(durations[min(len(durations)-1,math.ceil(len(durations)*v)-1)],2) if durations else None
    return dict(n=len(rows),TP=tp,TN=tn,FP=fp,FN=fn,errors=counts["errors"],
      block_recall_pct=pct(tp,tp+fn),allow_specificity_pct=pct(tn,tn+fp),
      block_precision_pct=pct(tp,tp+fp),accuracy_pct=pct(tp+tn,len(rows)),
      p50_ms=q(.5),p95_ms=q(.95),p99_ms=q(.99),
      people_detected=sum(bool(r.get("people")) for r in rows),
      no_person_detection=sum(not r.get("people") for r in rows))

def main():
    p=argparse.ArgumentParser()
    p.add_argument("--manifest",type=Path,default=HERE/".data/manifest.json")
    p.add_argument("--split",choices=["calibration","holdout","all"],required=True)
    p.add_argument("--variant",choices=["v2","official"],required=True)
    p.add_argument("--name",required=True)
    p.add_argument("--policy",type=Path)
    p.add_argument("--limit",type=int)
    p.add_argument("--audit",type=Path,default=HERE/"composition-audit.json")
    args=p.parse_args()
    result_dir=HERE/"results"/args.name
    result_dir.mkdir(parents=True,exist_ok=False)
    manifest_bytes=args.manifest.read_bytes();manifest=json.loads(manifest_bytes)
    audit_bytes=args.audit.read_bytes()
    excluded={r["id"] for r in json.loads(audit_bytes)["excluded"]}
    records=[r for r in manifest["rows"] if r["id"] not in excluded and (args.split=="all" or r["split"]==args.split)]
    if args.limit:records=records[:args.limit]
    overlay=result_dir/"isolated.toml"
    overlay.write_text('[cache]\nenabled=false\nsqlite_path="'+str(result_dir/"unused.sqlite3")+'"\n[diagnostics]\nenabled=false\ndirectory="'+str(result_dir/"diagnostics")+'"\n[runtime]\nintra_op_threads=1\ninter_op_threads=1\nmax_concurrent_inference=1\nprovider_priority=["CPUExecutionProvider"]\n')
    config=Path("/srv/pureline-poc/config/pureline-v2.toml") if args.variant=="v2" else HERE/"candidate.toml"
    overlays=[overlay]
    if args.policy:overlays.append(args.policy)
    t=time.perf_counter(); runtime=build_runtime(load_settings(config,overlays=overlays));load_ms=(time.perf_counter()-t)*1000
    if args.variant!="v2":
        runtime.pipeline.person_detector=FaceFallbackPersonDetector(runtime.pipeline.person_detector,
           "/srv/pureline-poc/official-candidate/face_yunet_2026may.onnx")
    receipt=dict(variant=args.variant,split=args.split,manifest_sha256=hashlib.sha256(manifest_bytes).hexdigest(),audit_sha256=hashlib.sha256(audit_bytes).hexdigest(),
                 config=str(config),config_sha256=hashlib.sha256(config.read_bytes()).hexdigest(),policy=str(args.policy) if args.policy else None,
                 effective_policy=runtime.settings.section("policy"),effective_processing=runtime.settings.section("processing"),
                 providers=runtime.selected_providers,model_descriptions=runtime.model_descriptions,load_ms=round(load_ms,2),
                 manifest_count=len(records),mock_models=False,created_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime()))
    (result_dir/"receipt.json").write_text(json.dumps(receipt,indent=2)+"\n")
    rows=[]
    with (result_dir/"results.jsonl").open("w") as output:
        for i,record in enumerate(records):
            row={k:record[k] for k in ["id","expected","source","split","sha256","width","height"]}
            start=time.perf_counter()
            try:
                content=(args.manifest.parent/record["path"]).read_bytes()
                if hashlib.sha256(content).hexdigest()!=record["sha256"]:raise ValueError("fixture hash changed")
                out=runtime.pipeline.filter_bytes(content,record["mime"])
                replacement=out.replacement_bytes
                row.update(action=out.decision.action.value,reasons=out.decision.reasons,
                           model_evidence_complete=out.decision.model_evidence_complete,
                           people=out.response.get("people",[]),summary=out.response.get("summary",{}),
                           nudity=out.response.get("nudity",{}),
                           replacement_exists=replacement is not None,
                           replacement_differs=replacement!=content if replacement else None,
                           replacement_sha256=hashlib.sha256(replacement).hexdigest() if replacement else None)
                # Public benchmark outputs support browser/render checking.
                if replacement is not None:
                    d=result_dir/"processed";d.mkdir(exist_ok=True)
                    (d/(record["id"]+".jpg")).write_bytes(replacement)
            except Exception as exc:row["error"]=type(exc).__name__+": "+str(exc)
            row["ms"]=round((time.perf_counter()-start)*1000,2)
            rows.append(row);output.write(json.dumps(row,ensure_ascii=False)+"\n");output.flush()
            if (i+1)%20==0:print(json.dumps({"name":args.name,"progress":i+1,"total":len(records)}),flush=True)
    report=dict(overall=summary(rows),by_source={src:summary([r for r in rows if r["source"]==src]) for src in sorted({r["source"]for r in rows})})
    (result_dir/"summary.json").write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps({"name":args.name,"result_dir":str(result_dir),"report":report}),flush=True)
if __name__=="__main__":main()
