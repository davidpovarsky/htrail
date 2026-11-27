#!/usr/bin/env python3
"""Real-socket mitmproxy boundary checks; no model-accuracy claims or services."""
from __future__ import annotations
import asyncio
import gzip
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import ssl
import sys
import tempfile
import time
from datetime import datetime, timezone, timedelta
import zlib
import brotli
from contextlib import contextmanager

HERE = Path(__file__).resolve().parent
MAXIMUM = 4_194_304
DEADLINE = 0.8
MARKER = b"PURELINE-UNINSPECTED-ORIGIN-BYTES"
SVG = b'<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"><rect width="4" height="4" fill="navy"/></svg>'
GIF = bytes.fromhex("47494638396101000100800000000000ffffff21f90401000000002c00000000010001000002024401003b")


@contextmanager
def traced_work():
    with tempfile.TemporaryDirectory(prefix="pureline-network-bounds-") as directory:
        try:
            yield directory
        except BaseException:
            for path in Path(directory).glob("*.log"):
                print(path.name + "\n" + path.read_text(errors="replace")[-12_000:], flush=True)
            raise


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


async def read_response(reader):
    raw = await reader.readuntil(b"\r\n\r\n")
    lines = raw.decode("latin1").split("\r\n")
    headers = dict(line.split(":", 1) for line in lines[1:] if ":" in line)
    headers = {key.lower(): value.strip() for key, value in headers.items()}
    if headers.get("transfer-encoding", "").lower() == "chunked":
        chunks = []
        while True:
            size = int((await reader.readline()).split(b";", 1)[0], 16)
            if not size:
                while await reader.readline() != b"\r\n":
                    pass
                break
            chunks.append(await reader.readexactly(size))
            assert await reader.readexactly(2) == b"\r\n"
        body = b"".join(chunks)
    elif "content-length" in headers:
        body = await reader.readexactly(int(headers["content-length"]))
    else:
        body = await reader.read()
    return int(lines[0].split()[1]), headers, body


async def main():
    rows = []
    hold_release = asyncio.Event()
    origin_writers = set()
    origin_tasks = set()
    tls_server = None
    origin_state = {"stalled_connection_aborted": False}
    compressed = {
        "/gzip-svg": (gzip.compress(SVG, mtime=0), "image/svg+xml", "gzip"),
        "/brotli-gif": (brotli.compress(GIF), "image/gif", "br"),
        "/brotli-large-svg": (brotli.compress(SVG[:-6] + b"<!--" + b"A" * 300_000 + b"-->" + SVG[-6:]), "image/svg+xml", "br"),
        "/deflate-gif": (zlib.compress(GIF), "image/gif", "deflate"),
        "/gzip-bomb": (gzip.compress(b"A" * (MAXIMUM + 100), mtime=0), "image/png", "gzip"),
        "/brotli-bomb": (brotli.compress(b"A" * (MAXIMUM + 100)), "image/png", "br"),
        "/malformed-gzip": (b"\x1f\x8bBROKEN", "image/png", "gzip"),
    }

    async def origin(reader, writer):
        task = asyncio.current_task()
        origin_tasks.add(task)
        origin_writers.add(writer)
        try:
            request = await reader.readuntil(b"\r\n\r\n")
            lines = request.decode("latin1").split("\r\n")
            method, path, _ = lines[0].split(" ")
            fields = {k.lower(): v.strip() for line in lines[1:] if ":" in line
                      for k, v in [line.split(":", 1)]}
            async def head(mime, *, size=None, encoding=None, chunked=False):
                value = f"HTTP/1.1 200 OK\r\nContent-Type: {mime}\r\nConnection: close\r\n"
                if size is not None:
                    value += f"Content-Length: {size}\r\n"
                if encoding:
                    value += f"Content-Encoding: {encoding}\r\n"
                if chunked:
                    value += "Transfer-Encoding: chunked\r\n"
                writer.write((value + "\r\n").encode())
                await writer.drain()
            async def chunk(body):
                writer.write(f"{len(body):x}\r\n".encode() + body + b"\r\n")
                await writer.drain()
            if path == "/large-upload":
                size = int(fields["content-length"])
                digest = hashlib.sha256()
                while size:
                    part = await reader.readexactly(min(size, 65_536))
                    digest.update(part); size -= len(part)
                result = digest.hexdigest().encode()
                await head("text/plain", size=len(result)); writer.write(result)
            elif path == "/large-html":
                result = b"H" * (MAXIMUM * 2 + 17)
                await head("text/html", size=len(result)); writer.write(result)
            elif path == "/sse":
                await head("text/event-stream", chunked=True)
                await chunk(b"data: first\n\n")
                await asyncio.sleep(DEADLINE * 2)
                await chunk(b"data: second\n\n"); writer.write(b"0\r\n\r\n")
            elif path in compressed:
                body, mime, encoding = compressed[path]
                await head(mime, size=len(body), encoding=encoding); writer.write(body)
            elif path == "/oversize-known":
                await head("image/png", size=MAXIMUM + 1)
                writer.write(MARKER)
            elif path in {"/oversize-chunked", "/ambiguous-chunked"}:
                await head("image/png" if path == "/oversize-chunked" else "application/octet-stream", chunked=True)
                part = MARKER + b"X" * (65_536 - len(MARKER))
                for _ in range(MAXIMUM // len(part) + 1):
                    await chunk(part)
                writer.write(b"0\r\n\r\n")
            elif path == "/stalled-image":
                await head("image/gif", size=len(GIF))
                writer.write(GIF[:6]); await writer.drain()
                try:
                    origin_state["stalled_connection_aborted"] = await asyncio.wait_for(reader.read(1), DEADLINE * 2) == b""
                except asyncio.TimeoutError:
                    writer.write(GIF[6:])
            elif path == "/large-allowed-image":
                body = GIF + b"X" * (3 * 1024 * 1024)
                await head("image/gif", size=len(body)); writer.write(body)
            elif path.startswith("/hold"):
                await head("image/png", chunked=True)
                await chunk(MARKER)
                await hold_release.wait()
                writer.write(b"0\r\n\r\n")
            elif path == "/body-then-worker-timeout":
                body = b"sleep:0.6"
                await head("image/png", size=len(body))
                await asyncio.sleep(0.5)
                writer.write(body)
            elif path == "/disconnect-worker":
                body = b"sleep:3"
                await head("image/png", size=len(body)); writer.write(body)
            else:
                await head("image/gif", size=len(GIF)); writer.write(GIF)
            await writer.drain()
        except (ConnectionError, asyncio.IncompleteReadError, BrokenPipeError, asyncio.CancelledError):
            pass
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except ConnectionError:
                pass
            origin_writers.discard(writer); origin_tasks.discard(task)

    server = await asyncio.start_server(origin, "127.0.0.1", 0)
    origin_port = server.sockets[0].getsockname()[1]
    proxy_port = free_port()

    async def connect(path, *, body=b"", method="GET"):
        reader, writer = await asyncio.open_connection("127.0.0.1", proxy_port)
        headers = (f"{method} http://127.0.0.1:{origin_port}{path} HTTP/1.1\r\n"
                   f"Host: 127.0.0.1:{origin_port}\r\nConnection: close\r\n")
        if body:
            headers += f"Content-Length: {len(body)}\r\nContent-Type: application/octet-stream\r\n"
        writer.write((headers + "\r\n").encode() + body)
        await writer.drain()
        return reader, writer

    async def fetch(path, **options):
        writer = None
        began = time.monotonic()
        try:
            async with asyncio.timeout(8):
                reader, writer = await connect(path, **options)
                status, headers, body = await read_response(reader)
                return status, headers, body, time.monotonic() - began
        except (ConnectionError, asyncio.IncompleteReadError):
            return 0, {}, b"", time.monotonic() - began
        finally:
            if writer:
                writer.close()
                try:
                    await writer.wait_closed()
                except ConnectionError:
                    pass

    async def metrics():
        status, _, body, _ = await fetch("/__pureline_boundary_metrics")
        assert status == 200
        return json.loads(body)

    def record(name, passed, **extra):
        rows.append({"id": name, "passed": bool(passed), **extra})
        assert passed, rows[-1]
        print(json.dumps(rows[-1]), flush=True)

    processes = []
    logs = []
    try:
        with traced_work() as directory:
            work = Path(directory)
            from cryptography import x509
            from cryptography.hazmat.primitives import hashes, serialization
            from cryptography.hazmat.primitives.asymmetric import rsa
            from cryptography.x509.oid import NameOID
            import ipaddress
            key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
            name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Pureline isolated test origin")])
            certificate = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
                           .public_key(key.public_key()).serial_number(x509.random_serial_number())
                           .not_valid_before(datetime.now(timezone.utc) - timedelta(minutes=1))
                           .not_valid_after(datetime.now(timezone.utc) + timedelta(hours=1))
                           .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
                           .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]), critical=False)
                           .sign(key, hashes.SHA256()))
            key_path, cert_path = work / "origin-key.pem", work / "origin-ca.pem"
            key_path.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                                   serialization.NoEncryption())); key_path.chmod(0o600)
            cert_path.write_bytes(certificate.public_bytes(serialization.Encoding.PEM))
            tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            tls_context.load_cert_chain(cert_path, key_path)
            tls_server = await asyncio.start_server(origin, "127.0.0.1", 0, ssl=tls_context)
            tls_port = tls_server.sockets[0].getsockname()[1]
            config = (HERE / "candidate.toml").read_text().replace(
                "request_timeout_seconds = 18", f"request_timeout_seconds = {DEADLINE}").replace(
                'ignore_hosts = ["localhost","127.0.0.1","::1"]', "ignore_hosts = []")
            (work / "candidate.toml").write_text(config)
            command = [str(Path(sys.executable).with_name("mitmdump")), "-q", "--listen-host", "127.0.0.1",
                       "--listen-port", str(proxy_port), "--set", "connection_strategy=lazy",
                       "--set", "flow_detail=0", "--set", "confdir=" + str(work / "confdir"),
                       "--set", "ssl_verify_upstream_trusted_ca=" + str(cert_path),
                       "--set", "local_image_filter_config=" + str(work / "candidate.toml"),
                       "-s", str(HERE / "tests/boundary_addon.py")]
            environment = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", PURELINE_TEST_START_DELAY="0.6")
            log = (work / "proxy.log").open("wb"); logs.append(log)
            process = await asyncio.create_subprocess_exec(*command, stdout=log, stderr=log,
                                                           env=environment, start_new_session=True)
            processes.append(process)
            began = time.monotonic()
            while True:
                assert process.returncode is None, (work / "proxy.log").read_text()
                try:
                    reader, writer = await connect("/image")
                    break
                except ConnectionRefusedError:
                    assert time.monotonic() - began < 8
                    await asyncio.sleep(0.02)
            try:
                status, headers, body = await asyncio.wait_for(read_response(reader), 2)
            except (ConnectionError, asyncio.IncompleteReadError):
                status, headers, body = 0, {}, b""
            writer.close()
            record("image-during-warmup-refused", body != GIF and status != 200, status=status)
            while not (await metrics())["ready"]:
                await asyncio.sleep(0.02)

            for path in ("/gzip-svg", "/brotli-gif", "/brotli-large-svg", "/deflate-gif"):
                status, headers, body, elapsed = await fetch(path)
                expected = compressed[path][0]
                record(path[1:] + "-allow-unchanged", status == 200 and body == expected and
                       headers.get("x-local-image-filter") == "allow", elapsed_ms=round(elapsed * 1000))

            for path in ("/oversize-known", "/oversize-chunked", "/ambiguous-chunked"):
                status, _, body, elapsed = await fetch(path)
                record(path[1:] + "-refused-before-origin-bytes", status != 200 and MARKER not in body,
                       status=status, elapsed_ms=round(elapsed * 1000))

            for path in ("/gzip-bomb", "/brotli-bomb", "/malformed-gzip"):
                status, headers, body, elapsed = await fetch(path)
                record(path[1:] + "-safe-replacement", status == 200 and
                       headers.get("x-local-image-filter") == "replace" and
                       "content-encoding" not in headers and len(body) < 100_000 and
                       headers.get("x-local-image-filter-reason") == ("image-decode-error" if path == "/malformed-gzip" else "image-decoded-too-large"),
                       reason=headers.get("x-local-image-filter-reason"), elapsed_ms=round(elapsed * 1000))

            status, _, body, elapsed = await fetch("/stalled-image")
            await asyncio.sleep(0.02)
            record("silent-body-deadline", status != 200 and GIF[:6] not in body and elapsed < 1.5,
                   status=status, elapsed_ms=round(elapsed * 1000), origin_connection_aborted=origin_state["stalled_connection_aborted"])
            assert origin_state["stalled_connection_aborted"]
            status, headers, _, elapsed = await fetch("/body-then-worker-timeout")
            record("body-and-worker-share-deadline", headers.get("x-local-image-filter-reason") == "inspection-timeout"
                   and elapsed < 1.5, elapsed_ms=round(elapsed * 1000))

            held = [await connect("/hold") for _ in range(10)]
            async with asyncio.timeout(0.5):
                while (await metrics())["reserved"] < 10:
                    await asyncio.sleep(0.01)
            status, _, body, elapsed = await fetch("/hold-overflow")
            record("header-admission-bounded", status != 200 and MARKER not in body and elapsed < 0.5,
                   status=status, peak_reserved=(await metrics())["peak_reserved"])
            for _, writer in held:
                writer.close()
            async with asyncio.timeout(0.5):
                while (await metrics())["reserved"]:
                    await asyncio.sleep(0.01)
            record("body-disconnect-releases-reservations", (await metrics())["reserved"] == 0)
            hold_release.set()

            reader, writer = await connect("/disconnect-worker")
            async with asyncio.timeout(0.5):
                while not (await metrics())["pool"].get("active"):
                    await asyncio.sleep(0.01)
            worker_pids = (await metrics())["workers"]
            writer.close()
            async with asyncio.timeout(1.5):
                while (await metrics())["pool"].get("active"):
                    await asyncio.sleep(0.01)
            record("inspection-disconnect-kills-worker", any(not Path(f"/proc/{pid}").exists() for pid in worker_pids)
                   and (await metrics())["reserved"] == 0)

            large = b"U" * (MAXIMUM * 2 + 17)
            status, _, body, elapsed = await fetch("/large-upload", method="POST", body=large)
            upload_metrics = await metrics()
            record("large-upload-streamed-and-preserved", status == 200 and body.decode() == hashlib.sha256(large).hexdigest()
                   and upload_metrics["upload_streamed"] and upload_metrics["upload_buffered_bytes"] == 0,
                   bytes=len(large), parent_body_buffer_bytes=upload_metrics["upload_buffered_bytes"], elapsed_ms=round(elapsed * 1000))
            status, _, body, elapsed = await fetch("/large-html")
            record("large-nonimage-preserved", status == 200 and body == b"H" * len(large),
                   bytes=len(body), elapsed_ms=round(elapsed * 1000))
            began = time.monotonic(); reader, writer = await connect("/sse")
            prefix = await asyncio.wait_for(reader.readuntil(b"data: first\n\n"), 0.5)
            elapsed = time.monotonic() - began; writer.close()
            record("sse-first-event-streams", b"text/event-stream" in prefix and elapsed < 0.5,
                   first_event_ms=round(elapsed * 1000))

            async def fetch_https(path):
                reader, writer = await asyncio.open_connection("127.0.0.1", proxy_port)
                writer.write((f"CONNECT 127.0.0.1:{tls_port} HTTP/1.1\r\nHost: 127.0.0.1:{tls_port}\r\n\r\n").encode())
                await writer.drain()
                connect_head = await reader.readuntil(b"\r\n\r\n")
                assert connect_head.startswith(b"HTTP/1.1 200")
                trust = ssl.create_default_context(cafile=str(work / "confdir/mitmproxy-ca-cert.pem"))
                await writer.start_tls(trust, server_hostname="127.0.0.1")
                began = time.monotonic()
                writer.write((f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{tls_port}\r\nConnection: close\r\n\r\n").encode())
                await writer.drain()
                try:
                    status, headers, body = await asyncio.wait_for(read_response(reader), 3)
                    return status, headers, body, time.monotonic() - began
                finally:
                    writer.close()
                    try:
                        await writer.wait_closed()
                    except ConnectionError:
                        pass

            status, headers, body, elapsed = await fetch_https("/image")
            record("https-connect-allow-unchanged", status == 200 and body == GIF and
                   headers.get("x-local-image-filter") == "allow", scoped_ca_verification=True,
                   elapsed_ms=round(elapsed * 1000))
            retained_https = await metrics()
            record("https-completion-weak-routing", retained_https["finished_image_bytes_retained"] == 0 and
                   retained_https["strong_image_wakeup_routes"] == 0,
                   retained_bytes=retained_https["finished_image_bytes_retained"])
            origin_state["stalled_connection_aborted"] = False
            status, _, body, elapsed = await fetch_https("/stalled-image")
            await asyncio.sleep(0.02)
            record("https-connect-silent-body-deadline", status != 200 and GIF[:6] not in body and elapsed < 1.5 and
                   origin_state["stalled_connection_aborted"], status=status, elapsed_ms=round(elapsed * 1000),
                   origin_connection_aborted=origin_state["stalled_connection_aborted"])

            status, headers, body, elapsed = await fetch("/large-allowed-image")
            retained = await metrics()
            record("completed-image-not-retained-by-wakeup", status == 200 and body == GIF + b"X" * (3 * 1024 * 1024)
                   and retained["finished_image_bytes_retained"] == 0 and retained["strong_image_wakeup_routes"] == 0,
                   retained_bytes=retained["finished_image_bytes_retained"], strong_wakeup_routes=retained["strong_image_wakeup_routes"],
                   measured_before_deadline=elapsed < DEADLINE)

            # A finished body must not be kept alive or aborted by its old wakeup.
            await asyncio.sleep(DEADLINE + 0.2)
            status, headers, body, _ = await fetch("/image")
            final_metrics = await metrics()
            record("completion-and-late-wakeup-safe", status == 200 and body == GIF and
                   headers.get("x-local-image-filter") == "allow" and final_metrics["reserved"] == 0)
            record("raw-buffer-ceiling", final_metrics["peak_buffer_bytes"] <= MAXIMUM and
                   final_metrics["peak_reserved"] <= 10, metrics=final_metrics)
            os.killpg(process.pid, signal.SIGTERM)
            await asyncio.wait_for(process.wait(), 5)

            # Incorrect expected pin is injected only in this test addon; no
            # installed vendor file or candidate runtime is modified.
            bad_log = (work / "bad-pin.log").open("wb"); logs.append(bad_log)
            bad_environment = dict(environment, PURELINE_TEST_BAD_PIN="1")
            bad = await asyncio.create_subprocess_exec(*command, stdout=bad_log, stderr=bad_log,
                                                       env=bad_environment, start_new_session=True)
            processes.append(bad)
            leaked = False
            async with asyncio.timeout(8):
                while bad.returncode is None:
                    try:
                        status, _, body, _ = await fetch("/image")
                        leaked |= status == 200 and body == GIF
                    except ConnectionRefusedError:
                        pass
                    await asyncio.sleep(0.02)
            record("unverified-source-startup-fatal", bad.returncode != 0 and not leaked,
                   returncode=bad.returncode)
            report = {"schema": 1, "created_utc": datetime.now(timezone.utc).isoformat(),
                      "passed": all(row["passed"] for row in rows), "cases": len(rows),
                      "actual_mitmproxy": True, "real_loopback_sockets": True, "actual_models": False,
                      "accuracy_samples_added": 0, "test_deadline_seconds": DEADLINE,
                      "runtime_default_deadline_seconds": 18, "raw_body_limit_bytes": MAXIMUM,
                      "rows": rows, "source_sha256": {str(p.relative_to(HERE)): hashlib.sha256(p.read_bytes()).hexdigest()
                                                       for p in sorted((HERE / "downstream").glob("*.py"))}}
            (HERE / "evidence/http-network-bounds.json").write_text(json.dumps(report, indent=2) + "\n")
            print(json.dumps({key: value for key, value in report.items() if key not in {"rows", "source_sha256"}}))
    finally:
        for process in processes:
            if process.returncode is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                await process.wait()
        for log in logs:
            log.close()
        server.close(); await server.wait_closed()
        if tls_server is not None:
            tls_server.close(); await tls_server.wait_closed()
        for writer in tuple(origin_writers):
            writer.close()
        for task in tuple(origin_tasks):
            task.cancel()
        await asyncio.gather(*tuple(origin_tasks), return_exceptions=True)


if __name__ == "__main__":
    asyncio.run(main())
