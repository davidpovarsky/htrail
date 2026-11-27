"""Actual mitmproxy transport with a deterministic worker, for network controls."""
import json
import gc
import os
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from mitmproxy import http
from downstream import http_body_bounds
from downstream.pureline_addon_candidate import PurelineVerifiedFilter


class BoundaryFixture(PurelineVerifiedFilter):
    def load(self, loader):
        if os.environ.get("PURELINE_TEST_BAD_PIN") == "1":
            http_body_bounds.EXPECTED_VERSION = "intentionally-invalid-test-pin"
        super().load(loader)

    def worker_command(self):
        return [sys.executable, str(Path(__file__).with_name("fake_pipeline_worker.py"))]

    def request(self, flow):
        if flow.request.path == "/large-upload":
            self.upload_streamed = flow.request.stream is True
            self.upload_buffered_bytes = len(flow.request.raw_content or b"")
        if flow.request.path != "/__pureline_boundary_metrics":
            return
        gc.collect()
        value = {
            "ready": self.pool is not None,
            "reserved": len(self.reserved_images), "peak_reserved": self.header_peak_active,
            "counts": dict(self._counts),
            "pool": dict(self.pool.metrics) if self.pool else {},
            "workers": [w.process.pid for w in self.pool.workers if w.process] if self.pool else [],
            "peak_buffer_bytes": self.bounds.peak_buffer_bytes if self.bounds else None,
            "size_aborts": self.bounds.size_aborts if self.bounds else None,
            "body_timeouts": self.bounds.body_timeouts if self.bounds else None,
            "upload_streamed": getattr(self, "upload_streamed", None),
            "upload_buffered_bytes": getattr(self, "upload_buffered_bytes", None),
            "finished_image_bytes_retained": sum(len(stream.flow.response.raw_content or b"")
                for stream in self.bounds.weak_streams if not stream.flow.live) if self.bounds else None,
            "strong_image_wakeup_routes": sum(1 for parent in self.bounds.weak_parents
                for command in parent.command_sources
                if hasattr(command, "_pureline_owner") and command._pureline_owner() is parent) if self.bounds else None,
        }
        flow.response = http.Response.make(200, json.dumps(value).encode(),
                                           {"content-type": "application/json", "cache-control": "no-store"})


addons = [BoundaryFixture()]
