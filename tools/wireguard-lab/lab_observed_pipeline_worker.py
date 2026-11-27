#!/usr/bin/env python3
"""Lab-only observation around the unchanged, frozen pipeline worker.

No renderer arguments, error messages, URLs, or image bytes are persisted.
The original functions receive the original arguments and their exact result or
exception is returned. This script does not change any inspection limit.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import time

EXPECTED_MANIFEST = "a6bbb87f9ea665e51ae4f964c843483626195f76caaa57358a76d94b270e641d"
SAFE_TYPES = frozenset({
    "SVGInspectionError", "InspectionFailure", "InspectionTimeout",
    "QueueCapacityExceeded", "TimeoutExpired", "TimeoutError", "CancelledError",
    "MemoryError", "ImportError", "ModuleNotFoundError", "PermissionError",
    "ValueError", "OSError", "RuntimeError", "RecursionError", "TypeError",
    "KeyError", "IndexError", "AssertionError", "EOFError", "BrokenPipeError",
    "ConnectionResetError", "IncompleteReadError", "SystemExit",
})
SAFE_STAGES = frozenset({
    "observer-attached", "worker-start", "worker-ready", "worker-error",
    "svg-render-start", "svg-render-finish", "svg-render-error",
    "parent-svg-input", "parent-inspect-complete", "parent-inspect-error",
})


def safe_type(value):
    name = value if isinstance(value, str) else type(value).__name__
    return name if name in SAFE_TYPES else "Other"


class Ledger:
    """At most 32 small, fixed-schema observations in a private lab directory."""

    def __init__(self, directory, name):
        self.directory = Path(directory).resolve()
        info = self.directory.stat()
        if info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise RuntimeError("A private observer directory owned by the runtime uid is required")
        self.path = self.directory / name
        self.events = []

    def record(self, stage, **values):
        # Observation failures must not turn a passing inspection into a failure.
        try:
            if stage not in SAFE_STAGES:
                return
            event = {"stage": stage}
            for key in ("exception_type", "cause_type", "stderr_type"):
                if key in values:
                    event[key] = safe_type(values[key])
            for key in ("elapsed_ms", "returncode", "input_bytes"):
                value = values.get(key)
                if isinstance(value, (int, float)) and not isinstance(value, bool):
                    event[key] = value
            digest = values.get("input_sha256", "")
            if len(digest) == 64 and all(c in "0123456789abcdef" for c in digest):
                event["input_sha256"] = digest
            self.events = (self.events + [event])[-32:]
            payload = {"schema": 1, "pid": os.getpid(), "events": self.events}
            temporary = self.path.with_suffix(".tmp")
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as stream:
                json.dump(payload, stream, sort_keys=True, allow_nan=False)
                stream.write("\n")
            os.replace(temporary, self.path)
        except (OSError, TypeError, ValueError):
            return


def install_worker_observers(protocol, renderer_path, ledger):
    original_encode = protocol.encode_message
    original_run = subprocess.run

    def observed_encode(value):
        result = original_encode(value)
        if isinstance(value, dict):
            if value.get("ready") is True:
                ledger.record("worker-ready")
            elif value.get("ok") is False:
                ledger.record("worker-error", exception_type=safe_type(value.get("error")))
        return result

    def observed_run(*args, **kwargs):
        command = args[0] if args else kwargs.get("args", ())
        if not isinstance(command, (list, tuple)) or renderer_path not in command:
            return original_run(*args, **kwargs)
        start = time.monotonic()
        # These are the actual decoded SVG bytes supplied by the unchanged
        # SVGInspectingPipeline. Transparent WireGuard request.host is an IP,
        # so this identity does not depend on the parent's hostname condition.
        content = kwargs.get("input")
        identity = ({"input_bytes": len(content),
                     "input_sha256": hashlib.sha256(content).hexdigest()}
                    if isinstance(content, bytes) else {})
        ledger.record("svg-render-start", **identity)
        try:
            result = original_run(*args, **kwargs)
        except BaseException as error:
            ledger.record("svg-render-error", exception_type=safe_type(error),
                          elapsed_ms=round((time.monotonic() - start) * 1000, 2))
            raise
        stderr = result.stderr if isinstance(result.stderr, bytes) else b""
        # svg_worker already emits only a class or its fixed presentation marker.
        error_type = stderr[:128].decode(errors="replace").strip()
        values = {"returncode": result.returncode,
                  "elapsed_ms": round((time.monotonic() - start) * 1000, 2)}
        if error_type and error_type != "PURELINE_RASTERIZED_ALLOW":
            values["stderr_type"] = safe_type(error_type)
        ledger.record("svg-render-finish", **values)
        return result

    protocol.encode_message = observed_encode
    subprocess.run = observed_run


def main():
    if len(sys.argv) != 3:
        raise SystemExit("Expected frozen worker and configuration paths")
    worker = Path(sys.argv[1]).resolve()
    manifest = Path(os.environ["PURELINE_BROWSER_MANIFEST"]).resolve()
    if (hashlib.sha256(manifest.read_bytes()).hexdigest() != EXPECTED_MANIFEST or
            worker != manifest.parent / "downstream/pipeline_worker.py"):
        raise SystemExit("Unexpected frozen runtime identity")
    slot = int(os.environ["PURELINE_WORKER_SLOT"])
    if slot not in (0, 1):
        raise SystemExit("The observer is scoped to the two-worker lab")
    ledger = Ledger(os.environ["PURELINE_LAB_OBSERVER_DIRECTORY"], f"worker-{slot}.json")
    ledger.record("worker-start")
    sys.path.insert(0, str(manifest.parent))
    from downstream import worker_protocol
    install_worker_observers(worker_protocol, str(worker.with_name("svg_worker.py")), ledger)
    # pipeline_worker performs its normal complete source/config/model checks.
    sys.argv = [str(worker), sys.argv[2]]
    runpy.run_path(str(worker), run_name="__main__")


if __name__ == "__main__":
    main()
