"""Inspect every displayed animation frame before returning original bytes.

This is a downstream format adapter: model weights, thresholds, and ordinary
static-image inference are unchanged. Sampling is deliberately not used.
"""
from __future__ import annotations

import hashlib
import io
import time
import zlib
from dataclasses import replace

from PIL import Image, UnidentifiedImageError
from local_image_filter.domain.models import FilterAction


class AnimationInspectionError(RuntimeError):
    """An animation could not be inspected completely within its bounds."""


def _gif_frame_count(content, maximum_frames):
    """Validate the bounded GIF block structure, including its end trailer."""
    if len(content) < 13:
        raise AnimationInspectionError("animation-truncated-gif")
    index = 13
    if content[10] & 0x80:
        index += 3 * (2 ** ((content[10] & 7) + 1))
    frames = 0
    while index < len(content):
        block = content[index]
        index += 1
        if block == 0x3B:
            if not frames:
                raise AnimationInspectionError("animation-has-no-frames")
            return frames
        if block == 0x2C:
            if index + 9 > len(content):
                break
            packed = content[index + 8]
            index += 9
            if packed & 0x80:
                index += 3 * (2 ** ((packed & 7) + 1))
            index += 1  # LZW minimum code size
            frames += 1
            if frames > maximum_frames:
                raise AnimationInspectionError("animation-frame-limit")
        elif block == 0x21:
            index += 1  # extension type
        else:
            raise AnimationInspectionError("animation-invalid-gif-block")
        # Extension and image-data subblocks use the same length-prefixed form.
        while index < len(content):
            length = content[index]
            index += 1
            if length == 0:
                break
            index += length
        else:
            break
    raise AnimationInspectionError("animation-truncated-gif")


def _png_frame_count(content, maximum_frames):
    """Validate APNG frame declarations before Pillow can treat it as static.

    Pillow trusts acTL.n_frames. A false count of one can otherwise hide extra
    fcTL/fdAT chunks from its iterator. Include a separate default PNG image in
    the count, since that image may be displayed by a non-APNG client.
    """
    index = 8
    declared = None
    controls = 0
    seen_idat = False
    separate_default = False
    while index + 12 <= len(content):
        length = int.from_bytes(content[index:index + 4], "big")
        kind = content[index + 4:index + 8]
        end = index + 8 + length
        if end + 4 > len(content):
            break
        data = content[index + 8:end]
        if kind in {b"acTL", b"fcTL", b"IEND"}:
            crc = int.from_bytes(content[end:end + 4], "big")
            if zlib.crc32(kind + data) & 0xffffffff != crc:
                raise AnimationInspectionError("animation-invalid-png-control-crc")
        if kind == b"acTL":
            if declared is not None or seen_idat or length != 8:
                raise AnimationInspectionError("animation-invalid-apng-declaration")
            declared = int.from_bytes(data[:4], "big")
            if not 1 <= declared <= maximum_frames:
                raise AnimationInspectionError("animation-frame-limit")
        elif kind == b"fcTL":
            if declared is None or length != 26:
                raise AnimationInspectionError("animation-invalid-apng-control")
            if not controls:
                separate_default = seen_idat
            controls += 1
            if controls + int(separate_default) > maximum_frames:
                raise AnimationInspectionError("animation-frame-limit")
        elif kind == b"fdAT" and not controls:
            raise AnimationInspectionError("animation-invalid-apng-frame-data")
        elif kind == b"IDAT":
            seen_idat = True
        elif kind == b"IEND":
            if length or not seen_idat:
                raise AnimationInspectionError("animation-invalid-png-end")
            if declared is None:
                return None
            if controls != declared:
                raise AnimationInspectionError("animation-apng-frame-count-mismatch")
            return controls + int(separate_default)
        index = end + 4
    raise AnimationInspectionError("animation-truncated-png")


class AnimationInspectingPipeline:
    def __init__(
        self,
        inner,
        *,
        maximum_frames: int = 128,
        maximum_frame_pixels: int = 4_194_304,
        maximum_total_pixels: int = 33_554_432,
        maximum_bytes: int = 4_194_304,
        maximum_seconds: float = 18.0,
    ):
        self.inner = inner
        self.maximum_frames = maximum_frames
        self.maximum_frame_pixels = maximum_frame_pixels
        self.maximum_total_pixels = maximum_total_pixels
        self.maximum_bytes = maximum_bytes
        self.maximum_seconds = maximum_seconds

    def __getattr__(self, name):
        return getattr(self.inner, name)

    def filter_bytes(self, content, mime_type, source_url=None):
        # Detect the actual format, including a GIF sent under a misleading MIME.
        # Leave unsupported non-raster formats to their existing wrapper.
        if not content.startswith((b"GIF87a", b"GIF89a", b"\x89PNG\r\n\x1a\n", b"RIFF")):
            return self.inner.filter_bytes(content, mime_type, source_url)
        if len(content) > self.maximum_bytes:
            raise AnimationInspectionError("animation-byte-limit")
        started = time.monotonic()
        gif_frames = None
        png_frames = None
        if content.startswith((b"GIF87a", b"GIF89a")):
            gif_frames = _gif_frame_count(content, self.maximum_frames)
        elif content.startswith(b"\x89PNG\r\n\x1a\n"):
            png_frames = _png_frame_count(content, self.maximum_frames)
        try:
            with Image.open(io.BytesIO(content)) as source:
                if source.format not in {"GIF", "PNG", "WEBP"}:
                    return self.inner.filter_bytes(content, mime_type, source_url)
                expected_frames = (gif_frames if source.format == "GIF" else
                                   png_frames if source.format == "PNG" else
                                   source.n_frames)
                if expected_frames is None or expected_frames == 1:
                    return self.inner.filter_bytes(content, mime_type, source_url)
                if expected_frames > self.maximum_frames:
                    raise AnimationInspectionError("animation-frame-limit")
                if source.format != "GIF" and source.n_frames != expected_frames:
                    raise AnimationInspectionError("animation-decoder-frame-count-mismatch")
                self._check_dimensions(source)
                # Avoid n_frames: some decoders scan the whole file to compute it.
                try:
                    source.seek(1)
                except EOFError:
                    raise AnimationInspectionError("animation-decoder-frame-count-mismatch")
                source.seek(0)
                source_format = source.format
                results = {}
                total_pixels = 0
                inspected = 0
                all_cached = True
                final = None
                for index in range(self.maximum_frames + 1):
                    self._check_time(started)
                    try:
                        source.seek(index)
                    except EOFError:
                        break
                    if index == self.maximum_frames:
                        raise AnimationInspectionError("animation-frame-limit")
                    self._check_dimensions(source)
                    total_pixels += source.width * source.height
                    if total_pixels > self.maximum_total_pixels:
                        raise AnimationInspectionError("animation-decoded-pixel-limit")
                    # Pillow seek/load applies GIF/APNG disposal and compositing.
                    # Classify the displayed full canvas, never raw delta tiles.
                    frame = source.convert("RGBA")
                    output = io.BytesIO()
                    frame.save(output, format="PNG")
                    frame_bytes = output.getvalue()
                    frame_key = hashlib.sha256(frame_bytes).hexdigest()
                    if frame_key not in results:
                        results[frame_key] = self.inner.filter_bytes(
                            frame_bytes, "image/png", source_url
                        )
                    final = results[frame_key]
                    inspected += 1
                    all_cached = all_cached and final.cache_hit
                    self._check_time(started)
                    if final.decision.action != FilterAction.ALLOW:
                        return self._outcome(
                            final, content, mime_type, source_format, inspected,
                            len(results), False, all_cached, started,
                        )
                if final is None:
                    raise AnimationInspectionError("animation-has-no-frames")
                if inspected != expected_frames:
                    raise AnimationInspectionError("animation-decoder-frame-count-mismatch")
                return self._outcome(
                    final, content, mime_type, source_format, inspected,
                    len(results), True, all_cached, started,
                )
        except AnimationInspectionError:
            raise
        except (UnidentifiedImageError, OSError, ValueError, IndexError, SyntaxError,
                Image.DecompressionBombError) as error:
            raise AnimationInspectionError("animation-decode-failed") from error

    def _check_dimensions(self, source):
        if source.width < 1 or source.height < 1:
            raise AnimationInspectionError("animation-invalid-dimensions")
        if source.width * source.height > self.maximum_frame_pixels:
            raise AnimationInspectionError("animation-frame-pixel-limit")

    def _check_time(self, started):
        if time.monotonic() - started >= self.maximum_seconds:
            raise AnimationInspectionError("animation-deadline")

    @staticmethod
    def _outcome(outcome, content, mime_type, source_format, count, unique,
                 complete, all_cached, started):
        # Model results refer to frames; transport identity refers to the file.
        outcome.content_hash = hashlib.sha256(content).hexdigest()
        outcome.cache_hit = all_cached
        pipeline = outcome.response.setdefault("pipeline", {})
        pipeline["animationInspection"] = {
            "mode": "every-composited-frame",
            "sourceFormat": source_format,
            "framesInspected": count,
            "uniqueFramesInspected": unique,
            "complete": complete,
            "durationMs": round((time.monotonic() - started) * 1000),
            "presentation": "original-animation" if complete else "static-replacement",
        }
        if complete:
            outcome.decision = replace(
                outcome.decision, reasons=("all-animation-frames-allowed",)
            )
            outcome.replacement_bytes = None
            outcome.replacement_mime_type = None
        pipeline.setdefault("modules", {}).setdefault("policy", {}).setdefault(
            "details", {}
        )["decision"] = outcome.decision.to_dict()
        outcome.response.setdefault("image", {}).update(
            mimeType=mime_type, byteCount=len(content)
        )
        return outcome
