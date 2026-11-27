#!/usr/bin/env python3
"""Run the pinned upstream parity suite with the product's Core ML compute policy.

iOS 27+ already uses CPU_ONLY in MobileCLIPService (MPSGraph SDPA workaround).
This adapter changes only MLModel's documented compute_units argument; it leaves
all ten deterministic fixtures and upstream acceptance thresholds unchanged.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import platform
import sys
import tempfile
from types import SimpleNamespace

VERIFIER_SHA256 = "e55600060d8aa63b8944b46fba24aa7f90064c582c90b6574bcb95c6a6703b09"
CONVERTER_SHA256 = "8ca2cf1416655a5d1698fb5a9138f5850242a9b813120fa7d6c1a79f2b52e03d"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--models", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--vendor-root", type=Path, default=Path(__file__).resolve().parents[1] / "Vendor/AI-Image-Classifier")
    parser.add_argument("--compute-units", choices=("CPU_ONLY", "CPU_AND_GPU", "ALL"), default="CPU_ONLY",
                        help="CPU_ONLY matches the existing iOS 27+ product policy; other values are explicit diagnostics.")
    args = parser.parse_args()
    tool_dir = args.vendor_root.resolve() / "tools/MobileCLIPConversion"
    verifier_path = tool_dir / "verify_conversion.py"
    for path, expected in ((verifier_path, VERIFIER_SHA256),
                           (tool_dir / "convert_mobileclip2_s2.py", CONVERTER_SHA256)):
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise SystemExit(f"Pinned verification source changed; review its fixtures and thresholds before updating this adapter: {path}")

    # Import the original verifier, then provide a narrow local view of Core ML.
    # This does not patch global coremltools or alter the verifier's main function.
    sys.path.insert(0, str(tool_dir))
    spec = importlib.util.spec_from_file_location("pureline_upstream_conversion_verifier", verifier_path)
    if spec is None or spec.loader is None:
        raise SystemExit("Cannot load the pinned conversion verifier.")
    verifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verifier)
    compute_units = getattr(verifier.ct.ComputeUnit, args.compute_units)
    native_model_loader = verifier.ct.models.MLModel

    def load_model(*model_args, **model_kwargs):
        return native_model_loader(*model_args, compute_units=compute_units, **model_kwargs)

    verifier.ct = SimpleNamespace(models=SimpleNamespace(MLModel=load_model))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    upstream_exit = 0
    saved_argv = sys.argv
    with tempfile.TemporaryDirectory(prefix=".pureline-verification-", dir=args.output.parent) as directory:
        fresh_output = Path(directory) / "upstream-result.json"
        sys.argv = [str(verifier_path), "--checkpoint", str(args.checkpoint.resolve()),
                    "--models", str(args.models.resolve()), "--output", str(fresh_output)]
        try:
            verifier.main()
        except SystemExit as error:
            upstream_exit = error.code if isinstance(error.code, int) else 1
            if error.code:
                print(str(error), file=sys.stderr)
        finally:
            sys.argv = saved_argv
        result = json.loads(fresh_output.read_text()) if fresh_output.is_file() else {"passed": False}
    contract_passed = (
        result.get("samples") == 10
        and result.get("sameTopCategorySamples") == 10
        and result.get("finite") is True
        and result.get("minimumImageEmbeddingCosine", 0) >= 0.995
        and result.get("maximumScoreDifference", float("inf")) <= 0.03
    )
    # Tighten failure propagation; never turn an upstream failure into a pass.
    result["passed"] = result.get("passed") is True and contract_passed and upstream_exit == 0
    result["verificationContext"] = {
        "computeUnits": args.compute_units,
        "defaultProductPolicy": "iOS27AndLaterCPUOnly",
        "upstreamVerifierSHA256": VERIFIER_SHA256,
        "upstreamConverterSHA256": CONVERTER_SHA256,
        "upstreamExitCode": upstream_exit,
        "fixtureCountRequired": 10,
        "thresholdsUnchanged": True,
        "hostPlatform": platform.platform(),
    }
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
