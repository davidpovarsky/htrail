from __future__ import annotations

import asyncio
import os
from typing import Any

from mitmproxy import ctx, http

from local_image_filter.config import load_settings
from local_image_filter.domain.models import FilterAction
from local_image_filter.image.rewrite import create_failure_placeholder
from local_image_filter.proxy.filters import ResponseDisposition, ResponseEligibility
from local_image_filter.runtime.container import RuntimeContainer, build_runtime
from downstream.http_input import bounded_content, BoundedContentError

INVALIDATED_HEADERS = (
    "content-encoding",
    "content-range",
    "accept-ranges",
    "etag",
    "content-md5",
    "last-modified",
)


def apply_replacement(
    response: Any,
    body: bytes,
    mime_type: str,
    *,
    reason: str,
    cache: str = "miss",
) -> None:
    response.status_code = 200
    # Clear origin representation headers BEFORE the content setter; mitmproxy
    # otherwise re-encodes replacement bytes using the obsolete Content-Encoding.
    for header in INVALIDATED_HEADERS:
        response.headers.pop(header, None)
    response.content = body
    response.headers["content-type"] = mime_type
    response.headers["content-length"] = str(len(body))
    response.headers["cache-control"] = "no-store"
    response.headers["x-local-image-filter"] = "replace"
    response.headers["x-local-image-filter-cache"] = cache
    response.headers["x-local-image-filter-reason"] = reason


class LocalImageFilterAddon:
    def __init__(self) -> None:
        self.runtime: RuntimeContainer | None = None
        self.eligibility: ResponseEligibility | None = None
        self.semaphore: asyncio.Semaphore | None = None

    def load(self, loader: Any) -> None:
        loader.add_option(
            name="local_image_filter_config",
            typespec=str,
            default=os.environ.get("LOCAL_IMAGE_FILTER_CONFIG", ""),
            help="Path to Local AI Image Filter TOML configuration",
        )

    def create_runtime(self, settings):
        return build_runtime(settings)

    def running(self) -> None:
        configured = str(ctx.options.local_image_filter_config).strip() or None
        settings = load_settings(configured)
        self.runtime = self.create_runtime(settings)
        proxy_config = settings.section("proxy")
        self.eligibility = ResponseEligibility(proxy_config)
        concurrency = min(
            int(proxy_config.get("max_parallel_images", 2)),
            int(settings.section("runtime").get("max_concurrent_inference", 1)),
        )
        self.semaphore = asyncio.Semaphore(concurrency)
        ignored = [str(value) for value in proxy_config.get("ignore_hosts", [])]
        if ignored:
            ctx.options.update(ignore_hosts=ignored)
        ctx.log.info(
            f"Local image filter ready; config={settings.source_description}; "
            f"providers={self.runtime.selected_providers}"
        )

    async def inspect(self, content, mime_type, flow):
        async with self.semaphore:
            return await asyncio.to_thread(self.runtime.pipeline.filter_bytes, content, mime_type, None)

    async def response(self, flow: http.HTTPFlow, *, inspected_content=None) -> None:
        if self.runtime is None or self.eligibility is None or self.semaphore is None:
            return
        response = flow.response
        if response is None:
            return
        try:
            content = inspected_content if inspected_content is not None else bounded_content(
                response, int(self.runtime.settings.section("proxy").get("max_body_bytes", 4_194_304)))
        except BoundedContentError as error:
            body, mime_type = create_failure_placeholder(b"", text="Image decoding unavailable")
            apply_replacement(response, body, mime_type, reason=error.reason)
            return
        result = self.eligibility.classify(
            host=flow.request.pretty_host,
            status_code=response.status_code,
            content_type=response.headers.get("content-type", ""),
            content_length=len(content),
            has_range="range" in flow.request.headers or "content-range" in response.headers,
        )
        if result.disposition == ResponseDisposition.IGNORE:
            return
        if result.disposition == ResponseDisposition.FAIL_CLOSED_IMAGE:
            body, mime_type = create_failure_placeholder(b"", text="Image not inspected")
            apply_replacement(response, body, mime_type, reason=result.reason)
            return

        try:
            outcome = await self.inspect(content, result.mime_type, flow)
        except Exception as error:
            # Do not include a raw exception message: libraries may embed URLs.
            ctx.log.error(f"Image filter pipeline error: {error.__class__.__name__}")
            fail_action = str(self.runtime.settings.section("proxy").get("fail_action", "replace"))
            if fail_action == "allow":
                response.headers["x-local-image-filter"] = "allow"
                response.headers["x-local-image-filter-reason"] = "model-failure-fail-open"
                return
            reason = getattr(error, "reason", "model-failure")
            if reason not in {"inspection-timeout", "inspection-queue-full", "worker-failure"}:
                reason = "model-failure"
            body, mime_type = create_failure_placeholder(b"", text="Image analysis unavailable")
            apply_replacement(response, body, mime_type, reason=reason)
            return

        response.headers["x-local-image-filter"] = outcome.decision.action.value
        response.headers["x-local-image-filter-cache"] = "hit" if outcome.cache_hit else "miss"
        response.headers["x-local-image-filter-reason"] = "policy"

        if outcome.decision.action in {FilterAction.BLUR, FilterAction.REPLACE}:
            if outcome.replacement_bytes is None:
                body, mime_type = create_failure_placeholder(b"", text="Image unavailable")
                apply_replacement(response, body, mime_type, reason="missing-rewrite")
                return
            # Invalidate the original encoding before assigning decoded pixels.
            for header in INVALIDATED_HEADERS:
                response.headers.pop(header, None)
            response.content = outcome.replacement_bytes
            response.headers["content-type"] = outcome.replacement_mime_type or "image/png"
            response.headers["content-length"] = str(len(outcome.replacement_bytes))
            response.headers["cache-control"] = "no-store"
        elif (outcome.decision.action == FilterAction.ALLOW
              and outcome.replacement_bytes is not None
              and outcome.response.get("pipeline", {}).get("svgPresentation") == "rasterized_allow"):
            for header in INVALIDATED_HEADERS:
                response.headers.pop(header, None)
            response.content = outcome.replacement_bytes
            response.headers["content-type"] = "image/png"
            response.headers["content-length"] = str(len(outcome.replacement_bytes))
            response.headers["cache-control"] = "no-store"
            response.headers["x-local-image-filter-presentation"] = "rasterized_allow"
            curated = outcome.response.get("pipeline", {}).get("curatedUIAsset")
            if curated:
                response.headers["x-local-image-filter-policy-exception"] = curated["id"]
                response.headers["x-local-image-filter-reason"] = "curated-public-ui-asset"
        elif outcome.decision.action == FilterAction.ERROR:
            body, mime_type = create_failure_placeholder(b"", text="Image analysis failed")
            apply_replacement(response, body, mime_type, reason="policy-error")


addons = [LocalImageFilterAddon()]
