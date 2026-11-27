#!/usr/bin/env python3
"""Actual mitmproxy response objects plus real process/timeout boundaries."""
import asyncio
import hashlib
import io
import json
from pathlib import Path
import sys
import time
from types import SimpleNamespace
from datetime import datetime, timezone
from PIL import Image

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from runtime_contract import prepare_runtime
prepare_runtime()
from mitmproxy import http, ctx
from local_image_filter.config import load_settings
from local_image_filter.proxy.filters import ResponseEligibility
from downstream.pureline_addon_candidate import PurelineVerifiedFilter
from downstream.process_pool import BoundedProcessPool

ctx.log = SimpleNamespace(error=lambda message: None)
rows = []


def flow(body, mime="image/png", encoding="gzip", connection="client-a"):
    headers = {"content-type": mime, "etag": '"origin"'}
    if encoding:
        headers["content-encoding"] = encoding
    return SimpleNamespace(
        id=str(time.monotonic_ns()), client_conn=SimpleNamespace(id=connection),
        request=http.Request.make("GET", "https://fixture.example/image"),
        response=http.Response.make(200, body, headers),
    )


def assert_placeholder(item, reason):
    response = item.response
    assert response.headers["x-local-image-filter"] == "replace"
    assert response.headers["x-local-image-filter-reason"] == reason
    assert "content-encoding" not in response.headers and "etag" not in response.headers
    assert response.headers["cache-control"] == "no-store"
    assert int(response.headers["content-length"]) == len(response.raw_content)
    with Image.open(io.BytesIO(response.raw_content)) as image:
        image.verify()


async def ready(timeout=0.2, queued=0):
    addon = PurelineVerifiedFilter()
    settings = load_settings(HERE/"candidate.toml")
    addon.runtime = addon.create_runtime(settings)
    addon.eligibility = ResponseEligibility(settings.section("proxy"))
    addon.semaphore = asyncio.Semaphore(1)
    addon.pool = BoundedProcessPool(
        [sys.executable, str(HERE/"tests/fake_pipeline_worker.py")],
        workers=1, queued=queued, timeout=timeout,
    )
    await addon.pool.warm_up(timeout=5)
    return addon


async def wait_active(addon):
    for _ in range(100):
        if addon.pool.metrics["active"]:
            return
        await asyncio.sleep(0.005)
    raise AssertionError("inspection did not start")


async def main():
    addon = await ready()
    output = io.BytesIO()
    Image.new("RGB", (32,32), "navy").save(output, format="PNG")
    image_bytes = output.getvalue()
    unready = PurelineVerifiedFilter()
    item = flow(image_bytes)
    item.response.stream = True
    unready.responseheaders(item)
    assert item.response.stream is False
    await unready.response(item)
    assert_placeholder(item, "runtime-not-ready")
    rows.append({"id":"startup-unready-fails-closed","passed":True})
    item = flow(image_bytes, "application/octet-stream")
    await unready.response(item)
    assert_placeholder(item, "runtime-not-ready")
    rows.append({"id":"unready-ambiguous-image-fails-closed","passed":True})
    item = flow(image_bytes)
    original_raw = item.response.raw_content
    addon.responseheaders(item)
    assert not item.response.stream
    await addon.response(item)
    assert item.response.raw_content == original_raw and item.response.content == image_bytes
    assert item.response.headers["x-local-image-filter"] == "allow"
    rows.append({"id":"allow-preserves-compressed-representation","passed":True})

    for mime in ["text/html", "text/css", "application/javascript", "text/event-stream"]:
        item = flow(b"non-image-stream", mime)
        raw = item.response.raw_content
        addon.responseheaders(item)
        assert item.response.stream is True
        await addon.response(item)
        assert item.response.raw_content == raw
        assert "x-local-image-filter" not in item.response.headers
        rows.append({"id":"stream-"+mime,"passed":True})

    item = flow(b"sleep:30")
    started = time.monotonic()
    await addon.response(item)
    elapsed = time.monotonic()-started
    assert_placeholder(item, "inspection-timeout")
    assert elapsed < 1.5
    rows.append({"id":"timeout-serves-valid-placeholder","elapsed_ms":round(elapsed*1000),"passed":True})
    await addon.pool.close()

    addon = await ready(timeout=2)
    first = flow(b"sleep:0.15")
    task = asyncio.create_task(addon.response(first))
    await wait_active(addon)
    second = flow(image_bytes, connection="client-b")
    await addon.response(second)
    assert_placeholder(second, "inspection-queue-full")
    await task
    rows.append({"id":"capacity-serves-valid-placeholder","passed":True})
    await addon.pool.close()

    for event in ["disconnect", "flow-error"]:
        addon = await ready(timeout=2)
        item = flow(b"sleep:30")
        task = asyncio.create_task(addon.response(item))
        await wait_active(addon)
        if event == "disconnect":
            addon.client_disconnected(item.client_conn)
        else:
            addon.error(item)
        result = await asyncio.gather(task, return_exceptions=True)
        assert isinstance(result[0], asyncio.CancelledError)
        assert addon.pool.admitted == 0 and not addon.active_inspections
        assert addon.pool.workers[0].process is None
        rows.append({"id":event+"-cancels-and-reaps","passed":True})
        await addon.pool.close()

    report = {"schema":1,"created_utc":datetime.now(timezone.utc).isoformat(),
              "passed":True,"cases":len(rows),"actual_mitmproxy_serialization":True,
              "actual_models":False,"accuracy_samples_added":0,"rows":rows,
              "sources":{name:hashlib.sha256((HERE/"downstream"/name).read_bytes()).hexdigest()
                         for name in ["pureline_http_addon.py","pureline_addon_v2.py","pureline_addon_candidate.py","process_pool.py"]}}
    (HERE/"evidence/runtime-http-bounds-regression.json").write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps(report))


if __name__ == "__main__":
    asyncio.run(main())
