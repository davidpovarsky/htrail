#!/usr/bin/env python3
"""Check public committed receipts without models, network, or image access."""
import hashlib,json
from pathlib import Path
H=Path(__file__).resolve().parent
v=json.loads((H/"evidence/verification-report.json").read_text())
digest=lambda f:hashlib.sha256(f.read_bytes()).hexdigest()
assert digest(H/"corpus/main.json")==v["manifest_sha256"]
assert digest(H/"composition-audit.json")==v["audit_sha256"]
excluded={r["id"]for r in json.loads((H/"composition-audit.json").read_text())["excluded"]}
reports={}
for name,record in v["runs"].items():
 p=H/"evidence"/name
 assert digest(p/"results.jsonl")==record["result_sha256"]
 assert digest(p/"receipt.json")==record["receipt_sha256"]
 counts=dict(TP=0,TN=0,FP=0,FN=0,errors=0)
 for line in(p/"results.jsonl").read_text().splitlines():
  r=json.loads(line)
  if r["id"]in excluded:continue
  error=bool(r.get("error"))or not r.get("model_evidence_complete",False)
  if error:counts["errors"]+=1;key="FN"if r["expected"]=="block"else"FP"
  else:
   blocked=r["action"]in{"blur","replace"}
   key=("TP"if blocked else"FN")if r["expected"]=="block"else("FP"if blocked else"TN")
   if blocked:assert r["replacement_exists"]and r["replacement_differs"]
   else:assert not r["replacement_exists"]
  counts[key]+=1
 for k,value in counts.items():assert value==record["audited_metrics"][k],(name,k)
 reports[name]=counts
held=reports["official-holdout-frozen-v1"]
assert held["TP"]/(held["TP"]+held["FN"])>=.90
assert held["TN"]/(held["TN"]+held["FP"])>=.90
print(json.dumps({"passed":True,"scope":"committed receipt integrity and arithmetic; pixels verified separately on Oracle","runs":reports}))
