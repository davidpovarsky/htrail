#!/usr/bin/env python3
"""Real-model animation and optional distinct-image HTTP-handler load receipt.

The existing labelled corpus is reused for regression and load only; its images
are not counted again as new independent classifier-accuracy samples.
"""
from __future__ import annotations
import argparse
import asyncio
import hashlib
import io
import json
import math
import os
from pathlib import Path
import sys
import time
from types import SimpleNamespace
from datetime import datetime, timezone
from PIL import Image

HERE = Path(__file__).resolve().parent
sys.path.insert(0,str(HERE))
from runtime_contract import prepare_runtime
prepare_runtime()
from mitmproxy import http, ctx
from local_image_filter.config import load_settings
from local_image_filter.proxy.filters import ResponseEligibility
from local_image_filter.image.decode import decode_image, ImageDecodeError
from downstream.process_pool import BoundedProcessPool, InspectionFailure
from downstream.worker_protocol import decode_outcome
from downstream.pureline_addon_candidate import PurelineVerifiedFilter

DATA = Path("/mnt/development/projects/pureline-quality-20261127/experiments/pureline-quality-20261127/.data")
PANGEA_SHA = "21de2a3e19a60fd4d933919f6aa491a775fa1a42d0709aa3e677fac51d712bdd"
ctx.log = SimpleNamespace(error=lambda message: None)


def rss(pid):
    try:
        values = {}
        for line in Path(f"/proc/{pid}/status").read_text().splitlines():
            if line.startswith(("VmRSS:", "VmHWM:")):
                values[line.split(":")[0]] = int(line.split()[1])*1024
        return values
    except FileNotFoundError:
        return {}


def percentile(values, percentile):
    return round(sorted(values)[max(0,math.ceil(len(values)*percentile)-1)],2) if values else None


async def main(args):
    settings=load_settings(HERE/"candidate.toml")
    addon=PurelineVerifiedFilter()
    addon.runtime=addon.create_runtime(settings)
    addon.eligibility=ResponseEligibility(settings.section("proxy"))
    addon.eligibility.allowed_content_types.add("image/svg+xml")
    addon.semaphore=asyncio.Semaphore(args.workers)
    pool=BoundedProcessPool([sys.executable,str(HERE/"downstream/pipeline_worker.py"),str(HERE/"candidate.toml")],
                            workers=args.workers,queued=8,timeout=18)
    addon.pool=pool
    memory={"peak_combined_rss_bytes":0,"peak_worker_rss_bytes":{},"parent_pid":os.getpid()}
    stop_sampling=asyncio.Event()
    async def sample():
        while not stop_sampling.is_set():
            total=rss(os.getpid()).get("VmRSS",0)
            for worker in pool.workers:
                if worker.process is not None:
                    pid=worker.process.pid
                    current=rss(pid).get("VmRSS",0)
                    memory["peak_worker_rss_bytes"][str(pid)]=max(memory["peak_worker_rss_bytes"].get(str(pid),0),current)
                    total+=current
            memory["peak_combined_rss_bytes"]=max(memory["peak_combined_rss_bytes"],total)
            await asyncio.sleep(0.05)
    sampler=asyncio.create_task(sample())
    rows=[]
    load_rows=[]
    started=time.monotonic()
    try:
        await pool.warm_up(timeout=90)
        startup_ms=round((time.monotonic()-started)*1000)
        ready=[worker.ready_info for worker in pool.workers]
        print(json.dumps({"stage":"ready","workers":args.workers,"startup_ms":startup_ms,"memory":memory}),flush=True)
        if not args.skip_animation:
            pangea=(HERE/"results/animation/pangea.gif").read_bytes()
            assert hashlib.sha256(pangea).hexdigest()==PANGEA_SHA
            try:
                decode_image(pangea,1536,4_194_304,"replace")
                raise AssertionError("original animation rejection not reproduced")
            except ImageDecodeError as error:
                assert error.reason=="animatedImageNotInspected"
            async def inspect(name,body,mime,expected):
                began=time.monotonic()
                try:
                    outcome=decode_outcome(await pool.inspect(body,mime))
                    action=outcome.decision.action.value
                    row={"id":name,"source_sha256":hashlib.sha256(body).hexdigest(),
                         "action":action,"expected":expected,"elapsed_ms":round((time.monotonic()-began)*1000),
                         "animation":outcome.response.get("pipeline",{}).get("animationInspection"),
                         "model_evidence_complete":outcome.decision.model_evidence_complete,
                         "original_passthrough":outcome.replacement_bytes is None,
                         "replacement_mime":outcome.replacement_mime_type,
                         "passed":action==expected}
                    if outcome.replacement_bytes:
                        with Image.open(io.BytesIO(outcome.replacement_bytes)) as image:image.verify()
                        row["replacement_decodes"]=True
                except InspectionFailure as error:
                    row={"id":name,"action":"replace","reason":error.reason,"expected":expected,
                         "elapsed_ms":round((time.monotonic()-began)*1000),"passed":False}
                rows.append(row)
                print(json.dumps(row),flush=True)
            await inspect("pangea-38-frames",pangea,"image/gif","allow")
            # Distinct original labelled images retained from earlier acceptance.
            blocked=(DATA/"images/randomuser-women-77.jpg").read_bytes()
            allowed=(DATA/"images/randomuser-men-54.jpg").read_bytes()
            await inspect("static-allow-regression",allowed,"image/jpeg","allow")
            await inspect("static-block-regression",blocked,"image/jpeg","blur")
            with Image.open(io.BytesIO(blocked)) as image:woman=image.convert("RGB")
            first=Image.new("RGB",woman.size,"navy")
            gif=io.BytesIO()
            first.save(gif,format="GIF",save_all=True,append_images=[woman],duration=[100,100],loop=0,disposal=2)
            await inspect("late-blocked-animation-frame",gif.getvalue(),"image/gif","blur")

        if args.samples:
            corpus={r["id"]:r for r in json.loads((HERE/"corpus/main.json").read_text())["rows"]}
            prior=[json.loads(line) for line in (HERE/"evidence/official-holdout-frozen-v1/results.jsonl").read_text().splitlines()]
            selected=sorted(prior,key=lambda row:row["sha256"])[:args.samples]
            if args.only_mime:
                selected=[row for row in selected if corpus[row["id"]]["mime"]==args.only_mime]
            gate=asyncio.Semaphore(args.clients)
            async def inspect_row(previous):
                async with gate:
                    metadata=corpus[previous["id"]]
                    content=(DATA/metadata["path"]).read_bytes()
                    assert hashlib.sha256(content).hexdigest()==previous["sha256"]
                    response=http.Response.make(200,content,{"content-type":metadata["mime"],"content-encoding":"gzip"})
                    item=SimpleNamespace(id=previous["id"],client_conn=SimpleNamespace(id=previous["id"]),
                                         request=http.Request.make("GET","https://fixture.example/"+previous["id"]),response=response)
                    began=time.monotonic()
                    await addon.response(item)
                    elapsed=(time.monotonic()-began)*1000
                    with Image.open(io.BytesIO(response.content)) as decoded:decoded.verify()
                    action=response.headers.get("x-local-image-filter")
                    reason=response.headers.get("x-local-image-filter-reason")
                    row={"id":previous["id"],"sha256":previous["sha256"],"expected_label":previous["expected"],
                         "previous_action":previous["action"],"action":action,"reason":reason,
                         "elapsed_ms":round(elapsed,2),"decoded":True,
                         "unchanged_allowed_bytes":response.content==content if action=="allow" else None,
                         "overload_or_timeout":reason in {"inspection-queue-full","inspection-timeout"},
                         "passed":action==previous["action"] and reason=="policy"}
                    load_rows.append(row)
                    if len(load_rows)%10==0:print(json.dumps({"stage":"load","completed":len(load_rows),"failures":sum(not r["passed"] for r in load_rows)}),flush=True)
            await asyncio.gather(*(inspect_row(row) for row in selected))
    finally:
        stop_sampling.set()
        await sampler
        await pool.close()
    latency=[row["elapsed_ms"] for row in load_rows]
    report={"schema":1,"created_utc":datetime.now(timezone.utc).isoformat(),"passed":all(row["passed"] for row in rows+load_rows),
            "workers":args.workers,"client_concurrency":args.clients,"request_deadline_seconds":18,
            "actual_models":True,"new_independent_accuracy_samples":0,"browser_navigation":False,
            "scope":"real-model pipeline and actual mitmproxy response-object load; not physical VPN or browser navigation",
            "startup_ms":startup_ms,"providers":ready,"animation_rows":rows,"load_images":len(load_rows),
            "load_successes":sum(row["passed"] for row in load_rows),
            "overload_or_timeout":sum(row["overload_or_timeout"] for row in load_rows),
            "p50_ms":percentile(latency,.5),"p95_ms":percentile(latency,.95),"p99_ms":percentile(latency,.99),
            "memory":memory,"within_2gib_rss":memory["peak_combined_rss_bytes"]<2*1024**3,
            "metrics":dict(pool.metrics),"load_rows":sorted(load_rows,key=lambda row:row["id"]),
            "source_sha256":{str(path.relative_to(HERE)):hashlib.sha256(path.read_bytes()).hexdigest()
                             for path in sorted((HERE/"downstream").glob("*.py"))}}
    target=HERE/"evidence"/args.report
    target.write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps({key:value for key,value in report.items() if key not in {"load_rows","source_sha256"}}),flush=True)
    return 0 if report["passed"] and report["within_2gib_rss"] else 1


if __name__=="__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("--workers",type=int,choices=[1,2],default=1)
    parser.add_argument("--samples",type=int,default=0)
    parser.add_argument("--clients",type=int,default=6)
    parser.add_argument("--skip-animation",action="store_true")
    parser.add_argument("--only-mime",help="Focused replay within the deterministically selected sample")
    parser.add_argument("--report",default="real-animation-workers1.json")
    raise SystemExit(asyncio.run(main(parser.parse_args())))
