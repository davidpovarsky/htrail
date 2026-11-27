"""Bounded Linux model workers with queue-inclusive deadlines and hard cancel."""
from __future__ import annotations
import asyncio
import base64
import os
import signal
from collections import Counter

from downstream.worker_protocol import encode_message, read_async_message


class InspectionFailure(RuntimeError):
    reason = "worker-failure"


class InspectionTimeout(InspectionFailure):
    reason = "inspection-timeout"


class QueueCapacityExceeded(InspectionFailure):
    reason = "inspection-queue-full"


class _Worker:
    def __init__(self, command, slot):
        self.command = command
        self.slot = slot
        self.process = None
        self.poisoned = False
        self.spawn_count = 0
        self.ready_info = None

    async def start(self):
        if self.process is not None:
            if self.poisoned:
                # Never exceed the slot's process limit while an old process is
                # still awaiting termination (for example, uninterruptible I/O).
                await self.process.wait()
                self.process = None
            elif self.process.returncode is None:
                return
        environment = os.environ.copy()
        environment.update(OPENBLAS_NUM_THREADS="1", OMP_NUM_THREADS="1",
                           PYTHONDONTWRITEBYTECODE="1", PURELINE_WORKER_SLOT=str(self.slot))
        spawning = asyncio.create_task(asyncio.create_subprocess_exec(
            *self.command, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL, start_new_session=True, env=environment,
        ))
        try:
            self.process = await asyncio.shield(spawning)
        except asyncio.CancelledError:
            # Retain ownership even if cancellation races process creation.
            self.process = await spawning
            self.kill_now()
            raise
        self.poisoned = False
        self.spawn_count += 1
        message = await read_async_message(self.process.stdout)
        if not message.get("ready"):
            raise InspectionFailure("worker-not-ready")
        self.ready_info = message

    async def exchange(self, request):
        await self.start()
        self.process.stdin.write(encode_message(request))
        await self.process.stdin.drain()
        result = await read_async_message(self.process.stdout)
        if not result.get("ok"):
            raise InspectionFailure("worker-pipeline-failure")
        return result["outcome"]

    def kill_now(self):
        if self.process is not None and self.process.returncode is None:
            self.poisoned = True
            try:
                # SVG renderer subprocesses share this private process group.
                os.killpg(self.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    async def stop(self):
        self.kill_now()
        if self.process is not None:
            try:
                await asyncio.wait_for(self.process.wait(), timeout=1.0)
            except asyncio.TimeoutError:
                # Keep it attached to the slot; start() will wait before reuse.
                return
            self.process = None
            self.poisoned = False


class BoundedProcessPool:
    def __init__(self, command, *, workers=2, queued=8, timeout=18.0):
        if workers < 1 or queued < 0 or not 0 < timeout <= 120:
            raise ValueError("invalid-worker-pool-bounds")
        self.workers = [_Worker(tuple(command), slot) for slot in range(workers)]
        self.available = asyncio.Queue(maxsize=workers)
        for worker in self.workers:
            self.available.put_nowait(worker)
        self.capacity = workers + queued
        self.timeout = timeout
        self.admitted = 0
        self.closed = False
        self.metrics = Counter()

    async def warm_up(self, timeout=60.0):
        starts = [asyncio.create_task(worker.start()) for worker in self.workers]
        try:
            async with asyncio.timeout(timeout):
                await asyncio.gather(*starts)
        except BaseException:
            for task in starts:
                task.cancel()
            await asyncio.gather(*starts, return_exceptions=True)
            await self.close()
            raise

    async def inspect(self, content, mime_type, *, timeout=None):
        if self.closed:
            raise InspectionFailure("worker-pool-closed")
        deadline_seconds = self.timeout if timeout is None else min(self.timeout, timeout)
        if deadline_seconds <= 0:
            self.metrics["timed_out"] += 1
            raise InspectionTimeout()
        if self.admitted >= self.capacity:
            self.metrics["capacity_rejections"] += 1
            raise QueueCapacityExceeded()
        # Admission is atomic on the event loop: do not await before incrementing.
        self.admitted += 1
        self.metrics["admitted"] += 1
        self.metrics["peak_admitted"] = max(self.metrics["peak_admitted"], self.admitted)
        worker = None
        started = asyncio.get_running_loop().time()
        try:
            async with asyncio.timeout(deadline_seconds):
                worker = await self.available.get()
                self.metrics["active"] += 1
                self.metrics["peak_active"] = max(self.metrics["peak_active"], self.metrics["active"])
                result = await worker.exchange({
                    "body": base64.b64encode(content).decode("ascii"), "mime": mime_type,
                })
            self.metrics["completed"] += 1
            return result
        except asyncio.TimeoutError as error:
            self.metrics["timed_out"] += 1
            if worker is not None:
                await worker.stop()
            raise InspectionTimeout() from error
        except asyncio.CancelledError:
            self.metrics["cancelled"] += 1
            if worker is not None:
                await worker.stop()
            raise
        except Exception as error:
            self.metrics["failed"] += 1
            if worker is not None:
                await worker.stop()
            if isinstance(error, InspectionFailure):
                raise
            raise InspectionFailure("worker-transport-failure") from error
        finally:
            if worker is not None:
                self.metrics["active"] -= 1
                if not self.closed:
                    self.available.put_nowait(worker)
            self.admitted -= 1
            self.metrics["last_elapsed_ms"] = round(
                (asyncio.get_running_loop().time() - started) * 1000
            )

    async def close(self):
        self.closed = True
        await asyncio.gather(*(worker.stop() for worker in self.workers))

    def close_now(self):
        # mitmproxy calls done() after its event loop has terminated.
        self.closed = True
        for worker in self.workers:
            worker.kill_now()
