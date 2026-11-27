#!/usr/bin/env python3
"""Actual model + HTTP validation for static SVG and stronger presentation."""
import argparse,asyncio,hashlib,io,json,sys,time
from pathlib import Path
from types import SimpleNamespace
from PIL import Image
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE))
from runtime_contract import prepare_runtime
prepare_runtime()
from mitmproxy import http,ctx
ctx.log=SimpleNamespace(error=lambda message:None)
from local_image_filter.config import load_settings
from local_image_filter.runtime.container import build_runtime
from local_image_filter.proxy.filters import ResponseEligibility
from downstream.face_fallback import FaceFallbackPersonDetector
from downstream.svg_pipeline import SVGInspectingPipeline
from downstream.strong_blur import StrongBlurPipeline
from downstream.pureline_http_addon import LocalImageFilterAddon
runtime=build_runtime(load_settings(HERE/"candidate.toml"))
runtime.pipeline.person_detector=FaceFallbackPersonDetector(runtime.pipeline.person_detector,"/srv/pureline-poc/official-candidate/face_yunet_2026may.onnx")
class Capture:
    def __init__(self,inner):self.inner=inner;self.last_sha=None
    def filter_bytes(self,content,*args):
        self.last_sha=hashlib.sha256(content).hexdigest()
        self.last_outcome=self.inner.filter_bytes(content,*args)
        return self.last_outcome
capture=Capture(runtime.pipeline)
runtime.pipeline=SVGInspectingPipeline(StrongBlurPipeline(capture,32.0))
parser=argparse.ArgumentParser();parser.add_argument("--only");args=parser.parse_args();selected=set(args.only.split(","))if args.only else None
addon=LocalImageFilterAddon();addon.runtime=runtime
addon.eligibility=ResponseEligibility(runtime.settings.section("proxy"));addon.eligibility.allowed_content_types.add("image/svg+xml")
addon.semaphore=asyncio.Semaphore(1)
async def check(identifier,body,mime,expected,source):
 response=http.Response.make(200,body,{"content-type":mime,"content-encoding":"gzip","etag":'"original"'})
 before=response.raw_content;flow=SimpleNamespace(request=http.Request.make("GET","https://fixture.example/"+identifier),response=response)
 start=time.perf_counter();await addon.response(flow)
 action=response.headers.get("x-local-image-filter")
 result=dict(id=identifier,expected=expected,source=source,action=action,policy_exception=response.headers.get("x-local-image-filter-policy-exception"),reason=response.headers.get("x-local-image-filter-reason"),mime=response.headers.get("content-type"),ms=round((time.perf_counter()-start)*1000,2))
 if action=="allow":
  result["original_representation_unchanged"]=response.raw_content==before and response.headers.get("content-encoding")=="gzip"
  result["rasterized_allow"]=response.headers.get("x-local-image-filter-presentation")=="rasterized_allow"
  if result["rasterized_allow"]:
   result["exact_inspected_raster_returned"]=hashlib.sha256(response.content).hexdigest()==capture.last_sha
   with Image.open(io.BytesIO(response.content))as im:im.verify()
  result["pass"]=expected=="allow"and(result["original_representation_unchanged"]or result.get("exact_inspected_raster_returned",False))
 else:
  try:
   with Image.open(io.BytesIO(response.content))as im:result["dimensions"]=list(im.size);im.verify()
   result["decoded"]=True
  except Exception:result["decoded"]=False
  result["content_length_correct"]=int(response.headers.get("content-length","0"))==len(response.raw_content)
  result["pass"]=(expected=="reject"and action=="replace"or expected=="block"and action=="blur")and result["decoded"]and result["content_length_correct"]
  result["replacement_sha256"]=hashlib.sha256(response.content).hexdigest()
  folder=HERE/"results"/("presentation"if source=="high-resolution"else"svg")/"processed";folder.mkdir(exist_ok=True)
  (folder/(identifier+".png")).write_bytes(response.content)
 if result.get("policy_exception"):
  policy=capture.last_outcome.response["pipeline"]["modules"]["policy"]["details"]
  result["reported_policy_action"]=policy["decision"]["action"]
  result["outcome_action"]=capture.last_outcome.decision.action.value
  result["modelActionBeforeOverride"]=policy.get("modelActionBeforeOverride")
  result["reporting_consistent"]=result["reported_policy_action"]==result["outcome_action"]==action=="allow" and result["modelActionBeforeOverride"]=="blur"
  result["pass"]=result["pass"] and result["reporting_consistent"]
 if expected=="no_exception":
  result["pass"]=not result["policy_exception"]and capture.last_sha!="bb0e4b77e584215801290c003052a2aa2b0a760adcba1894a2fcddcbad9a8153"
  result["changed_raster_sha256"]=capture.last_sha
 with (HERE/"results/svg/validation-progress.jsonl").open("a")as log:log.write(json.dumps(result)+"\n")
 return result
async def main():
 rows=[]
 for group in ["svg-validation","presentation-validation"]:
  for r in json.loads((HERE/"corpus"/(group+".json")).read_text())["rows"]:
   if selected and r["id"]not in selected:continue
   result=await check(r["id"],Path(r["path"]).read_bytes(),"image/svg+xml"if group=="svg-validation"else"image/jpeg",r["expected"],r.get("source","high-resolution"))
   rows.append(result)
 if selected and "changed-pixel-globe"in selected:
  original=(HERE/"results/svg/fixtures/wiki-svg-00.svg").read_bytes()
  changed=original.replace(b"</svg>",b'<rect x="0" y="0" width="3" height="3" fill="red"/></svg>')
  rows.append(await check("changed-pixel-globe",changed,"image/svg+xml","no_exception","policy-boundary"))
 base='<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128">'
 bad={
 "external-http":base+'<image href="https://example.invalid/private.png"/></svg>',
 "external-file":base+'<image href="file:///pureline-denied-probe"/></svg>',
 "entity":'<!DOCTYPE svg [<!ENTITY x SYSTEM "file:///pureline-denied-probe">]>'+base+'<text>&x;</text></svg>',
 "foreign-object":base+'<foreignObject><body xmlns="http://www.w3.org/1999/xhtml"><img src="data:image/png;base64,AA==" onerror="alert(1)"/></body></foreignObject></svg>',
 "filter-image":base+'<filter id="f"><feImage href="data:image/png;base64,AA=="/></filter><rect width="50" height="50" filter="url(#f)"/></svg>',
 "script":base+'<script>alert(1)</script></svg>',
 "animation":base+'<rect width="50" height="50"><animate attributeName="fill" values="red;blue" dur="1s"/></rect></svg>',
 "malformed":base+'<path>',
 "huge-dimensions":'<svg xmlns="http://www.w3.org/2000/svg" width="1e9" height="1e9"/>',
 "deep-tree":base+'<g>'*65+'</g>'*65+'</svg>',
 "node-count":base+'<path d="M0 0"/>'*4097+'</svg>',
 "css-external":base+'<style>@import url("https://example.invalid/a.css");</style></svg>',
 "css-escaped-url":base+'<rect style="fill:u\\72l(https://example.invalid/a.svg)"/></svg>',
 "recursive-use":base+'<g id="loop"><use href="#loop"/></g></svg>',
 "input-byte-limit":base+' '*1048576+'</svg>'
 }
 for identifier,value in bad.items():
  if selected and "security-"+identifier not in selected:continue
  rows.append(await check("security-"+identifier,value.encode(),"image/svg+xml","reject","security-boundary"))
 report={"passed":all(r["pass"]for r in rows),"cases":len(rows),"actual_models":True,"mock_classification":False,"raster_holdout_reclassified":False,"rows":rows}
 (HERE/"evidence"/("svg-normalization-validation.json"if selected else"svg-presentation-validation.json")).write_text(json.dumps(report,indent=2)+"\n")
 print(json.dumps({"passed":report["passed"],"cases":len(rows),"failures":[r for r in rows if not r["pass"]],"by_source":{s:{"n":sum(r["source"]==s for r in rows),"pass":sum(r["pass"]and r["source"]==s for r in rows)}for s in {r["source"]for r in rows}}}))
 raise SystemExit(not report["passed"])
asyncio.run(main())
