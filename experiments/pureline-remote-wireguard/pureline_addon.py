"""Pureline's isolated mitmproxy adapter.

Reuse the project's tested AI pipeline. This wrapper recognizes image responses
mislabelled as octet-stream, streams clearly non-image content, and avoids
persisting user traffic. It does not modify the vendor repository.
"""
from __future__ import annotations

from mitmproxy import http

from local_image_filter.proxy.addon import LocalImageFilterAddon

AMBIGUOUS = frozenset({
    "", "application/octet-stream", "binary/octet-stream",
    "application/x-octet-stream", "application/x-binary",
})


def sniff_image_mime(body: bytes) -> str | None:
    """Conservative magic-byte checks; never infer from URL or extension."""
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
    def responseheaders(self, flow: http.HTTPFlow) -> None:
        """Do not buffer streaming chat, HTML, JSON, or huge media downloads."""
        response = flow.response
        if response is None:
            return
        declared = response.headers.get("content-type", "").split(";", 1)[0].lower().strip()
        if declared.startswith("image/") or declared in AMBIGUOUS:
            return
        response.stream = True

    async def response(self, flow: http.HTTPFlow) -> None:
        response = flow.response
        if response is None:
            return
        declared = response.headers.get("content-type", "").split(";", 1)[0].lower().strip()
        if declared in AMBIGUOUS and response.status_code in (200, 206):
            body = response.content or b""
            if mime := sniff_image_mime(body):
                response.headers["content-type"] = mime
        await super().response(flow)


addons = [PurelineRemoteFilter()]
