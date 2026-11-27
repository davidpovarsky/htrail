#!/usr/bin/env python3
"""Real child-process/cancellation/load tests with a deterministic worker fixture."""
import asyncio
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import time
from datetime import datetime, timezone
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from downstream.process_pool import (BoundedProcessPool, QueueCapacityExceeded,
                                     InspectionTimeout, InspectionFailure)

COMMAND = [sys.executable, str(HERE / "tests/fake_pipeline_worker.py")]
rows = []


def running(pid):
    try:
        os.kill(pid, 0)
        # A zombie is terminated; its final OS reap can belong to PID1.
        status = Path(f"/proc/{pid}/stat")
        return not status.exists() or status.read_text().split(") ", 1)[1][0] != "Z"
    except (FileNotFoundError, ProcessLookupError):
        return False


async def wait_active(pool):
    for _ in range(100):
        if pool.metrics["active"]:
            return
        await asyncio.sleep(0.005)
    raise AssertionError("worker never became active")


async def main():
    pool = BoundedProcessPool(COMMAND, workers=2, queued=8, timeout=3)
    await pool.warm_up(timeout=5)
    latencies = []
    async def one():
        started = time.monotonic()
        try:
            await pool.inspect(b"sleep:0.02", "image/png")
            return "allow"
        except QueueCapacityExceeded:
            return "capacity"
        finally:
            latencies.append(time.monotonic() - started)
    results = await asyncio.gather(*(one() for _ in range(100)))
    assert results.count("allow") == 10 and results.count("capacity") == 90
    assert pool.metrics["peak_active"] == 2 and pool.metrics["peak_admitted"] == 10
    rows.append({"id": "100-image-burst", "completed": 10, "bounded_rejections": 90,
                 "maximum_latency_ms": round(max(latencies)*1000), "metrics": dict(pool.metrics)})
    gate = asyncio.Semaphore(10)
    async def sustained():
        async with gate:
            return await pool.inspect(b"sleep:0.01", "image/png")
    started = time.monotonic()
    answers = await asyncio.gather(*(sustained() for _ in range(100)))
    assert len(answers) == 100 and pool.admitted == 0
    rows.append({"id": "100-image-bounded-sustained", "completed": len(answers),
                 "elapsed_ms": round((time.monotonic()-started)*1000),
                 "peak_active": pool.metrics["peak_active"]})
    pids = [worker.process.pid for worker in pool.workers]
    await pool.close()
    assert all(not running(pid) for pid in pids)
    rows.append({"id": "shutdown-reaps-workers", "terminated": len(pids)})

    pool = BoundedProcessPool(COMMAND, workers=1, queued=1, timeout=0.25)
    await pool.warm_up(timeout=5)
    old_pid = pool.workers[0].process.pid
    started = time.monotonic()
    try:
        await pool.inspect(b"sleep:30", "image/png")
        raise AssertionError("deadline not enforced")
    except InspectionTimeout:
        pass
    elapsed = time.monotonic()-started
    assert elapsed < 1.5 and not running(old_pid)
    result = await pool.inspect(b"recovered", "image/png")
    assert result["pid"] != old_pid
    rows.append({"id": "deadline-kills-and-recovers", "elapsed_ms": round(elapsed*1000),
                 "old_pid_terminated": True, "new_pid": result["pid"]})
    await pool.close()

    pool = BoundedProcessPool(COMMAND, workers=1, queued=1, timeout=0.2)
    await pool.warm_up(timeout=5)
    first = asyncio.create_task(pool.inspect(b"sleep:30", "image/png"))
    await wait_active(pool)
    started = time.monotonic()
    second = asyncio.create_task(pool.inspect(b"queued", "image/png"))
    results = await asyncio.gather(first, second, return_exceptions=True)
    assert all(isinstance(value, InspectionTimeout) for value in results)
    assert time.monotonic()-started < 1.5 and pool.admitted == 0
    rows.append({"id": "queue-time-counts-in-deadline", "timed_out": 2})
    await pool.close()

    temporary = tempfile.TemporaryDirectory(prefix="pureline-process-test-")
    child_report = Path(temporary.name)/"child.json"
    pool = BoundedProcessPool(COMMAND+[str(child_report)], workers=1, queued=1, timeout=2)
    await pool.warm_up(timeout=5)
    old_pid = pool.workers[0].process.pid
    task = asyncio.create_task(pool.inspect(b"spawn-sleep", "image/png"))
    await wait_active(pool)
    child_pids = []
    for _ in range(100):
        child_pids = [json.loads(child_report.read_text())["child"]] if child_report.exists() else []
        if child_pids:
            break
        await asyncio.sleep(0.005)
    assert child_pids, "descendant fixture was not created"
    task.cancel()
    result = await asyncio.gather(task, return_exceptions=True)
    assert isinstance(result[0], asyncio.CancelledError)
    assert not running(old_pid) and all(not running(pid) for pid in child_pids)
    recovered = await pool.inspect(b"post-cancel", "image/png")
    assert recovered["pid"] != old_pid
    rows.append({"id": "cancel-kills-worker-and-descendants", "descendants": len(child_pids),
                 "old_pid_terminated": True, "recovered": True})
    await pool.close()
    temporary.cleanup()

    pool = BoundedProcessPool(COMMAND, workers=1, queued=1, timeout=2)
    await pool.warm_up(timeout=5)
    old_pid = pool.workers[0].process.pid
    first = asyncio.create_task(pool.inspect(b"sleep:0.15", "image/png"))
    await wait_active(pool)
    waiting = asyncio.create_task(pool.inspect(b"queued", "image/png"))
    await asyncio.sleep(0.01)
    waiting.cancel()
    cancelled, first_result = await asyncio.gather(waiting, first, return_exceptions=True)
    assert isinstance(cancelled, asyncio.CancelledError) and first_result["pid"] == old_pid
    assert pool.admitted == 0
    rows.append({"id": "cancel-queued-preserves-other-client", "active_worker_preserved": True})
    await pool.close()

    for fixture in [b"crash", b"invalid-message"]:
        pool = BoundedProcessPool(COMMAND, workers=1, queued=0, timeout=2)
        await pool.warm_up(timeout=5)
        old_pid = pool.workers[0].process.pid
        try:
            await pool.inspect(fixture, "image/png")
            raise AssertionError("invalid worker response accepted")
        except InspectionFailure:
            pass
        assert not running(old_pid)
        result = await pool.inspect(b"recover", "image/png")
        assert result["pid"] != old_pid
        rows.append({"id": fixture.decode()+"-recovery", "recovered": True})
        await pool.close()

    os.environ["PURELINE_TEST_START_DELAY"] = "30"
    pool = BoundedProcessPool(COMMAND, workers=2, queued=0, timeout=2)
    try:
        await pool.warm_up(timeout=0.1)
        raise AssertionError("startup timeout not enforced")
    except asyncio.TimeoutError:
        pass
    finally:
        del os.environ["PURELINE_TEST_START_DELAY"]
    assert pool.closed and all(worker.process is None for worker in pool.workers)
    rows.append({"id": "startup-timeout-reaps-every-worker", "terminated": 2})

    pool = BoundedProcessPool(COMMAND, workers=1, queued=0, timeout=2)
    task = asyncio.create_task(pool.inspect(b"first", "image/png"))
    await asyncio.sleep(0)
    task.cancel()
    result = await asyncio.gather(task, return_exceptions=True)
    assert isinstance(result[0], asyncio.CancelledError)
    assert pool.admitted == 0 and pool.workers[0].process is None
    rows.append({"id": "cancel-during-spawn-retains-ownership", "reaped": True})
    await pool.close()

    pool = BoundedProcessPool(COMMAND, workers=1, queued=1, timeout=2)
    await pool.warm_up(timeout=5)
    old_pid = pool.workers[0].process.pid
    began = time.monotonic()
    try:
        await pool.inspect(b"sleep:30", "image/png", timeout=0.1)
        raise AssertionError("remaining header budget was ignored")
    except InspectionTimeout:
        pass
    assert time.monotonic() - began < 1 and not running(old_pid)
    before = pool.workers[0].spawn_count
    try:
        await pool.inspect(b"expired", "image/png", timeout=0)
        raise AssertionError("expired header budget admitted work")
    except InspectionTimeout:
        pass
    assert pool.workers[0].spawn_count == before and pool.admitted == 0
    recovered = await pool.inspect(b"recovered", "image/png")
    assert recovered["pid"] != old_pid
    rows.append({"id": "remaining-header-budget-enforced", "expired_budget_spawns": 0,
                 "worker_killed_and_recovered": True})
    await pool.close()

    report = {"schema": 1, "created_utc": datetime.now(timezone.utc).isoformat(),
              "passed": True, "cases": len(rows), "real_processes": True,
              "actual_models": False, "accuracy_samples_added": 0,
              "source_sha256": hashlib.sha256((HERE/"downstream/process_pool.py").read_bytes()).hexdigest(),
              "rows": rows}
    (HERE/"evidence").mkdir(exist_ok=True)
    (HERE/"evidence/process-bounds-v6-regression.json").write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps(report))


if __name__ == "__main__":
    asyncio.run(main())
