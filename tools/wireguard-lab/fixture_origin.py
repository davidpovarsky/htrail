"""Strict Oracle-local fixture origin for the isolated WireGuard lab only.

Requests still traverse the Mac WireGuard client and Oracle WireGuard server.
The normal Pureline response hook subsequently inspects these image bytes.
No public listener, host route, DNS override, or production service is changed.
This synthetic origin is integration evidence, never independent public-origin
or classifier-accuracy evidence.
"""
from __future__ import annotations

import hashlib
import json
import os
import logging
import time
import re
from pathlib import Path
from urllib.parse import urlsplit

from mitmproxy import http

HOST = "192.0.2.1"
PREFIX = "/pureline-lab-20261127/fixtures/"
ROOT = Path(os.environ.get(
    "PURELINE_LAB_FIXTURES", str(Path(__file__).resolve().parent / "fixtures")
)).resolve()
MAX_BYTES = 4 * 1024 * 1024
ALLOWED_MIME = frozenset({"image/svg+xml", "image/jpeg", "image/png", "image/webp", "image/gif"})


class FixtureErrorAudit(logging.Handler):
    def emit(self, record):
        message = record.getMessage()
        prefix = "Image filter pipeline error: "
        if not message.startswith(prefix): return
        error_class = message[len(prefix):].split(":", 1)[0]
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{0,80}", error_class): error_class = "UnclassifiedError"
        boundary = next((v for v in ("SVG inspection timed out", "SVG rejected by bounded renderer", "SVG exceeds inspection bounds") if v in message), None)
        try:
            (ROOT.parent / "fixture-error-probe.json").write_text(json.dumps({"timestamp": time.time(), "error_class": error_class, "boundary": boundary}, indent=2) + "\n")
        except OSError: pass


class PurelineFixtureOrigin:
    def __init__(self) -> None:
        self._error_audit = FixtureErrorAudit(level=logging.ERROR)
        logging.getLogger().addHandler(self._error_audit)
        manifest = json.loads((ROOT / "manifest.json").read_text())
        self._fixtures: dict[str, tuple[bytes, str, str]] = {}
        for entry in manifest["fixtures"]:
            name = entry["filename"]
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,120}", name):
                raise ValueError("Invalid fixture filename")
            location = (ROOT / name).resolve()
            if location.parent != ROOT or not location.is_file():
                raise ValueError("Fixture outside the fixed directory")
            if entry["content_type"] not in ALLOWED_MIME:
                raise ValueError("Unexpected fixture content type")
            body = location.read_bytes()
            digest = hashlib.sha256(body).hexdigest()
            if len(body) > MAX_BYTES or digest != entry["sha256"]:
                raise ValueError("Fixture size/hash does not match manifest")
            if name in self._fixtures:
                raise ValueError("Duplicate fixture filename")
            self._fixtures[name] = (body, entry["content_type"], digest)

    def request(self, flow: http.HTTPFlow) -> None:
        req = flow.request
        if req.host != HOST or req.port != 80 or req.scheme != "http":
            return
        path = urlsplit(req.path).path
        if req.method != "GET":
            flow.response = http.Response.make(405, b"Fixture origin accepts GET only.\n",
                                                {"content-type": "text/plain", "cache-control": "no-store"})
            return
        if not path.startswith(PREFIX) or path[len(PREFIX):] not in self._fixtures:
            flow.response = http.Response.make(404, b"Unknown laboratory fixture.\n",
                                                {"content-type": "text/plain", "cache-control": "no-store"})
            return
        name = path[len(PREFIX):]
        body, mime, digest = self._fixtures[name]
        flow.metadata["pureline_lab_fixture"] = name
        flow.response = http.Response.make(200, body, {
            "content-type": mime,
            "cache-control": "no-store",
            "x-pureline-lab-origin": "oracle-controlled-fixture",
            "x-pureline-lab-source-sha256": digest,
        })


    def responseheaders(self, flow: http.HTTPFlow) -> None:
        name = flow.metadata.get("pureline_lab_fixture")
        if name != "randomuser-women-77.svg" or flow.response is None: return
        body = flow.response.content
        expected = self._fixtures[name][2]
        digest = hashlib.sha256(body).hexdigest() if body is not None else None
        (ROOT.parent / "fixture-input-probe.json").write_text(json.dumps({"stage": "responseheaders-before-response-filter", "timestamp": time.time(), "fixture": name, "mime_type": flow.response.headers.get("content-type"), "decoded_body_bytes": len(body) if body is not None else None, "decoded_body_sha256": digest, "expected_sha256": expected, "matches_fixture": digest == expected}, indent=2) + "\n")

    def done(self) -> None:
        logging.getLogger().removeHandler(self._error_audit)


addons = [PurelineFixtureOrigin()]
