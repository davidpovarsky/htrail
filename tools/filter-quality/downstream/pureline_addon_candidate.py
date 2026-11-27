"""Pinned downstream runtime with bounded and cancellable image inspection."""
from __future__ import annotations
import asyncio
import sys
import time
from pathlib import Path
from types import SimpleNamespace

PACKAGE = Path(__file__).resolve().parents[1]
if str(PACKAGE) not in sys.path:
    sys.path.insert(0, str(PACKAGE))
from runtime_contract import prepare_runtime
prepare_runtime()
from downstream.pureline_addon_v2 import PurelineRemoteFilter
from downstream.pureline_addon_v2 import AMBIGUOUS, sniff_image_mime
from downstream.pureline_http_addon import apply_replacement
from local_image_filter.image.rewrite import create_failure_placeholder
from downstream.process_pool import BoundedProcessPool
from downstream.worker_protocol import decode_outcome
from downstream.http_input import DEADLINE_KEY, MAXIMUM_IMAGE_BYTES, image_response
from downstream.http_body_bounds import install_http_body_bounds
from mitmproxy import ctx


class PurelineVerifiedFilter(PurelineRemoteFilter):
    def __init__(self):
        super().__init__()
        self.pool = None
        self.active_inspections = {}
        self.reserved_images = {}
        self.bounds = None
        self.header_capacity = 10
        self.header_timeout = 18.0
        self.header_peak_active = 0

    def load(self, loader):
        super().load(loader)
        try:
            self.bounds = install_http_body_bounds()
        except Exception:
            ctx.log.error("Pureline refused unverified HTTP transport source")
            raise SystemExit(78)

    def create_runtime(self, settings):
        if settings.section("proxy").get("fail_action") != "replace":
            raise RuntimeError("The bounded candidate requires fail-closed replacement")
        maximum = int(settings.section("proxy").get("max_body_bytes", MAXIMUM_IMAGE_BYTES))
        if not 0 < maximum <= MAXIMUM_IMAGE_BYTES:
            raise RuntimeError("Image body limit must not exceed the verified 4 MiB ceiling")
        if self.bounds is not None:
            self.bounds.maximum_bytes = maximum
        # Models are loaded only inside the owned worker processes.
        return SimpleNamespace(settings=settings, selected_providers={"execution": ["isolated-process"]})

    async def running(self):
        super().running()
        self.eligibility.allowed_content_types.add("image/svg+xml")
        proxy = self.runtime.settings.section("proxy")
        workers = min(int(self.runtime.settings.section("runtime").get("process_workers", 2)),
                      int(proxy.get("max_parallel_images", 2)),
                      int(self.runtime.settings.section("runtime").get("max_concurrent_inference", 1)))
        queued = int(proxy.get("max_queued_images", 8))
        self.header_capacity = workers + queued
        self.header_timeout = float(proxy.get("request_timeout_seconds", 18))
        candidate_pool = BoundedProcessPool(
            self.worker_command(),
            workers=workers,
            queued=queued,
            timeout=self.header_timeout,
        )
        try:
            await candidate_pool.warm_up()
        except BaseException:
            ctx.master.shutdown()
            raise
        # Listeners can accept before the async running hook completes.
        # Publish only fully warmed workers; headers fail closed until then.
        self.pool = candidate_pool

    def worker_command(self):
        return [sys.executable, str(PACKAGE / "downstream/pipeline_worker.py"),
                str(self.runtime.settings.source_path or "")]

    def responseheaders(self, flow):
        super().responseheaders(flow)
        if not image_response(flow):
            return
        if self.bounds is None or self.pool is None or self.pool.closed:
            self._count("image_runtime_not_ready")
            flow.kill()
            return
        if flow.id not in self.reserved_images:
            if len(self.reserved_images) >= self.header_capacity:
                self._count("image_header_capacity_rejections")
                flow.kill()
                return
            deadline = time.monotonic() + self.header_timeout
            self.reserved_images[flow.id] = (flow.client_conn.id, deadline)
            flow.metadata[DEADLINE_KEY] = deadline
            self.header_peak_active = max(self.header_peak_active, len(self.reserved_images))

    async def inspect(self, content, mime_type, flow):
        task = asyncio.current_task()
        self.active_inspections[flow.id] = (flow.client_conn.id, task)
        try:
            deadline = getattr(flow, "metadata", {}).get(DEADLINE_KEY)
            remaining = None if deadline is None else deadline - time.monotonic()
            return decode_outcome(await self.pool.inspect(content, mime_type, timeout=remaining))
        finally:
            self.active_inspections.pop(flow.id, None)

    async def response(self, flow):
        try:
            if self.pool is None:
                response = flow.response
                if response is not None and image_response(flow):
                    body, content_type = create_failure_placeholder(b"", text="Image analysis unavailable")
                    apply_replacement(response, body, content_type, reason="runtime-not-ready")
                return
            await super().response(flow)
        finally:
            self.reserved_images.pop(flow.id, None)

    def error(self, flow):
        super().error(flow)
        self.reserved_images.pop(flow.id, None)
        pending = self.active_inspections.get(flow.id)
        if pending and pending[1] is not asyncio.current_task():
            pending[1].cancel()

    def client_disconnected(self, client):
        for flow_id, (connection_id, _) in tuple(self.reserved_images.items()):
            if connection_id == client.id:
                self.reserved_images.pop(flow_id, None)
        for connection_id, task in tuple(self.active_inspections.values()):
            if connection_id == client.id:
                task.cancel()

    def done(self):
        if self.pool is not None:
            self.pool.close_now()


addons = [PurelineVerifiedFilter()]
