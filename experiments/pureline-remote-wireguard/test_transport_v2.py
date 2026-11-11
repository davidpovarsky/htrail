"""Contract tests for Pureline's remote WireGuard image-response adapter.

These tests deliberately do not use real user images or connect to live sites.
"""
from __future__ import annotations

from types import SimpleNamespace
import unittest

from mitmproxy.http import Response

from pureline_addon_v2 import PurelineRemoteFilter, sniff_image_mime


class TestRemoteImageTransport(unittest.TestCase):
    def setUp(self) -> None:
        self.filter = PurelineRemoteFilter()

    def test_image_signatures(self) -> None:
        samples = {
            "ffd8ff": "image/jpeg",
            "89504e470d0a1a0a": "image/png",
            "474946383961": "image/gif",
            "524946463030303057454250": "image/webp",
            "30303030667479706176696630303030": "image/avif",
            "30303030667479706865696330303030": "image/heic",
        }
        for hexdump, mime in samples.items():
            with self.subTest(mime=mime):
                self.assertEqual(sniff_image_mime(bytes.fromhex(hexdump)), mime)
        for sample in (b"", b"<html>", b"not a jpg", b"RIFFxxxxWAVExxxx"):
            with self.subTest(sample=sample):
                self.assertIsNone(sniff_image_mime(sample))

    def test_keep_image_bodies_buffered(self) -> None:
        for mime in ("image/jpeg", "image/png", "image/webp", "application/octet-stream", ""):
            with self.subTest(mime=mime):
                response = Response.make(200, b"test", {"content-type": mime})
                self.filter.responseheaders(SimpleNamespace(response=response))
                self.assertFalse(response.stream)

    def test_buffer_document_assets_instead_of_streaming(self) -> None:
        for mime in (
            "text/html", "text/css", "application/javascript",
            "application/json", "text/plain",
        ):
            with self.subTest(mime=mime):
                response = Response.make(200, b"test", {"content-type": mime})
                self.filter.responseheaders(SimpleNamespace(response=response))
                self.assertFalse(response.stream)

    def test_stream_long_running_and_large_assets(self) -> None:
        for mime in ("text/event-stream", "video/mp4", "audio/mpeg", "application/x-ndjson"):
            with self.subTest(mime=mime):
                response = Response.make(200, b"", {"content-type": mime})
                self.filter.responseheaders(SimpleNamespace(response=response))
                self.assertTrue(response.stream)
        response = Response.make(200, b"", {"content-type": "application/wasm"})
        response.headers["content-length"] = "3000000"
        self.filter.responseheaders(SimpleNamespace(response=response))
        self.assertTrue(response.stream)

    def test_errors_and_metrics_only_aggregate(self) -> None:
        self.filter.error(SimpleNamespace(error=SimpleNamespace(msg="private user path")))
        self.assertEqual(self.filter._counts["transport_errors"], 1)
        self.assertNotIn("private", str(self.filter._counts))


if __name__ == "__main__":
    unittest.main()
