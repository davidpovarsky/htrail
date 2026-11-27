#!/usr/bin/env python3
"""Real mitmproxy serialization regression. Stub decisions, not classifier scores."""
import asyncio, io, json, sys
from pathlib import Path
from types import SimpleNamespace
from PIL import Image
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE))
from runtime_contract import prepare_runtime
prepare_runtime()
from mitmproxy import http
from local_image_filter.config import load_settings
from local_image_filter.domain.models import FilterAction
from local_image_filter.proxy.filters import ResponseEligibility
from local_image_filter.proxy.addon import LocalImageFilterAddon as Original, apply_replacement as original_replace
from downstream.pureline_http_addon import LocalImageFilterAddon as Fixed, apply_replacement as fixed_replace, INVALIDATED_HEADERS
def png(color):
 b=io.BytesIO();Image.new("RGB",(96,96),color).save(b,format="PNG");return b.getvalue()
original=png("navy");replacement=png("gray")
settings=load_settings(HERE/"candidate.toml")
def response(encoding):
 headers={"content-type":"image/png","etag":'"fixture"',"last-modified":"Fri, 27 Nov 2026 00:00:00 GMT","content-md5":"invalidated-on-rewrite","accept-ranges":"bytes"}
 if encoding!="identity":headers["content-encoding"]=encoding
 r=http.Response.make(200,original,headers)
 assert r.content==original
 return r
async def policy(cls,r,action):
 outcome=SimpleNamespace(decision=SimpleNamespace(action=action),cache_hit=False,replacement_bytes=replacement if action!=FilterAction.ALLOW else None,replacement_mime_type="image/png")
 addon=cls();addon.runtime=SimpleNamespace(settings=settings,pipeline=SimpleNamespace(filter_bytes=lambda *args:outcome))
 addon.eligibility=ResponseEligibility(settings.section("proxy"));addon.semaphore=asyncio.Semaphore(1)
 flow=SimpleNamespace(request=http.Request.make("GET","https://fixture.example/test.png"),response=r)
 await addon.response(flow)
def rewritten_correct(r):
 return r.raw_content==replacement and r.content==replacement and "content-encoding"not in r.headers and int(r.headers["content-length"])==len(r.raw_content)
rows=[]
for encoding in ("identity","gzip","br"):
 for branch in ("policy","failure-placeholder"):
  before=response(encoding)
  if branch=="policy":asyncio.run(policy(Original,before,FilterAction.BLUR))
  else:original_replace(before,replacement,"image/png",reason="regression")
  baseline_ok=rewritten_correct(before)
  after=response(encoding)
  if branch=="policy":asyncio.run(policy(Fixed,after,FilterAction.BLUR))
  else:fixed_replace(after,replacement,"image/png",reason="regression")
  assert rewritten_correct(after),(encoding,branch)
  assert all(h not in after.headers for h in INVALIDATED_HEADERS)
  assert after.headers["cache-control"]=="no-store"
  with Image.open(io.BytesIO(after.raw_content))as im:im.verify()
  if encoding!="identity":assert not baseline_ok,"Regression must detect original bug"
  rows.append(dict(encoding=encoding,branch=branch,original_serialization_valid=baseline_ok,fixed_serialization_valid=True))
 r=response(encoding);old_raw=r.raw_content;old_headers=dict(r.headers)
 asyncio.run(policy(Fixed,r,FilterAction.ALLOW))
 assert r.raw_content==old_raw and all(r.headers.get(k)==v for k,v in old_headers.items())
 rows.append(dict(encoding=encoding,branch="allow",representation_unchanged=True))
report={"passed":True,"count":len(rows),"uses_real_mitmproxy_response":True,"model_inference":False,"classification_acceptance_samples_added":0,"cases":rows}
(HERE/"evidence/http-serialization-regression.json").write_text(json.dumps(report,indent=2)+"\n")
print(json.dumps(report))
