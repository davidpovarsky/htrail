#!/usr/bin/env python3
"""Focused observer identity/privacy checks. No renderer, network, or model run."""
import argparse
import asyncio
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    from mitmproxy import http, version
    here = Path(__file__).resolve().parent
    driver = load("observer_check_driver", here / "lab_observed_pipeline_worker.py")
    cases = []

    def check(name, value):
        assert value, name
        cases.append({"name": name, "passed": True})

    with tempfile.TemporaryDirectory(prefix="pureline-observer-check-") as temporary:
        directory = Path(temporary)
        ledger = driver.Ledger(directory, "worker.json")
        protocol = SimpleNamespace(encode_message=lambda value: json.dumps(value).encode())
        encode = protocol.encode_message
        result = subprocess.CompletedProcess([], 2, b"PRIVATE_IMAGE_BYTES", b"https://private.invalid/secret")
        received = []
        failure = None

        def fake_run(*argv, **kwargs):
            received.append((argv, kwargs))
            if failure is not None:
                raise failure
            return result

        with patch.object(subprocess, "run", fake_run):
            driver.install_worker_observers(protocol, "/frozen/svg_worker.py", ledger)
            ready = {"ready": True}
            success = {"ok": True, "outcome": {"decision": "allow", "value": "PRIVATE_OUTCOME"}}
            check("ready_protocol_bytes_unchanged", protocol.encode_message(ready) == encode(ready))
            check("success_protocol_bytes_unchanged", protocol.encode_message(success) == encode(success))
            error = {"ok": False, "error": "SVGInspectionError"}
            check("failure_protocol_bytes_unchanged", protocol.encode_message(error) == encode(error))
            protocol.encode_message({"ok": False, "error": "PRIVATE_UNKNOWN_CLASS"})
            command = ["/python", "/frozen/svg_worker.py"]
            returned = subprocess.run(command, input=b"PRIVATE_IMAGE_BYTES", timeout=5)
            check("renderer_result_and_arguments_unchanged",
                  returned is result and received[-1] == ((command,), {"input": b"PRIVATE_IMAGE_BYTES", "timeout": 5}))
            observed_input = next(event for event in ledger.events if event["stage"] == "svg-render-start")
            check("renderer_stdin_sha_and_length_recorded",
                  observed_input["input_bytes"] == len(b"PRIVATE_IMAGE_BYTES") and
                  observed_input["input_sha256"] == hashlib.sha256(b"PRIVATE_IMAGE_BYTES").hexdigest())
            before = len(ledger.events)
            check("other_subprocess_passthrough", subprocess.run(["/other"]) is result and len(ledger.events) == before)
            failure = subprocess.TimeoutExpired("PRIVATE_COMMAND", 5)
            try:
                subprocess.run(command, input=b"PRIVATE_IMAGE_BYTES", timeout=5)
            except subprocess.TimeoutExpired as caught:
                check("renderer_exception_identity_preserved", caught is failure)
            else:
                raise AssertionError("renderer_exception_identity_preserved")
        text = ledger.path.read_text()
        check("worker_diagnostics_redacted", "PRIVATE" not in text and "https:" not in text and "Other" in text)
        for _ in range(100):
            ledger.record("worker-ready")
        check("ledger_is_bounded", len(json.loads(ledger.path.read_text())["events"]) == 32 and ledger.path.stat().st_size < 8192)

        package = directory / "package"
        package.mkdir()
        manifest = package / args.manifest.name
        manifest.write_bytes(args.manifest.read_bytes())
        expected_result = object()
        calls = []

        class Candidate:
            pool = None
            error = None

            def worker_command(self):
                return ["/python", str(package / "downstream/pipeline_worker.py"), "/same-config.toml"]

            async def inspect(self, content, mime_type, flow):
                calls.append((content, mime_type, flow))
                if self.error is not None:
                    raise self.error
                return expected_result

        candidate = Candidate()
        fake_mitm = SimpleNamespace(ctx=SimpleNamespace(master=SimpleNamespace(
            addons=SimpleNamespace(get=lambda name: candidate))))
        environment = {"PURELINE_BROWSER_MANIFEST": str(manifest),
                       "PURELINE_LAB_OBSERVER_DIRECTORY": str(directory)}
        with patch.dict(sys.modules, {"mitmproxy": fake_mitm}), patch.dict(os.environ, environment):
            addon = load("observer_check_addon", here / "lab_worker_observer.py")
            addon.addons[0].load(None)
            check("only_worker_launcher_is_substituted", candidate.worker_command() == [
                "/python", str(here / "lab_observed_pipeline_worker.py"),
                str(package / "downstream/pipeline_worker.py"), "/same-config.toml"])
            flow = SimpleNamespace(request=SimpleNamespace(method="GET", scheme="https",
                host="upload.wikimedia.org", pretty_host="upload.wikimedia.org", port=443,
                path="/wikipedia/commons/4/4c/Wikisource-logo.svg"))
            content = b"PRIVATE_FIXTURE_BYTES"
            check("parent_result_and_arguments_unchanged", asyncio.run(candidate.inspect(content, "image/svg+xml", flow)) is expected_result
                  and calls[-1] == (content, "image/svg+xml", flow))
            candidate.error = ValueError("PRIVATE_ERROR_WITH_URL_https://private.invalid")
            try:
                asyncio.run(candidate.inspect(content, "image/svg+xml", flow))
            except ValueError as caught:
                check("parent_exception_identity_preserved", caught is candidate.error)
            else:
                raise AssertionError("parent_exception_identity_preserved")
            parent_text = (directory / "parent.json").read_text()
            check("parent_diagnostics_redacted", "PRIVATE" not in parent_text and "https:" not in parent_text
                  and hashlib.sha256(content).hexdigest() in parent_text)
            candidate.error = None
            flow.request.host = "unrelated.invalid"
            flow.request.pretty_host = "unrelated.invalid"
            asyncio.run(candidate.inspect(b"PRIVATE_UNRELATED_BYTES", "image/png", flow))
            check("unrelated_flow_not_observed", (directory / "parent.json").read_text() == parent_text)
            request = http.Request.make("GET",
                "https://192.0.2.9/wikipedia/commons/4/4c/Wikisource-logo.svg")
            # Request.make's URL setter writes Host, just as routing changes
            # preserve an already parsed authority separately from data.host.
            request.headers["Host"] = "upload.wikimedia.org"
            actual_flow = SimpleNamespace(request=request)
            actual_body = b"PRIVATE_TRANSPARENT_FIXTURE"
            result = asyncio.run(candidate.inspect(actual_body, "image/svg+xml", actual_flow))
            observations = json.loads((directory / "parent.json").read_text())["events"]
            latest_input = next(event for event in reversed(observations) if event["stage"] == "parent-svg-input")
            check("real_mitm_request_transparent_host_authority",
                  request.host == "192.0.2.9" and request.pretty_host == "upload.wikimedia.org" and
                  result is expected_result and
                  latest_input["input_sha256"] == hashlib.sha256(actual_body).hexdigest() and
                  latest_input["input_bytes"] == len(actual_body))

    receipt = {"schema": 1, "passed": True, "tests": cases,
               "mitmproxy_version": version.VERSION,
               "real_models_run": False, "network_requests": 0, "renderer_processes": 0,
               "source_sha256": {name: hashlib.sha256((here / name).read_bytes()).hexdigest()
                                  for name in ("lab_worker_observer.py", "lab_observed_pipeline_worker.py", "check_lab_worker_observer.py")}}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"passed": True, "tests": len(cases), "output": str(args.output)}))


if __name__ == "__main__":
    main()
