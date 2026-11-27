#!/usr/bin/env python3
"""Format/control regressions; synthetic decisions are not accuracy samples."""
from __future__ import annotations
import hashlib
import io
import json
import sys
import struct
import zlib
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from runtime_contract import prepare_runtime
prepare_runtime()
from local_image_filter.domain.models import FilterAction, FilterDecision, FilterOutcome
from downstream.animation_pipeline import AnimationInspectingPipeline, AnimationInspectionError


def animation(colors, *, format="GIF", disposal=2):
    images = [Image.new("RGBA", (32, 32), color) for color in colors]
    output = io.BytesIO()
    options = {"save_all": True, "append_images": images[1:], "duration": 40, "loop": 0}
    if format == "GIF":
        options.update(disposal=disposal, optimize=False)
    images[0].save(output, format=format, **options)
    return output.getvalue()


class ColorPolicy:
    """Deterministic testing seam: any visible red pixel must block a frame."""
    def __init__(self):
        self.calls = []

    def filter_bytes(self, content, mime_type, source_url=None):
        with Image.open(io.BytesIO(content)) as image:
            image.seek(0)
            pixels = image.convert("RGB")
            blocked = any(r > 200 and g < 40 and b < 40 for r, g, b in pixels.get_flattened_data())
        self.calls.append(hashlib.sha256(content).hexdigest())
        action = FilterAction.BLUR if blocked else FilterAction.ALLOW
        replacement = io.BytesIO()
        Image.new("RGB", (32, 32), "gray").save(replacement, format="PNG")
        return FilterOutcome(
            content_hash=hashlib.sha256(content).hexdigest(), response={"pipeline": {}},
            decision=FilterDecision(action, ("test-visible-pixel",)),
            replacement_bytes=replacement.getvalue() if blocked else None,
            replacement_mime_type="image/png" if blocked else None,
        )


rows = []
def check(name, body, expected, **limits):
    policy = ColorPolicy()
    pipeline = AnimationInspectingPipeline(policy, **limits)
    try:
        outcome = pipeline.filter_bytes(body, "image/gif")
        action = outcome.decision.action.value
        metadata = outcome.response.get("pipeline", {}).get("animationInspection")
        if action == "allow":
            assert outcome.replacement_bytes is None
        if action == "blur":
            assert outcome.replacement_mime_type == "image/png"
            with Image.open(io.BytesIO(outcome.replacement_bytes)) as image:
                assert not getattr(image, "is_animated", False)
        reason = None
    except AnimationInspectionError as error:
        action, metadata, reason = "reject", None, str(error)
    assert action == expected, (name, action, expected)
    rows.append({"id": name, "action": action, "expected": expected,
                 "classifier_calls": len(policy.calls), "animation": metadata,
                 "reason": reason, "passed": True})


safe = animation(["navy", "green", "blue"])
check("all-safe-gif-preserves-original", safe, "allow")
assert rows[-1]["animation"]["framesInspected"] == 3
assert rows[-1]["animation"]["complete"]
check("last-frame-blocked-no-first-frame-bypass", animation(["navy", "green", "red"]), "blur")
assert rows[-1]["animation"]["framesInspected"] == 3
check("first-frame-blocked", animation(["red", "green"]), "blur")
assert rows[-1]["animation"]["framesInspected"] == 1
check("middle-single-flash-blocked", animation(["navy", "red", "blue"]), "blur")
check("all-safe-apng", animation(["navy", "green"], format="PNG"), "allow")
check("last-frame-blocked-apng", animation(["navy", "red"], format="PNG"), "blur")
apng = animation(["navy", "red"], format="PNG")
offset = apng.index(b"acTL")
for count in (1, 3):
    data = struct.pack(">II", count, 0)
    mismatch = (apng[:offset + 4] + data +
                struct.pack(">I", zlib.crc32(b"acTL" + data) & 0xffffffff) +
                apng[offset + 16:])
    check(f"apng-false-frame-count-{count}", mismatch, "reject")
check("apng-missing-iend", apng[:-12], "reject")
invalid_crc = bytearray(apng)
invalid_crc[offset + 12] ^= 1
check("apng-invalid-control-crc", bytes(invalid_crc), "reject")
for default, expected in (("navy", "allow"), ("red", "blur")):
    images = [Image.new("RGBA", (32, 32), color) for color in (default, "green", "blue")]
    output = io.BytesIO()
    images[0].save(output, format="PNG", save_all=True, append_images=images[1:],
                   default_image=True, duration=40, loop=0)
    check(f"apng-separate-default-{default}", output.getvalue(), expected)
check("all-safe-webp", animation(["navy", "green"], format="WEBP"), "allow")
check("last-frame-blocked-webp", animation(["navy", "red"], format="WEBP"), "blur")
check("frame-count-exhaustion", safe, "reject", maximum_frames=2)
check("frame-pixels-exhaustion", safe, "reject", maximum_frame_pixels=1023)
check("total-pixels-exhaustion", safe, "reject", maximum_total_pixels=2047)
check("input-bytes-exhaustion", safe, "reject", maximum_bytes=len(safe)-1)
check("deadline-exhaustion", safe, "reject", maximum_seconds=0)
check("corrupt-gif", b"GIF89aBAD", "reject")
check("truncated-gif", safe[:len(safe)//2], "reject")
check("missing-gif-trailer", safe[:-1], "reject")
check("single-static-gif-unchanged", animation(["navy"]), "allow")
assert rows[-1]["animation"] is None and rows[-1]["classifier_calls"] == 1

# Disposal/compositing: small delta-frame red pixels cannot escape inspection.
for disposal in (1, 2, 3):
    first = Image.new("RGBA", (32, 32), "navy")
    delta = first.copy()
    ImageDraw.Draw(delta).rectangle((8, 8, 12, 12), fill="red")
    final = first.copy()
    output = io.BytesIO()
    first.save(output, format="GIF", save_all=True, append_images=[delta, final],
               duration=[30, 10, 30], loop=0, disposal=disposal, optimize=True)
    check(f"delta-pixels-disposal-{disposal}", output.getvalue(), "blur")

report = {"schema": 1, "created_utc": datetime.now(timezone.utc).isoformat(),
          "passed": all(row["passed"] for row in rows), "cases": len(rows),
          "actual_image_decoding": True, "actual_model_inference": False,
          "accuracy_samples_added": 0, "rows": rows,
          "source_sha256": hashlib.sha256((HERE / "downstream/animation_pipeline.py").read_bytes()).hexdigest()}
(HERE / "evidence").mkdir(exist_ok=True)
(HERE / "evidence/animated-format-regression.json").write_text(json.dumps(report, indent=2)+"\n")
print(json.dumps({key: report[key] for key in ["passed", "cases", "actual_model_inference", "source_sha256"]}))
