#!/usr/bin/env python3
"""Real-model cache/diagnostic check against an immutable candidate package.

Run as the deployment user. Only the supplied writable work/report paths are
modified; generated stores are removed after evidence has been collected.
"""
from __future__ import annotations
import argparse
import asyncio
import hashlib
import io
import json
import os
import pwd
from pathlib import Path
import re
import sqlite3
import sys
import tempfile
import time
from datetime import datetime, timezone


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def private_values(value):
    """Report field names only, never the possibly sensitive values."""
    found = []
    if isinstance(value, dict):
        for key, item in value.items():
            if key in {"url", "imageBytes", "authorization", "cookies", "proxyCredentials"} and item:
                found.append(key)
            found.extend(private_values(item))
    elif isinstance(value, list):
        for item in value:
            found.extend(private_values(item))
    return found


async def main(args):
    package = args.package.resolve()
    manifest_path = package / "runtime-candidate-20261127-bounded-v5.json"
    assert digest(manifest_path) == args.manifest_sha256
    manifest = json.loads(manifest_path.read_text())
    for name, sha in manifest["files"].items():
        assert digest(package / name) == sha, name
    before = {str(p.relative_to(package)): digest(p) for p in package.rglob("*") if p.is_file()}
    assert all(p.stat().st_uid == 0 and p.stat().st_mode & 0o222 == 0
               for p in package.rglob("*"))
    assert os.getuid() != 0, "Run as the configured unprivileged runtime user"
    assert os.environ.get("PYTHONDONTWRITEBYTECODE") == "1"
    sys.path.insert(0, str(package))
    from runtime_contract import prepare_runtime
    prepare_runtime()
    from downstream.process_pool import BoundedProcessPool
    from downstream.worker_protocol import decode_outcome
    from PIL import Image

    fixtures = [
        ("allow", "static-allow.jpg", "d1a3e08d4e37d6ee2b7de1db8df87c1dc7acd8ffb004caaf980917de518a60c9"),
        ("blur", "static-block.jpg", "2b60a52f98219bd878af04c6c7a7cbbd291bae76598bbdf3c1148ce294256869"),
    ]
    payloads = {}
    for action, name, sha in fixtures:
        body = (args.fixtures / name).read_bytes()
        assert hashlib.sha256(body).hexdigest() == sha
        payloads[action] = body

    rows, stores, diagnostics, process_ids = [], [], [], []
    args.work.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="pureline-cache-v5-", dir=args.work) as temp:
        work = Path(temp)
        cache = work / "cache" / "decisions-20261127-bounded-v5.sqlite3"
        diag = work / "diagnostics"
        reference = (package / "candidate.toml").read_text()
        config_text = reference.replace("enabled = false", "enabled = true")
        config_text = re.sub(r"^sqlite_path = .*$", "sqlite_path = " + json.dumps(str(cache)),
                             config_text, flags=re.MULTILINE)
        config_text = re.sub(r"^directory = .*$", "directory = " + json.dumps(str(diag)),
                             config_text, flags=re.MULTILINE)
        config = work / "cache-enabled.toml"
        config.write_text(config_text)
        command = [sys.executable, str(package / "downstream/pipeline_worker.py"), str(config)]

        for phase in ("initial", "restart"):
            pool = BoundedProcessPool(command, workers=2, queued=8, timeout=18)
            try:
                await pool.warm_up()
                process_ids.extend(worker.process.pid for worker in pool.workers)
                rounds = (False, True) if phase == "initial" else (True,)
                for expected_hit in rounds:
                    for expected_action, _, _ in fixtures:
                        for slot in range(2):
                            started = time.monotonic()
                            outcome = decode_outcome(await pool.inspect(payloads[expected_action], "image/jpeg"))
                            replacement_decodes = None
                            if outcome.replacement_bytes is not None:
                                with Image.open(io.BytesIO(outcome.replacement_bytes)) as image:
                                    image.verify()
                                replacement_decodes = True
                            passed = (outcome.decision.action.value == expected_action and
                                      outcome.cache_hit is expected_hit and
                                      (outcome.replacement_bytes is None if expected_action == "allow"
                                       else replacement_decodes is True))
                            rows.append({"phase": phase, "worker_slot": slot,
                                         "expected_action": expected_action,
                                         "action": outcome.decision.action.value,
                                         "expected_cache_hit": expected_hit, "cache_hit": outcome.cache_hit,
                                         "replacement_decodes": replacement_decodes,
                                         "elapsed_ms": round((time.monotonic() - started) * 1000, 2),
                                         "passed": passed})
                            assert passed, rows[-1]
            finally:
                await pool.close()
        assert all(not Path(f"/proc/{pid}").exists() for pid in process_ids)
        assert not cache.exists(), "Workers must not share the unsuffixed database"
        for slot in range(2):
            file = cache.with_name(cache.stem + f".worker-{slot}" + cache.suffix)
            assert file.exists()
            with sqlite3.connect(f"file:{file}?mode=ro", uri=True) as connection:
                entries = connection.execute(
                    "SELECT content_hash,response_json,decision_json FROM analysis_cache_v2"
                ).fetchall()
            assert len(entries) == 2
            assert {row[0] for row in entries} == {sha for _, _, sha in fixtures}
            for _, response, decision in entries:
                assert not private_values(json.loads(response))
                assert not private_values(json.loads(decision))
            stores.append({"worker_slot": slot, "filename": file.name, "entries": len(entries),
                           "owner_uid": file.stat().st_uid, "raw_image_fields": False})
            event_file = diag / f"worker-{slot}" / "image-filter-events.jsonl"
            summary_file = diag / f"worker-{slot}" / "image-filter-summary.json"
            events = [json.loads(line) for line in event_file.read_text().splitlines()]
            summary = json.loads(summary_file.read_text())
            assert len(events) == 6
            assert sum(event["event"] == "imageAnalysisCacheHit" for event in events) == 4
            assert not private_values(events)
            assert summary["totalInspected"] == 2 and summary["cacheHits"] == 4
            diagnostics.append({"worker_slot": slot, "relative_directory": f"diagnostics/worker-{slot}",
                                "events": len(events), "cache_hits": summary["cacheHits"],
                                "total_inspected": summary["totalInspected"],
                                "private_fields_present": False})
        assert not any(p.suffix.lower() in {".jpg", ".jpeg", ".png", ".gif", ".webp"}
                       for p in work.rglob("*"))
        for p in work.rglob("*"):
            if p.is_file():
                content = p.read_bytes()
                assert all(body not in content for body in payloads.values())
        config_sha = digest(config)
    assert not work.exists()
    after = {str(p.relative_to(package)): digest(p) for p in package.rglob("*") if p.is_file()}
    assert before == after, "Immutable package changed or acquired generated files"
    report = {"schema": 1, "created_utc": datetime.now(timezone.utc).isoformat(),
              "passed": all(row["passed"] for row in rows), "cases": len(rows),
              "actual_models": True, "new_independent_accuracy_samples": 0,
              "runtime_uid": os.getuid(), "runtime_user": pwd.getpwuid(os.getuid()).pw_name,
              "manifest_sha256": digest(manifest_path), "package_files_unchanged": True,
              "package_file_count": len(before), "workers": 2,
              "worker_processes_reaped": len(process_ids),
              "config_sha256": config_sha, "temporary_stores_removed": True,
              "raw_image_disk_spool": False, "rows": rows, "stores": stores,
              "diagnostics": diagnostics,
              "source_sha256": {name: digest(package / name) for name in manifest["files"]}}
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items()
                      if key not in {"rows", "source_sha256"}}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--fixtures", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--manifest-sha256", default="e9b4424cce6a376c9ac2620cf5b5ad0ac0680264e5653042dc29eb812b13711b")
    asyncio.run(main(parser.parse_args()))
