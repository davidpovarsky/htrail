#!/usr/bin/env python3
"""Private model worker. Its parent owns deadlines, capacity and cancellation."""
from __future__ import annotations
import base64
import os
import sys
from pathlib import Path

PACKAGE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PACKAGE))
from downstream.worker_protocol import encode_message, read_message, encode_outcome


def main():
    protocol_out = sys.stdout.buffer
    # Library diagnostics must never corrupt the binary protocol or expose data.
    sys.stdout = sys.stderr
    from runtime_contract import prepare_runtime
    prepare_runtime()
    from local_image_filter.config import load_settings
    from downstream.runtime_factory import build_verified_runtime
    settings = load_settings(sys.argv[1])
    # Each mutable store has one writer; the package itself remains read-only.
    slot = str(int(os.environ.get("PURELINE_WORKER_SLOT", "0")))
    if settings.section("cache").get("enabled", True):
        cache = settings.path("cache.sqlite_path")
        settings.data["cache"]["sqlite_path"] = str(
            cache.with_name(cache.stem + ".worker-" + slot + cache.suffix)
        )
    if settings.section("diagnostics").get("enabled", False):
        settings.data["diagnostics"]["directory"] = str(
            settings.path("diagnostics.directory") / ("worker-" + slot)
        )
    runtime = build_verified_runtime(settings)
    maximum_bytes = int(settings.section("proxy").get("max_body_bytes", 4_194_304))
    protocol_out.write(encode_message({"ready": True, "providers": runtime.selected_providers}))
    protocol_out.flush()
    while True:
        request = read_message(sys.stdin.buffer)
        if request is None:
            return
        try:
            content = base64.b64decode(request["body"], validate=True)
            if not 0 < len(content) <= maximum_bytes:
                raise ValueError("worker-input-limit")
            outcome = runtime.pipeline.filter_bytes(content, str(request["mime"]), None)
            result = {"ok": True, "outcome": encode_outcome(outcome)}
        except Exception as error:
            # A sanitized class is sufficient; never transmit URLs or image bytes
            # in error diagnostics, and never serialize executable Python objects.
            result = {"ok": False, "error": error.__class__.__name__}
        protocol_out.write(encode_message(result))
        protocol_out.flush()


if __name__ == "__main__":
    main()
