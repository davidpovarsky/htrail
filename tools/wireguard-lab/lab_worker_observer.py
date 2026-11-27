"""Lab-only fixed-public-SVG and worker observation; no filtering decisions.

Load after the candidate, before its async running hook. The paired launcher
executes the same frozen pipeline worker with the same config and limits.
"""
from __future__ import annotations

import hashlib
import importlib.util
import os
from pathlib import Path
import time

from mitmproxy import ctx

DRIVER = Path(__file__).resolve().with_name("lab_observed_pipeline_worker.py")
spec = importlib.util.spec_from_file_location("_pureline_lab_observer_support", DRIVER)
support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)


class PurelineLabWorkerObserver:
    def load(self, loader):
        manifest = Path(os.environ["PURELINE_BROWSER_MANIFEST"]).resolve()
        if hashlib.sha256(manifest.read_bytes()).hexdigest() != support.EXPECTED_MANIFEST:
            raise SystemExit("Observer refused an unexpected runtime manifest")
        candidate = ctx.master.addons.get("purelineverifiedfilter")
        if candidate is None or candidate.pool is not None or getattr(candidate, "_lab_observed", False):
            raise SystemExit("Observer must attach once, after candidate load and before warmup")
        ledger = support.Ledger(os.environ["PURELINE_LAB_OBSERVER_DIRECTORY"], "parent.json")
        original_command = candidate.worker_command
        original_inspect = candidate.inspect

        def observed_command():
            command = original_command()
            if (len(command) != 3 or
                    Path(command[1]).resolve() != manifest.parent / "downstream/pipeline_worker.py"):
                raise RuntimeError("Unexpected original worker command")
            return [command[0], str(DRIVER), command[1], command[2]]

        async def observed_inspect(content, mime_type, flow):
            request = flow.request
            target = (request.method, request.scheme, request.host, request.port, request.path) == (
                "GET", "https", "upload.wikimedia.org", 443,
                "/wikipedia/commons/4/4c/Wikisource-logo.svg")
            if not target:
                return await original_inspect(content, mime_type, flow)
            ledger.record("parent-svg-input", input_bytes=len(content),
                          input_sha256=hashlib.sha256(content).hexdigest())
            start = time.monotonic()
            try:
                result = await original_inspect(content, mime_type, flow)
            except BaseException as error:
                values = {"exception_type": support.safe_type(error),
                          "elapsed_ms": round((time.monotonic() - start) * 1000, 2)}
                if error.__cause__ is not None:
                    values["cause_type"] = support.safe_type(error.__cause__)
                ledger.record("parent-inspect-error", **values)
                raise
            ledger.record("parent-inspect-complete",
                          elapsed_ms=round((time.monotonic() - start) * 1000, 2))
            return result

        candidate.worker_command = observed_command
        candidate.inspect = observed_inspect
        candidate._lab_observed = True
        ledger.record("observer-attached")


addons = [PurelineLabWorkerObserver()]
