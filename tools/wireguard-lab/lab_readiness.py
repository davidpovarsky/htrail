"""Fixed lab-only readiness endpoint; never changes classifier decisions."""
import hashlib
import json
import os
from pathlib import Path
from mitmproxy import ctx, http

class PurelineLabReadiness:
    def request(self, flow):
        req=flow.request
        if (req.scheme,req.host,req.port,req.path)!=("http","192.0.2.1",80,"/pureline-lab-20261127/ready"):
            return
        if req.method!="GET":
            flow.response=http.Response.make(405,b"",{"content-type":"application/json","cache-control":"no-store"})
            return
        candidate=ctx.master.addons.get("purelineverifiedfilter")
        pool=getattr(candidate,"pool",None)
        workers=getattr(pool,"workers",[])
        ready=pool is not None and not pool.closed and bool(workers) and all(
            worker.process is not None and worker.process.returncode is None and worker.ready_info
            for worker in workers)
        manifest=Path(os.environ["PURELINE_BROWSER_MANIFEST"])
        payload={"ready":bool(ready),"pid":os.getpid(),"worker_count":len(workers),
                 "header_capacity":getattr(candidate,"header_capacity",None),
                 "manifest_sha256":hashlib.sha256(manifest.read_bytes()).hexdigest()}
        flow.response=http.Response.make(200 if ready else 503,json.dumps(payload).encode(),
            {"content-type":"application/json","cache-control":"no-store"})

addons=[PurelineLabReadiness()]
