"""Pinned downstream Pureline server candidate; no live service mutations."""
from __future__ import annotations
import sys
from pathlib import Path
PACKAGE=Path(__file__).resolve().parents[1]
if str(PACKAGE)not in sys.path:sys.path.insert(0,str(PACKAGE))
from runtime_contract import prepare_runtime, RUNTIME
prepare_runtime()
from downstream.face_fallback import FaceFallbackPersonDetector
from downstream.pureline_addon_v2 import PurelineRemoteFilter
from downstream.svg_pipeline import SVGInspectingPipeline
from downstream.strong_blur import StrongBlurPipeline
class PurelineVerifiedFilter(PurelineRemoteFilter):
    def running(self):
        super().running()
        if self.runtime is None or self.runtime.manifest is None:
            raise RuntimeError("Expected real model runtime and manifest")
        clip=self.runtime.manifest.model("mobileCLIP2")
        person=self.runtime.manifest.model("personDetector")
        if clip.get("source")!="apple/MobileCLIP2-S2":
            raise RuntimeError("Official Apple S2 provenance not verified")
        if "official_decoded"not in str(person.get("runtimeFile")):
            raise RuntimeError("Correct decoded YOLOX model not selected")
        self.runtime.pipeline.person_detector=FaceFallbackPersonDetector(
            self.runtime.pipeline.person_detector,
            RUNTIME/"official-candidate/face_yunet_2026may.onnx",score_threshold=0.65)
        if self.runtime.settings.section("proxy").get("fail_action")!="replace":
            raise RuntimeError("Bounded SVG requires fail-closed replacement")
        self.runtime.pipeline=SVGInspectingPipeline(StrongBlurPipeline(
            self.runtime.pipeline,self.runtime.settings.section("processing").get("blur_radius",32.0)))
        self.eligibility.allowed_content_types.add("image/svg+xml")
addons=[PurelineVerifiedFilter()]
