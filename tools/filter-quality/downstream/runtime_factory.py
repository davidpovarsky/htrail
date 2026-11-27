"""Build the pinned real-model pipeline in the process that will execute it."""
from runtime_contract import RUNTIME, prepare_runtime

prepare_runtime()

from local_image_filter.runtime.container import build_runtime
from downstream.animation_pipeline import AnimationInspectingPipeline
from downstream.face_fallback import FaceFallbackPersonDetector
from downstream.strong_blur import StrongBlurPipeline
from downstream.svg_pipeline import SVGInspectingPipeline


def build_verified_runtime(settings):
    runtime = build_runtime(settings)
    if runtime.manifest is None:
        raise RuntimeError("Expected real model runtime and manifest")
    clip = runtime.manifest.model("mobileCLIP2")
    person = runtime.manifest.model("personDetector")
    if clip.get("source") != "apple/MobileCLIP2-S2":
        raise RuntimeError("Official Apple S2 provenance not verified")
    if "official_decoded" not in str(person.get("runtimeFile")):
        raise RuntimeError("Correct decoded YOLOX model not selected")
    if settings.section("proxy").get("fail_action") != "replace":
        raise RuntimeError("Bounded format inspection requires fail-closed replacement")
    runtime.pipeline.person_detector = FaceFallbackPersonDetector(
        runtime.pipeline.person_detector,
        RUNTIME / "official-candidate/face_yunet_2026may.onnx",
        score_threshold=0.65,
    )
    processing = settings.section("processing")
    runtime.pipeline = SVGInspectingPipeline(AnimationInspectingPipeline(
        StrongBlurPipeline(runtime.pipeline, processing.get("blur_radius", 32.0)),
        maximum_bytes=int(settings.section("proxy").get("max_body_bytes", 4_194_304)),
        maximum_seconds=float(settings.section("proxy").get("request_timeout_seconds", 18)),
    ))
    return runtime
