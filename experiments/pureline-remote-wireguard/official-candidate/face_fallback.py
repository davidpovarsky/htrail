"""Opt-in YuNet fallback for the Pureline server research runtime.

The original Swift app tries full-human detection before face fallback.
This adapter reproduces its top-left expansion:
x - .75 * face width, y - .5 * face height, width 2.5x, height 5x.
Only engage it when the main person detector returns no results.

This is not face recognition, and does not infer protected identity.
"""
from __future__ import annotations

import threading
from pathlib import Path

import numpy as np
from PIL import Image
from local_image_filter.domain.models import BoundingBox, PersonDetection


class FaceFallbackPersonDetector:
    def __init__(
        self,
        primary,
        model_path: str | Path,
        *,
        score_threshold: float = 0.65,
        max_input_dimension: int = 768,
        max_faces: int = 12,
    ) -> None:
        import cv2
        self.primary = primary
        self._cv2 = cv2
        self._lock = threading.Lock()
        self._face = cv2.FaceDetectorYN_create(
            str(model_path), "", (320, 320), score_threshold, 0.3, 100
        )
        self.max_input_dimension = max_input_dimension
        self.max_faces = max_faces
        self._total_face_fallbacks = 0

    def detect(self, image: Image.Image) -> list[PersonDetection]:
        detected = self.primary.detect(image)
        if detected:
            return detected

        cv2 = self._cv2
        orig_w, orig_h = image.size
        if orig_w < 90 or orig_h < 90:
            return []
        scale = min(1.0, self.max_input_dimension / max(orig_w, orig_h))
        target_w, target_h = max(1, round(orig_w * scale)), max(1, round(orig_h * scale))
        resized = image.convert("RGB")
        if (target_w, target_h) != image.size:
            resized = resized.resize((target_w, target_h), Image.Resampling.BILINEAR)
        rgb = np.asarray(resized, dtype=np.uint8)
        bgr = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
        with self._lock:
            self._face.setInputSize((target_w, target_h))
            _, raw = self._face.detect(bgr)
        if raw is None or len(raw) == 0:
            return []
        results: list[PersonDetection] = []
        for item in sorted(raw, key=lambda row: row[2] * row[3], reverse=True)[:self.max_faces]:
            x, y, w, h = (float(v) for v in item[:4])
            score = float(item[-1])
            if w <= 0 or h <= 0:
                continue
            # Exact equivalence to Vision faceFallback box expansion,
            # translated from Vision's bottom-left into top-left coordinates.
            box = BoundingBox(
                x=(x - 0.75 * w) / target_w,
                y=(y - 0.5 * h) / target_h,
                width=(2.5 * w) / target_w,
                height=(5.0 * h) / target_h,
            ).clamped()
            if box.width <= 0 or box.height <= 0:
                continue
            results.append(
                PersonDetection(
                    person_id=f"face-person-{len(results) + 1}",
                    source="faceFallback",
                    confidence=score,
                    bounding_box=box,
                )
            )
        self._total_face_fallbacks += len(results)
        return results
