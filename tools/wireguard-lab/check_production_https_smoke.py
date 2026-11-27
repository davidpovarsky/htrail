#!/usr/bin/env python3
"""Prepared v6 production smoke. No traffic unless --execute is supplied.

Uses the existing loopback proxy and verified production CA. Never starts a
model/process/service, changes configuration, retries a request, or saves an
image. The owner coordinates activation and rollback separately.
"""
from __future__ import annotations
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import http.client
import io
import json
import os
from pathlib import Path
import platform
import signal
import sqlite3
import ssl
import threading
import time
import tomllib
from urllib.parse import urlsplit
import zlib

RELEASE = Path("/srv/pureline-poc/releases/20261127-wireguard-header-bounded-v6")
MANIFEST = "runtime-candidate-20261127-header-bounded-v6.json"
MANIFEST_SHA = "a6bbb87f9ea665e51ae4f964c843483626195f76caaa57358a76d94b270e641d"
CONFIG_SHA = "8198c25521d3064a636215cf399a000dd4dd6030b91f463221d8ba609bc6d4eb"
CA = Path("/srv/pureline-poc/wg-profile/mitmproxy-ca-cert.pem")
CA_SHA = "7429afe52de2cce4ff7a32120eba1e54d28856eeddc10ec52c3b32219ba15beb"
LIMIT = 4_194_304
FIXTURES = {
    "allow": {"url": "https://randomuser.me/api/portraits/men/54.jpg",
              "sha": "d1a3e08d4e37d6ee2b7de1db8df87c1dc7acd8ffb004caaf980917de518a60c9", "bytes": 5276},
    "block": {"url": "https://randomuser.me/api/portraits/women/77.jpg",
              "sha": "2b60a52f98219bd878af04c6c7a7cbbd291bae76598bbdf3c1148ce294256869", "bytes": 4082,
              "output_sha": "e207d17fcebf558e97358e0bae26474770e9c0c96b45fccb10b83e2790e73aec", "output_bytes": 979},
    "svg": {"url": "https://upload.wikimedia.org/wikipedia/commons/4/4c/Wikisource-logo.svg",
            "sha": "211b332af6138a7c2d5fce0b58586c63e03ea418060539dd315e61c0c0e49e95", "bytes": 16160},
}
SEQUENCE = ["allow", "block", "block", "allow"] * 2 + ["svg"]


class SmokeFailure(RuntimeError):
    pass


def require(value, code):
    if not value:
        raise SmokeFailure(code)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def parent_identity(pid):
    proc = Path("/proc") / str(pid)
    args = (proc / "cmdline").read_bytes().split(b"\0")
    require(str(RELEASE / "downstream/pureline_addon_candidate.py").encode() in args,
            "parent-candidate-path-mismatch")
    require(("local_image_filter_config=" + str(RELEASE / "production.toml")).encode() in args,
            "parent-config-path-mismatch")
    return {"pid": pid, "start_ticks": int((proc / "stat").read_text().rsplit(") ", 1)[1].split()[19])}


def listener_owned(pid):
    inodes = {line.split()[9] for line in Path("/proc/net/tcp").read_text().splitlines()[1:]
              if line.split()[1] == "0100007F:4862" and line.split()[3] == "0A"}
    # 18530 == 0x4862. Do not accept a wildcard or another process's listener.
    targets = set()
    for fd in (Path("/proc") / str(pid) / "fd").iterdir():
        try:
            targets.add(os.readlink(fd))
        except FileNotFoundError:
            pass
    return bool(inodes) and all(f"socket:[{inode}]" in targets for inode in inodes)


def workers(pid, require_idle=False):
    result = []
    children = (Path("/proc") / str(pid) / "task" / str(pid) / "children").read_text().split()
    read_call = {"x86_64": 0, "aarch64": 63}.get(platform.machine())
    for child in children:
        proc = Path("/proc") / child
        args = (proc / "cmdline").read_bytes().split(b"\0")
        if str(RELEASE / "downstream/pipeline_worker.py").encode() not in args:
            continue
        require(str(RELEASE / "production.toml").encode() in args, "worker-config-path-mismatch")
        selected = [value.split(b"=", 1)[1] for value in (proc / "environ").read_bytes().split(b"\0")
                    if value.startswith(b"PURELINE_WORKER_SLOT=")]
        require(len(selected) == 1 and selected[0] in (b"0", b"1"), "worker-slot-mismatch")
        row = {"pid": int(child), "slot": int(selected[0])}
        if require_idle:
            require(read_call is not None, "startup-observer-unsupported-architecture")
            syscall = (proc / "syscall").read_text().split()
            row["stdin_read_observed"] = (len(syscall) >= 3 and syscall[0] != "running" and
                int(syscall[0], 0) == read_call and int(syscall[1], 0) == 0 and
                os.readlink(proc / "fd/0").startswith("pipe:["))
        result.append(row)
    return sorted(result, key=lambda row: row["slot"])


def startup_guard(pid, identity, deadline):
    started = time.monotonic()
    while time.monotonic() < min(deadline, started + 60):
        require(parent_identity(pid) == identity, "parent-changed-during-startup")
        if listener_owned(pid):
            rows = workers(pid, require_idle=True)
            if ([row["slot"] for row in rows] == [0, 1] and
                    all(row["stdin_read_observed"] for row in rows)):
                return {"workers": rows, "elapsed_ms": round((time.monotonic() - started) * 1000, 2),
                        "scope": "Read-only observation of exact child main threads reading fd0 after ready; not an API health endpoint"}
        time.sleep(0.2)
    raise SmokeFailure("startup-idle-protocol-read-not-observed")


@contextmanager
def absolute_timeout(seconds):
    def expired(signum, frame):
        raise SmokeFailure("absolute-request-timeout")
    previous = signal.signal(signal.SIGALRM, expired)
    prior_timer = signal.getitimer(signal.ITIMER_REAL)
    started = time.monotonic()
    signal.setitimer(signal.ITIMER_REAL, min(seconds, prior_timer[0]) if prior_timer[0] else seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)
        if prior_timer[0]:
            remaining = prior_timer[0] - (time.monotonic() - started)
            if remaining <= 0:
                raise SmokeFailure("overall-deadline-exceeded")
            signal.setitimer(signal.ITIMER_REAL, remaining)


def decoded_body(raw, encoding):
    require(len(raw) <= LIMIT, "response-representation-too-large")
    if encoding in ("", "identity"):
        return raw
    require(encoding == "gzip", "unexpected-content-encoding")
    decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
    body = decoder.decompress(raw, LIMIT + 1)
    require(len(body) <= LIMIT and not decoder.unconsumed_tail and
            decoder.eof and not decoder.unused_data, "invalid-or-oversize-gzip")
    return body


def request_fixture(name, context, expected_cache, deadline, row):
    from PIL import Image
    fixture = FIXTURES[name]
    url = urlsplit(fixture["url"])
    remaining = min(30, deadline - time.monotonic())
    require(remaining > 0, "overall-deadline-exceeded")
    connection = http.client.HTTPSConnection("127.0.0.1", 18530, timeout=remaining, context=context)
    connection.set_tunnel(url.hostname, 443)
    started = time.monotonic()
    try:
        with absolute_timeout(remaining):
            connection.request("GET", url.path, headers={
                "User-Agent": "PurelineProductionSmoke/1.0 (+https://github.com/davidpovarsky/htrail)",
                "Accept-Encoding": "gzip", "Cache-Control": "no-cache", "Connection": "close"})
            response = connection.getresponse()
            headers = {key.lower(): value for key, value in response.getheaders()}
            row["status"] = response.status
            for header, key, allowed in (
                ("x-local-image-filter", "action", {"allow", "blur", "replace", "error"}),
                ("x-local-image-filter-cache", "cache", {"miss", "hit"}),
                ("x-local-image-filter-reason", "reason", {"policy", "worker-failure", "inspection-timeout",
                    "inspection-queue-full", "runtime-not-ready", "model-failure", "image-decode-error"})):
                value = headers.get(header)
                row[key] = value if value in allowed else ("other" if value else None)
            raw = response.read(LIMIT + 1)
            row["representation_bytes"] = len(raw)
            require(response.status == 200, "public-source-http-status")
            if "content-length" in headers:
                require(int(headers["content-length"]) == len(raw), "representation-length-mismatch")
            encoding = headers.get("content-encoding", "").lower().strip()
            body = decoded_body(raw, encoding)
            row.update(output_sha256=sha(body), decoded_bytes=len(body),
                       content_encoding=encoding or "identity")
            mime = headers.get("content-type", "").split(";", 1)[0].lower().strip()
            action = headers.get("x-local-image-filter")
            reason = headers.get("x-local-image-filter-reason")
            cache = headers.get("x-local-image-filter-cache")
            require(reason == "policy", "filter-nonpolicy-result")
            require(cache == expected_cache, "cache-result-mismatch")
            require(not headers.get("x-local-image-filter-policy-exception"), "unexpected-policy-exception")
            if name in ("allow", "svg"):
                require(action == "allow" and sha(body) == fixture["sha"] and len(body) == fixture["bytes"],
                        "allowed-public-source-identity-mismatch")
            else:
                require(action == "blur" and sha(body) != fixture["sha"], "blocked-image-not-blurred")
                require(sha(body) == fixture["output_sha"] and len(body) == fixture["output_bytes"],
                        "blocked-representation-identity-mismatch")
                require(not encoding and headers.get("cache-control") == "no-store", "rewrite-encoding-or-cache-policy")
            if name == "svg":
                # The byte-exact, already validated public fixture is pinned
                # above; no private renderer/vendor imports or extra render.
                from xml.etree import ElementTree
                require(mime == "image/svg+xml", "svg-mime-mismatch")
                element = ElementTree.fromstring(body)
                require(element.tag == "{http://www.w3.org/2000/svg}svg", "svg-xml-root-mismatch")
                dimensions = {"width": element.get("width"), "height": element.get("height"), "xml_parsed": True}
            else:
                require(mime in ("image/jpeg", "image/png"), "raster-mime-mismatch")
                with Image.open(io.BytesIO(body)) as image:
                    require(image.width * image.height <= LIMIT, "raster-pixel-limit")
                    require((image.width, image.height) == (128, 128), "raster-dimensions-mismatch")
                    require({"JPEG": "image/jpeg", "PNG": "image/png"}.get(image.format) == mime, "raster-mime-decode-mismatch")
                    image.load()
                    dimensions = {"width": image.width, "height": image.height, "decoded": True}
            return {"fixture": name, "passed": True, "status": 200, "action": action, "reason": reason,
                    "cache": cache, "expected_public_source_sha256": fixture["sha"],
                    "output_sha256": sha(body), "decoded_bytes": len(body), "representation_bytes": len(raw),
                    "content_encoding": encoding or "identity", "mime": mime, "dimensions": dimensions,
                    "elapsed_ms": round((time.monotonic() - started) * 1000, 2)}
    finally:
        row["elapsed_ms"] = round((time.monotonic() - started) * 1000, 2)
        connection.close()


class ResourceSampler:
    """Read cgroup counters only; includes service threads and descendants."""
    def __init__(self, pid):
        relative = next(line.split(":", 2)[2] for line in Path(f"/proc/{pid}/cgroup").read_text().splitlines()
                        if line.startswith("0::"))
        self.root = Path("/sys/fs/cgroup") / relative.lstrip("/")
        self.stop = threading.Event()
        self.result = {"scope": "Sampled during this probe, not all service startup", "interval_ms": 100,
                       "peak_memory_bytes": 0, "peak_tasks_including_threads": 0, "peak_processes": 0}
        self.result["memory_max"] = int((self.root / "memory.max").read_text())
        self.result["tasks_max"] = int((self.root / "pids.max").read_text())
        require(self.result["memory_max"] == 2_147_483_648 and self.result["tasks_max"] == 128,
                "service-resource-limit-mismatch")
        self.thread = threading.Thread(target=self.sample, daemon=True)

    def sample(self):
        while not self.stop.is_set():
            try:
                for filename, key in (("memory.current", "peak_memory_bytes"), ("pids.current", "peak_tasks_including_threads")):
                    self.result[key] = max(self.result[key], int((self.root / filename).read_text()))
                self.result["peak_processes"] = max(self.result["peak_processes"], len((self.root / "cgroup.procs").read_text().split()))
            except (OSError, ValueError):
                self.result["read_failed"] = True
            self.stop.wait(0.1)

    def finish(self):
        self.stop.set()
        if self.thread.ident is not None:
            self.thread.join(timeout=1)
        for name in ("memory.peak", "pids.peak"):
            path = self.root / name
            try:
                if path.is_file():
                    self.result["kernel_cgroup_lifetime_" + name.replace(".", "_")] = int(path.read_text())
            except (OSError, ValueError):
                self.result["read_failed"] = True
        return self.result


def private_fields(value):
    if isinstance(value, dict):
        return [key for key, item in value.items() if key in {
            "url", "sourceURL", "imageBytes", "authorization", "cookies", "proxyCredentials"} and item] + [
            found for item in value.values() for found in private_fields(item)]
    if isinstance(value, list):
        return [found for item in value for found in private_fields(item)]
    return []


def cache_snapshot(config, expect_fixture_entries=None):
    base = Path(config["cache"]["sqlite_path"])
    require(not base.exists(), "unexpected-shared-worker-cache")
    report = []
    for slot in range(2):
        file = base.with_name(base.stem + f".worker-{slot}" + base.suffix)
        require(file.is_file(), "worker-cache-missing")
        with sqlite3.connect(f"file:{file}?mode=ro", uri=True, timeout=2) as db:
            count = db.execute("SELECT COUNT(*) FROM analysis_cache_v2").fetchone()[0]
            require(count <= 64, "unexpected-concurrent-cache-volume")
            rows = db.execute("SELECT content_hash,response_json,decision_json FROM analysis_cache_v2").fetchall()
        fixture_hashes = {FIXTURES[key]["sha"] for key in ("allow", "block")}
        matching = {row[0] for row in rows} & fixture_hashes
        for _, response, decision in rows:
            require(not private_fields(json.loads(response)) and not private_fields(json.loads(decision)), "private-cache-fields")
        if expect_fixture_entries is not None:
            require(len(matching) == expect_fixture_entries, "worker-public-source-cache-identity-mismatch")
        report.append({"slot": slot, "filename": file.name, "entries": count,
                       "public_fixture_hashes": sorted(matching), "private_fields_present": False})
    return report


def diagnostic_snapshot(config):
    root = Path(config["diagnostics"]["directory"])
    result = []
    for slot in range(2):
        directory = root / f"worker-{slot}"
        events_path = directory / "image-filter-events.jsonl"
        require(events_path.stat().st_size <= 5_000_000, "diagnostic-byte-limit")
        events = [json.loads(line) for line in events_path.read_text().splitlines()]
        require(not private_fields(events), "private-diagnostic-fields")
        summary = json.loads((directory / "image-filter-summary.json").read_text())
        result.append({"slot": slot, "events": len(events), "cache_hits": summary["cacheHits"],
                       "inspected": summary["totalInspected"], "private_fields_present": False})
    require(not any(p.suffix.lower() in {".jpg", ".jpeg", ".png", ".webp", ".gif", ".svg"}
                    for base in (root, Path(config["cache"]["sqlite_path"]).parent)
                    for p in base.rglob("*")), "unexpected-image-spool-file")
    return result


def execute(args, report):
    deadline = time.monotonic() + 180
    manifest_path = RELEASE / MANIFEST
    require(sha(manifest_path.read_bytes()) == MANIFEST_SHA, "manifest-mismatch")
    manifest = json.loads(manifest_path.read_text())
    require(all(sha((RELEASE / name).read_bytes()) == digest for name, digest in manifest["files"].items()), "runtime-file-mismatch")
    require(sha((RELEASE / "production.toml").read_bytes()) == CONFIG_SHA, "config-mismatch")
    require(sha(CA.read_bytes()) == CA_SHA, "production-ca-mismatch")
    config = tomllib.loads((RELEASE / "production.toml").read_text())
    require(config["cache"]["enabled"] and config["runtime"]["process_workers"] == 2, "cache-worker-config-mismatch")
    require(all(config["diagnostics"][key] is False for key in ("store_urls", "store_image_bytes", "store_crops")), "diagnostic-privacy-config")
    identity = parent_identity(args.expected_pid)
    report["identity_before"] = identity
    report["startup_guard"] = startup_guard(args.expected_pid, identity, deadline)
    transport_path = Path(config["diagnostics"]["directory"]) / "transport-path-diagnostics.json"
    before = json.loads(transport_path.read_text())
    require(before["pid"] == args.expected_pid and before["epoch_id"] and before["lifecycle"] == "running", "transport-epoch-before")
    report["transport_before"] = before
    report["cache_before"] = cache_snapshot(config, expect_fixture_entries=0)
    require(all(row["entries"] == 0 for row in report["cache_before"]), "production-cache-not-fresh")
    context = ssl.create_default_context()
    context.load_verify_locations(cafile=str(CA))
    require(context.check_hostname and context.verify_mode == ssl.CERT_REQUIRED, "tls-verification-disabled")
    report["tls"] = {"hostname_verified": True, "certificate_verified": True, "ca_sha256": CA_SHA}
    for index, name in enumerate(SEQUENCE):
        require(parent_identity(args.expected_pid) == identity, "parent-changed-during-smoke")
        row = {"fixture": name, "expected_public_source_sha256": FIXTURES[name]["sha"], "passed": False}
        report["requests"].append(row)
        row.update(request_fixture(name, context, "hit" if 4 <= index < 8 else "miss", deadline, row))
        if index == 7:
            report["cache_after_jpegs"] = cache_snapshot(config, expect_fixture_entries=2)
            require(all(row["entries"] == 2 for row in report["cache_after_jpegs"]), "unexpected-cache-cohort")
    report["cache_after"] = cache_snapshot(config, expect_fixture_entries=2)
    report["diagnostics"] = diagnostic_snapshot(config)
    require(all(row["cache_hits"] == 2 for row in report["diagnostics"]), "worker-cache-hit-count-mismatch")
    require(sum(row["inspected"] for row in report["diagnostics"]) == 5, "worker-inference-count-mismatch")
    # The companion flushes on events, not a periodic timer. Its final counters
    # may lag the ninth response; do not generate extra traffic to flush them.
    after = json.loads(transport_path.read_text())
    report["transport_after"] = after
    require(after["pid"] == before["pid"] and after["epoch_id"] == before["epoch_id"], "transport-epoch-changed")
    delta = after.get("counts", {}).get("http_response:2xx", 0) - before.get("counts", {}).get("http_response:2xx", 0)
    report["transport_persisted_2xx_delta"] = delta
    report["transport_counts_can_lag_final_events"] = True
    require(delta > 0, "transport-response-delta-missing")
    require(parent_identity(args.expected_pid) == identity and listener_owned(args.expected_pid), "parent-listener-changed")
    final_workers = workers(args.expected_pid)
    report["workers_after"] = final_workers
    require([(w["pid"], w["slot"]) for w in final_workers] ==
            [(w["pid"], w["slot"]) for w in report["startup_guard"]["workers"]], "worker-restarted-during-smoke")
    report["passed"] = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--expected-pid", type=int)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    if not args.execute:
        print(json.dumps({"prepared_only": True, "network_requests": 0, "planned_sequence": SEQUENCE,
                          "startup_max_seconds": 60, "request_max_seconds": 30, "overall_max_seconds": 180}))
        return
    require(args.expected_pid and args.report and not args.report.exists(), "new-report-and-explicit-pid-required")
    report = {"schema": 1, "started_utc": datetime.now(timezone.utc).isoformat(), "passed": False,
              "manifest_sha256": MANIFEST_SHA, "config_sha256": CONFIG_SHA, "requests": [],
              "scope": "Same-process loopback HTTPS production smoke; not client WireGuard or whole-page acceptance",
              "request_retries": 0, "raw_image_persistence": False, "source_manifest_sha256":
              "592dd80686141d54da26dd84eb66d2e60a5dbadc3f3da75733283026a443182b"}
    try:
        sampler = ResourceSampler(args.expected_pid)
        sampler.thread.start()
        with absolute_timeout(180):
            execute(args, report)
    except Exception as error:
        report["failure"] = str(error) if isinstance(error, SmokeFailure) else type(error).__name__
    finally:
        if "sampler" in locals():
            report["resources"] = sampler.finish()
        report["finished_utc"] = datetime.now(timezone.utc).isoformat()
        args.report.parent.mkdir(parents=True, exist_ok=True)
        with args.report.open("x") as stream:
            json.dump(report, stream, indent=2, sort_keys=True)
            stream.write("\n")
        args.report.chmod(0o600)
    print(json.dumps({"passed": report["passed"], "completed_requests": len(report["requests"]),
                      "failure": report.get("failure"), "report": str(args.report)}))
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
