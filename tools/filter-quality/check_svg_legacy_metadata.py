#!/usr/bin/env python3
"""Targeted real-model regression for legacy Creative Commons SVG metadata."""
from __future__ import annotations
import asyncio, hashlib, io, json, sys, time, urllib.request
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace
from PIL import Image

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from runtime_contract import prepare_runtime
prepare_runtime()
from mitmproxy import http, ctx
from local_image_filter.config import load_settings
from local_image_filter.runtime.container import build_runtime
from local_image_filter.proxy.filters import ResponseEligibility
from downstream.face_fallback import FaceFallbackPersonDetector
from downstream.strong_blur import StrongBlurPipeline
from downstream.svg_pipeline import SVGInspectingPipeline
from downstream.pureline_http_addon import LocalImageFilterAddon

ctx.log = SimpleNamespace(error=lambda message: None)
runtime = build_runtime(load_settings(HERE / "candidate.toml"))
runtime.pipeline.person_detector = FaceFallbackPersonDetector(
    runtime.pipeline.person_detector,
    "/srv/pureline-poc/official-candidate/face_yunet_2026may.onnx",
)

class Capture:
    def __init__(self, inner):
        self.inner = inner
        self.calls = 0
        self.last_outcome = None

    def filter_bytes(self, *args):
        self.calls += 1
        self.last_outcome = self.inner.filter_bytes(*args)
        return self.last_outcome

capture = Capture(runtime.pipeline)
runtime.pipeline = SVGInspectingPipeline(StrongBlurPipeline(capture, 32.0))
addon = LocalImageFilterAddon()
addon.runtime = runtime
addon.eligibility = ResponseEligibility(runtime.settings.section("proxy"))
addon.eligibility.allowed_content_types.add("image/svg+xml")
addon.semaphore = asyncio.Semaphore(1)

async def check(identifier, body, expected):
    response = http.Response.make(
        200, body,
        {"content-type": "image/svg+xml", "content-encoding": "gzip", "etag": '"original"'},
    )
    original_raw = response.raw_content
    flow = SimpleNamespace(
        request=http.Request.make("GET", "https://fixture.example/" + identifier),
        response=response,
    )
    previous_calls = capture.calls
    started = time.perf_counter()
    await addon.response(flow)
    action = response.headers.get("x-local-image-filter")
    invoked = capture.calls != previous_calls
    result = {
        "id": identifier,
        "expected": expected,
        "action": action,
        "reason": response.headers.get("x-local-image-filter-reason"),
        "source_sha256": hashlib.sha256(body).hexdigest(),
        "source_bytes": len(body),
        "mime": response.headers.get("content-type"),
        "classifier_invoked": invoked,
        "policy_exception": response.headers.get("x-local-image-filter-policy-exception"),
        "elapsed_ms": round((time.perf_counter() - started) * 1000, 2),
    }
    if expected == "allow":
        result["original_representation_unchanged"] = (
            response.raw_content == original_raw
            and response.headers.get("content-encoding") == "gzip"
            and response.content == body
        )
        result["model_evidence_complete"] = bool(
            invoked and capture.last_outcome.decision.model_evidence_complete
        )
        result["pass"] = (
            action == "allow"
            and result["original_representation_unchanged"]
            and result["model_evidence_complete"]
            and result["policy_exception"] is None
        )
    else:
        try:
            with Image.open(io.BytesIO(response.content)) as image:
                image.verify()
            result["decoded_replacement"] = True
        except Exception:
            result["decoded_replacement"] = False
        result["content_length_correct"] = (
            int(response.headers.get("content-length", "0")) == len(response.raw_content)
        )
        result["pass"] = (
            action == "replace"
            and not invoked
            and result["decoded_replacement"]
            and result["content_length_correct"]
            and result["policy_exception"] is None
        )
    return result

async def main():
    fixture = json.loads((HERE / "corpus/svg-legacy-metadata.json").read_text())["rows"][0]
    cache = HERE / "results/svg" / fixture["cache_filename"]
    cache.parent.mkdir(parents=True, exist_ok=True)
    if not cache.exists():
        request = urllib.request.Request(
            fixture["url"], headers={"User-Agent": "PurelineValidation/2026-11-27"}
        )
        with urllib.request.urlopen(request, timeout=15) as response:
            source = response.read(1048577)
        assert len(source) <= 1048576
        assert hashlib.sha256(source).hexdigest() == fixture["source_sha256"]
        cache.write_bytes(source)
    source = cache.read_bytes()
    assert len(source) == fixture["source_bytes"]
    assert hashlib.sha256(source).hexdigest() == fixture["source_sha256"]
    rows = [await check(fixture["id"], source, fixture["expected"])]
    prefix = (
        '<svg xmlns="http://www.w3.org/2000/svg" '
        'xmlns:cc="http://web.resource.org/cc/" width="128" height="128">'
        '<metadata><cc:Work>'
    )
    suffix = "</cc:Work></metadata></svg>"
    controls = {
        "legacy-cc-external-resource": '<cc:image href="https://example.invalid/denied.png"/>',
        "legacy-cc-script": "<cc:script>alert(1)</cc:script>",
        "legacy-cc-foreign-object": (
            '<cc:foreignObject><body xmlns="http://www.w3.org/1999/xhtml">'
            '<img src="data:image/png;base64,AA==" onerror="alert(1)"/>'
            "</body></cc:foreignObject>"
        ),
    }
    for identifier, content in controls.items():
        rows.append(await check(identifier, (prefix + content + suffix).encode(), "reject"))
    worker = HERE / "downstream/svg_worker.py"
    before = json.loads((HERE / "evidence/wikisource-svg-compatibility-boundary.json").read_text())
    report = {
        "schema": 1,
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "passed": all(row["pass"] for row in rows),
        "cases": len(rows),
        "actual_models": True,
        "mock_classification": False,
        "raster_holdout_reclassified": False,
        "new_curated_exception": False,
        "public_source_url": fixture["url"],
        "worker_sha256_before": before["worker_sha256"],
        "worker_sha256_after": hashlib.sha256(worker.read_bytes()).hexdigest(),
        "before": {
            "worker_exit": before["worker_exit"],
            "reason": "unsupported-svg-tag",
            "namespace": "http://web.resource.org/cc/",
            "source_sha256": before["source_sha256"],
            "classifier_run": before["classifier_run"],
        },
        "rows": rows,
    }
    destination = HERE / "evidence/svg-legacy-metadata-validation.json"
    destination.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
    raise SystemExit(not report["passed"])

if __name__ == "__main__":
    asyncio.run(main())
