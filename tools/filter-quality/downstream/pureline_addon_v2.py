"""Pureline trial add-on: conservative image inspection, streaming and aggregate diagnostics.

No raw image bytes, URLs, headers, hostname, cookies or credentials are logged.
Preserves the existing content policy. All allowed images are forwarded unchanged.
"""
from __future__ import annotations

import json
from collections import Counter
from pathlib import Path
from time import monotonic

from mitmproxy import http
from downstream.pureline_http_addon import LocalImageFilterAddon, apply_replacement
from local_image_filter.image.rewrite import create_failure_placeholder
from downstream.http_input import AMBIGUOUS, image_response, bounded_content, BoundedContentError

STREAMING_TYPES = frozenset({
    "text/event-stream", "application/x-ndjson", "application/stream+json",
    "application/x-protobuf",
})


def sniff_image_mime(body: bytes) -> str | None:
    """Recognize safe image signatures; do not trust a filename or URL."""
    if body.startswith(bytes.fromhex("ffd8ff")):
        return "image/jpeg"
    if body.startswith(bytes.fromhex("89504e470d0a1a0a")):
        return "image/png"
    if body[:4] == b"RIFF" and body[8:12] == b"WEBP":
        return "image/webp"
    if body.startswith((b"GIF87a", b"GIF89a")):
        return "image/gif"
    if len(body) >= 16 and body[4:8] == b"ftyp":
        brands = {body[8:12], body[12:16]}
        if brands & {b"avif", b"avis"}:
            return "image/avif"
        if brands & {b"heic", b"heix", b"hevc", b"hevx", b"mif1", b"msf1"}:
            return "image/heic"
    return None


class PurelineRemoteFilter(LocalImageFilterAddon):
    def __init__(self) -> None:
        super().__init__()
        self._counts: Counter[str] = Counter()
        self._last_write = monotonic()
        self._health_file: Path | None = None

    def running(self) -> None:
        super().running()
        assert self.runtime is not None
        self._health_file = (
            self.runtime.settings.path("diagnostics.directory") / "transport-summary.json"
            if self.runtime.settings.section("diagnostics").get("enabled", False) else None
        )

    def _count(self, event: str) -> None:
        self._counts[event] += 1
        now = monotonic()
        if self._health_file and (
            now - self._last_write > 10 or sum(self._counts.values()) % 50 == 0
        ):
            tmp = self._health_file.with_suffix(".tmp")
            try:
                tmp.write_text(json.dumps(dict(sorted(self._counts.items())), indent=2) + "\n")
                tmp.replace(self._health_file)
            except OSError:
                # Observability must never interrupt an image response.
                self._health_file = None
            self._last_write = now

    @staticmethod
    def _mime_type(response: http.Response) -> str:
        return response.headers.get("content-type", "").split(";", 1)[0].lower().strip()

    def requestheaders(self, flow: http.HTTPFlow) -> None:
        # This server does not inspect or rewrite upload bodies. Use the public
        # streaming seam instead of retaining complete uploads in the parent.
        flow.request.stream = True

    def responseheaders(self, flow: http.HTTPFlow) -> None:
        response = flow.response
        if response is None:
            return
        mime = self._mime_type(response)
        if mime.startswith("image/") or mime in AMBIGUOUS:
            response.stream = False
            return  # image responses must be buffered so the AI can analyze
        # No downstream inspection mutates non-image bodies. Let HTML, CSS,
        # JavaScript and streams render while independent images are inspected.
        response.stream = True
        self._count("streamed_nonimage")

    async def response(self, flow: http.HTTPFlow) -> None:
        response = flow.response
        if response is None:
            return
        mime = self._mime_type(response)
        if not image_response(flow):
            return
        try:
            content = bounded_content(response, int(self.runtime.settings.section("proxy").get(
                "max_body_bytes", 4_194_304)))
        except BoundedContentError as error:
            body, content_type = create_failure_placeholder(b"", text="Image decoding unavailable")
            apply_replacement(response, body, content_type, reason=error.reason)
            self._count("image_pipeline_failure")
            return
        if mime in AMBIGUOUS and response.status_code in (200, 206):
            if recognized := sniff_image_mime(content):
                response.headers["content-type"] = recognized
                self._count("image_mime_corrected")
        if response.status_code >= 500:
            self._count("origin_http_5xx")
        elif response.status_code >= 400:
            self._count("origin_http_4xx")
        await super().response(flow, inspected_content=content)
        action = response.headers.get("x-local-image-filter", "")
        if action in {"allow", "blur", "replace"}:
            self._count(f"image_{action}")
        if response.headers.get("x-local-image-filter-reason") in {
            "model-failure", "missing-rewrite", "policy-error",
            "inspection-timeout", "inspection-queue-full", "worker-failure",
        }:
            self._count("image_pipeline_failure")

    def error(self, flow: http.HTTPFlow) -> None:
        # Only aggregate counts. Never log hostnames, request paths or TLS errors
        # verbatim: they might contain sensitive user information.
        self._count("transport_errors")


addons = [PurelineRemoteFilter()]
