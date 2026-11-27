"""Pinned downstream runtime with bounded and cancellable image inspection."""
from __future__ import annotations
import asyncio
import sys
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


class PurelineVerifiedFilter(PurelineRemoteFilter):
    def __init__(self):
        super().__init__()
        self.pool = None
        self.active_inspections = {}

    def create_runtime(self, settings):
        if settings.section("proxy").get("fail_action") != "replace":
            raise RuntimeError("The bounded candidate requires fail-closed replacement")
        # Models are loaded only inside the owned worker processes.
        return SimpleNamespace(settings=settings, selected_providers={"execution": ["isolated-process"]})

    async def running(self):
        super().running()
        self.eligibility.allowed_content_types.add("image/svg+xml")
        proxy = self.runtime.settings.section("proxy")
        workers = min(int(self.runtime.settings.section("runtime").get("process_workers", 2)),
                      int(proxy.get("max_parallel_images", 2)),
                      int(self.runtime.settings.section("runtime").get("max_concurrent_inference", 1)))
        self.pool = BoundedProcessPool(
            [sys.executable, str(PACKAGE / "downstream/pipeline_worker.py"),
             str(self.runtime.settings.source_path or "")],
            workers=workers,
            queued=int(proxy.get("max_queued_images", 8)),
            timeout=float(proxy.get("request_timeout_seconds", 18)),
        )
        await self.pool.warm_up()

    async def inspect(self, content, mime_type, flow):
        task = asyncio.current_task()
        self.active_inspections[flow.id] = (flow.client_conn.id, task)
        try:
            return decode_outcome(await self.pool.inspect(content, mime_type))
        finally:
            self.active_inspections.pop(flow.id, None)

    async def response(self, flow):
        if self.pool is None:
            response = flow.response
            if response is not None and 200 <= response.status_code < 300:
                mime = self._mime_type(response)
                is_image = mime.startswith("image/") or (
                    mime in AMBIGUOUS and sniff_image_mime(response.content or b"")
                )
                if is_image:
                    body, content_type = create_failure_placeholder(b"", text="Image analysis unavailable")
                    apply_replacement(response, body, content_type, reason="runtime-not-ready")
            return
        await super().response(flow)

    def error(self, flow):
        super().error(flow)
        pending = self.active_inspections.get(flow.id)
        if pending and pending[1] is not asyncio.current_task():
            pending[1].cancel()

    def client_disconnected(self, client):
        for connection_id, task in tuple(self.active_inspections.values()):
            if connection_id == client.id:
                task.cancel()

    def done(self):
        if self.pool is not None:
            self.pool.close_now()


addons = [PurelineVerifiedFilter()]
