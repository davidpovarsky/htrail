"""Pureline research trial: official Apple S2 + decoded YOLOX + face fallback.

The existing v2 response-streaming behavior is preserved unchanged.
This file does not modify the upstream classifier package.
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path("/srv/pureline-poc")
CANDIDATE = ROOT / "official-candidate"
VENDOR = CANDIDATE / "vendor"
for directory in (CANDIDATE, VENDOR):
    location = str(directory)
    if location not in sys.path:
        sys.path.insert(0, location)

from face_fallback import FaceFallbackPersonDetector
from pureline_addon_v2 import PurelineRemoteFilter


class PurelineVerifiedFilter(PurelineRemoteFilter):
    def running(self) -> None:
        super().running()
        if self.runtime is None:
            raise RuntimeError("Candidate filter runtime missing")
        manifest = self.runtime.manifest
        if manifest is None:
            raise RuntimeError("Expected real model manifest")
        clip_metadata = manifest.model("mobileCLIP2")
        person_metadata = manifest.model("personDetector")
        if clip_metadata.get("source") != "apple/MobileCLIP2-S2":
            raise RuntimeError("Official Apple S2 provenance not verified")
        if "official_decoded" not in str(person_metadata.get("runtimeFile")):
            raise RuntimeError("Correct decoded YOLOX model not selected")
        detector = self.runtime.pipeline.person_detector
        self.runtime.pipeline.person_detector = FaceFallbackPersonDetector(
            detector,
            CANDIDATE / "face_yunet_2026may.onnx",
            score_threshold=0.65,
        )


addons = [PurelineVerifiedFilter()]
