"""Pinned process-local mitmproxy seam for image buffers before addon hooks.

mitmproxy 12.2.3 has no public per-flow body limit. Its global body_size_limit
also rejects large uploads/nonimages, while stream callbacks send headers before
an async verdict. This reviewed adapter does not edit installed vendor files or
global options. Source/version drift is a fatal startup error.
"""
from __future__ import annotations
import hashlib
import importlib.metadata
from pathlib import Path
import time
import weakref

from downstream.http_input import DEADLINE_KEY, MAXIMUM_IMAGE_BYTES, image_response

EXPECTED_VERSION = "12.2.3"
EXPECTED_SOURCES = {
    "proxy/layers/http/__init__.py": "0e7b3474f7febddcf81cb69685f3cd9a3b7af9c849ae47925add565e9ed67d4c",
    "proxy/layer.py": "c45454046edfdf03a62642405857fbf48d309c9cd1112e5d0f605cf6ccc79a13",
    "proxy/events.py": "fda47e3a66245adb1ce5b9bff7f6c50bb57ecdc9280047b09246b9d5daee9933",
    "proxy/commands.py": "aa32ee34a747871dca9c22ae3b2f36e40023e78a9d82c0855573a863d03c039e",
}
_installed = None


def verify_transport_source():
    import mitmproxy
    if importlib.metadata.version("mitmproxy") != EXPECTED_VERSION:
        raise RuntimeError("unverified-mitmproxy-version")
    root = Path(mitmproxy.__file__).resolve().parent
    for name, expected in EXPECTED_SOURCES.items():
        if hashlib.sha256((root / name).read_bytes()).hexdigest() != expected:
            raise RuntimeError("unverified-mitmproxy-http-source")
    return dict(EXPECTED_SOURCES)


def install_http_body_bounds():
    global _installed
    verify_transport_source()
    if _installed is not None:
        return _installed
    from mitmproxy import flow as flow_module
    from mitmproxy.proxy import commands, events
    from mitmproxy.proxy.layers import http as transport
    from mitmproxy.net.http.http1 import expected_http_body_size
    from mitmproxy.utils import human

    class Bounds:
        maximum_bytes = MAXIMUM_IMAGE_BYTES
        peak_buffer_bytes = 0
        size_aborts = 0
        body_timeouts = 0
        weak_streams = weakref.WeakSet()
        weak_parents = weakref.WeakSet()

    bounds = Bounds()
    stream_class = transport.HttpStream
    parent_class = transport.HttpLayer
    original_check = stream_class.check_body_size
    original_consume = stream_class.state_consume_response_body
    original_headers = stream_class.state_wait_for_response_headers
    original_event = stream_class._handle_event
    original_parent_event = parent_class._handle_event
    original_child = parent_class.event_to_child

    def limit(stream):
        configured = human.parse_size(stream.context.options.body_size_limit)
        return min(bounds.maximum_bytes, configured) if configured is not None else bounds.maximum_bytes

    def abort(stream, reason, *, timeout=False):
        stream.response_body_buf.clear()
        if stream.flow.response is not None:
            stream.flow.response.raw_content = None
        if timeout:
            bounds.body_timeouts += 1
        else:
            bounds.size_aborts += 1
        code = transport.ErrorCode.RESPONSE_TOO_LARGE
        stream.flow.error = flow_module.Error(reason)
        yield transport.HttpErrorHook(stream.flow)
        yield transport.SendHttp(transport.ResponseProtocolError(stream.stream_id, reason, code),
                                 stream.context.client)
        yield transport.SendHttp(transport.RequestProtocolError(stream.stream_id, reason, code),
                                 stream.context.server)
        stream.client_state = stream.server_state = stream.state_errored
        stream.flow.live = False

    def check_size(stream, request):
        if request or not image_response(stream.flow):
            return (yield from original_check(stream, request))
        size = len(stream.response_body_buf)
        if not size:
            try:
                size = expected_http_body_size(stream.flow.request, stream.flow.response) or 0
            except ValueError:
                size = 0  # installed header validation rejects malformed framing
        if size > limit(stream):
            if not stream.response_body_buf:
                yield transport.HttpResponseHeadersHook(stream.flow)
            yield from abort(stream, "pureline-image-body-limit")
            return True
        # Never let stream_large_bodies expose an uninspected image. Known
        # nonimages and requests retain the original implementation unchanged.
        return False

    def consume(stream, event):
        if image_response(stream.flow):
            if isinstance(event, transport.ResponseData):
                buffered = len(stream.response_body_buf) + len(event.data)
                if buffered > limit(stream):
                    yield from abort(stream, "pureline-image-body-limit")
                    return
                bounds.peak_buffer_bytes = max(bounds.peak_buffer_bytes, buffered)
            elif isinstance(event, transport.ResponseEndOfMessage):
                stream._pureline_body_complete = True
        yield from original_consume(stream, event)

    def headers(stream, event):
        yield from original_headers(stream, event)
        deadline = stream.flow.metadata.get(DEADLINE_KEY)
        if deadline is not None and stream.flow.live and image_response(stream.flow):
            bounds.weak_streams.add(stream)
            wakeup = commands.RequestWakeup(max(0.0, deadline - time.monotonic()))
            wakeup._pureline_stream = weakref.ref(stream)
            stream._pureline_wakeup = wakeup
            yield wakeup

    def stream_event(stream, event):
        if isinstance(event, events.Wakeup) and event.command is getattr(stream, "_pureline_wakeup", None):
            if stream.flow.live and not getattr(stream, "_pureline_body_complete", False):
                yield from abort(stream, "pureline-image-body-timeout", timeout=True)
            return
        if isinstance(event, (transport.RequestProtocolError, transport.ResponseProtocolError)):
            if hasattr(stream, "flow") and image_response(stream.flow):
                stream.response_body_buf.clear()
        yield from original_event(stream, event)

    def child_event(parent, child, event):
        for command in original_child(parent, child, event):
            if isinstance(command, commands.RequestWakeup) and hasattr(command, "_pureline_stream"):
                # A normal wakeup registration strongly retains its stream/body
                # after completion. Keep only weak routing in the owning layer.
                if not hasattr(command, "_pureline_owner"):
                    command._pureline_owner = weakref.ref(parent)
                    bounds.weak_parents.add(parent)
                if command._pureline_owner() is parent:
                    parent.command_sources.pop(command, None)
            yield command

    def parent_event(parent, event):
        if isinstance(event, events.Wakeup) and hasattr(event.command, "_pureline_owner"):
            if event.command._pureline_owner() is parent:
                stream = event.command._pureline_stream()
                if stream is not None:
                    yield from parent.event_to_child(stream, event)
                return
        yield from original_parent_event(parent, event)

    stream_class.check_body_size = check_size
    stream_class.state_consume_response_body = consume
    stream_class.state_wait_for_response_headers = headers
    stream_class._handle_event = stream_event
    parent_class.event_to_child = child_event
    parent_class._handle_event = parent_event
    _installed = bounds
    return bounds
