"""Inspect supported static SVG through the unchanged raster classifier."""
from __future__ import annotations
import hashlib,json,subprocess,sys
from dataclasses import replace
from local_image_filter.domain.models import FilterAction
from pathlib import Path
class SVGInspectionError(RuntimeError):pass
class SVGInspectingPipeline:
    def __init__(self,inner):
        self.inner=inner
        entries=json.loads((Path(__file__).resolve().parents[1]/"approved-ui-rasters.json").read_text())["entries"]
        self.approved={r["normalized_png_sha256"]:r for r in entries}
    def __getattr__(self,name):return getattr(self.inner,name)
    def filter_bytes(self,content,mime_type,source_url=None):
        if mime_type.split(";",1)[0].strip().lower()!="image/svg+xml":
            return self.inner.filter_bytes(content,mime_type,source_url)
        if len(content)>1048576:raise SVGInspectionError("SVG exceeds inspection bounds")
        try:
            result=subprocess.run([sys.executable,str(Path(__file__).with_name("svg_worker.py"))],
                input=content,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=5,check=False)
        except subprocess.TimeoutExpired as exc:
            raise SVGInspectionError("SVG inspection timed out")from exc
        if result.returncode or not result.stdout.startswith(b"\x89PNG\r\n\x1a\n"):
            raise SVGInspectionError("SVG rejected by bounded renderer")
        # Ordinary ALLOW preserves the original validated SVG bytes.
        # Normalized/curated ALLOW returns the exact inspected PNG instead.
        # BLUR/REPLACE returns a real raster image and its matching MIME.
        outcome=self.inner.filter_bytes(result.stdout,"image/png",source_url)
        approved=self.approved.get(hashlib.sha256(result.stdout).hexdigest())
        if approved:
            before=outcome.decision.action.value
            outcome.decision=replace(outcome.decision,action=FilterAction.ALLOW,reasons=("curated-public-ui-raster:"+approved["id"],))
            outcome.response.setdefault("pipeline",{})["curatedUIAsset"]={"id":approved["id"],"sha256":approved["normalized_png_sha256"],"modelActionBeforeOverride":before}
            details=outcome.response.setdefault("pipeline",{}).setdefault("modules",{}).setdefault("policy",{}).setdefault("details",{})
            details["modelActionBeforeOverride"]=before
            details["decision"]=outcome.decision.to_dict()
        if approved or (b"PURELINE_RASTERIZED_ALLOW"in result.stderr and outcome.decision.action.value=="allow"):
            outcome.replacement_bytes=result.stdout
            outcome.replacement_mime_type="image/png"
            outcome.response.setdefault("pipeline",{})["svgPresentation"]="rasterized_allow"
        return outcome
