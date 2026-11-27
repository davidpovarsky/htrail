"""Bounded HTTP content decoding; never call Response.content on input."""
from __future__ import annotations
import zlib

AMBIGUOUS = frozenset({"", "application/octet-stream", "binary/octet-stream",
                       "application/x-octet-stream", "application/x-binary"})
MAXIMUM_IMAGE_BYTES = 4_194_304
DEADLINE_KEY = "pureline_image_deadline"


class BoundedContentError(ValueError):
    def __init__(self, reason):
        self.reason = reason
        super().__init__(reason)


def image_response(flow):
    response = flow.response
    if response is None or flow.request.method.upper() == "HEAD":
        return False
    if response.status_code in {204, 304} or 100 <= response.status_code < 200:
        return False
    mime = response.headers.get("content-type", "").split(";", 1)[0].lower().strip()
    return mime.startswith("image/") or mime in AMBIGUOUS


def _zlib_decode(content, maximum, *, gzip):
    remaining = content
    output = bytearray()
    for _ in range(32):
        decoder = zlib.decompressobj(31 if gzip else 15)
        try:
            part = decoder.decompress(remaining, maximum - len(output) + 1)
        except zlib.error:
            if gzip:
                raise
            decoder = zlib.decompressobj(-15)
            part = decoder.decompress(remaining, maximum - len(output) + 1)
        if len(part) > maximum - len(output) or decoder.unconsumed_tail:
            raise BoundedContentError("image-decoded-too-large")
        output.extend(part)
        if not decoder.eof:
            raise BoundedContentError("image-decode-error")
        remaining = decoder.unused_data
        if not remaining:
            return bytes(output)
        if not gzip:
            raise BoundedContentError("image-decode-error")
    raise BoundedContentError("image-encoding-member-limit")


def _brotli_decode(content, maximum):
    import brotli
    decoder = brotli.Decompressor()
    output = bytearray()
    pending = content
    # The installed Brotli API limits each C output buffer. Empty calls drain
    # buffered input; a single decompress(content) could allocate an expansion.
    for _ in range(maximum // 32_768 + 8):
        part = decoder.process(pending, output_buffer_limit=min(32_768, maximum - len(output) + 1))
        pending = b""
        if len(part) > maximum - len(output):
            raise BoundedContentError("image-decoded-too-large")
        output.extend(part)
        if decoder.is_finished():
            return bytes(output)
        # Brotli may accept more input while decoded output remains buffered.
        # Drain that output before interpreting an empty result as truncation.
        if not part and decoder.can_accept_more_data():
            raise BoundedContentError("image-decode-error")
    raise BoundedContentError("image-decoded-too-large")


def bounded_content(response, maximum=MAXIMUM_IMAGE_BYTES):
    content = response.raw_content or b""
    if len(content) > maximum:
        raise BoundedContentError("image-encoded-too-large")
    encodings = [item.strip().lower() for item in
                 response.headers.get("content-encoding", "").split(",") if item.strip()]
    if len(encodings) > 2:
        raise BoundedContentError("unsupported-content-encoding")
    try:
        for encoding in reversed(encodings):
            if encoding in {"", "identity"}:
                continue
            if encoding in {"gzip", "x-gzip", "deflate"}:
                content = _zlib_decode(content, maximum, gzip=encoding != "deflate")
            elif encoding == "br":
                content = _brotli_decode(content, maximum)
            else:
                raise BoundedContentError("unsupported-content-encoding")
    except BoundedContentError:
        raise
    except Exception as error:
        raise BoundedContentError("image-decode-error") from error
    return content
