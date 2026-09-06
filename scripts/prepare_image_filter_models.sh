#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/Vendor/AI-Image-Classifier"
TOOLS_DIR="$VENDOR_DIR/tools/MobileCLIPConversion"
MODELS_DIR="$VENDOR_DIR/AI-Image-Classifier/Models"
CACHE_ROOT="${IMAGE_FILTER_MODEL_CACHE:-$ROOT_DIR/.model-cache}"
CHECKPOINT_DIR="$CACHE_ROOT/mobileclip2-s2"
CONVERTED_DIR="$CACHE_ROOT/coreml-mobileclip2-s2"
MOBILECLIP_COMMIT="aecfb5453d022e9deff12f81a150ea8f35194baa"
OPEN_CLIP_COMMIT="54c9754a94baacac5b2d9b1c76318078d48912af"

if [ ! -d "$VENDOR_DIR/.git" ] && [ ! -f "$VENDOR_DIR/.git" ]; then
  echo "AI-Image-Classifier submodule is missing. Run: git submodule update --init --recursive"
  exit 1
fi

if [ ! -f "$TOOLS_DIR/requirements.txt" ]; then
  echo "Pinned MobileCLIP conversion tools were not found in the vendored classifier."
  exit 1
fi

mkdir -p "$CHECKPOINT_DIR" "$CONVERTED_DIR" "$MODELS_DIR"

python -m pip install --upgrade pip
python -m pip install -r "$TOOLS_DIR/requirements.txt"

WORK_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/httrail-image-filter-models"
rm -rf "$WORK_ROOT"
mkdir -p "$WORK_ROOT"

git clone -q https://github.com/apple/ml-mobileclip.git "$WORK_ROOT/ml-mobileclip"
git -C "$WORK_ROOT/ml-mobileclip" checkout -q --detach "$MOBILECLIP_COMMIT"
git clone -q https://github.com/mlfoundations/open_clip.git "$WORK_ROOT/open_clip"
git -C "$WORK_ROOT/open_clip" checkout -q --detach "$OPEN_CLIP_COMMIT"
git -C "$WORK_ROOT/open_clip" apply "$WORK_ROOT/ml-mobileclip/mobileclip2/open_clip_inference_only.patch"
cp -R "$WORK_ROOT/ml-mobileclip/mobileclip2/." "$WORK_ROOT/open_clip/src/open_clip/"
python -m pip install -e "$WORK_ROOT/open_clip"
export PYTHONPATH="$WORK_ROOT/ml-mobileclip:$WORK_ROOT/open_clip/src${PYTHONPATH:+:$PYTHONPATH}"

# All original MobileCLIP helper scripts use repository-relative sibling paths.
# Execute every vendor tool from the pinned classifier repository root, exactly
# like its standalone workflow does.
(
  cd "$VENDOR_DIR"
  tools/MobileCLIPConversion/download_model.sh "$CHECKPOINT_DIR"
)

IMAGE_PACKAGE="$CONVERTED_DIR/MobileCLIP2S2ImageEncoder.mlpackage"
PROMPTS="$CONVERTED_DIR/MobileCLIP2S2PromptEmbeddings.json"
MANIFEST="$CONVERTED_DIR/MobileCLIP2S2ModelManifest.json"
REPORT="$CONVERTED_DIR/MobileCLIP2S2ConversionReport.json"

if [ ! -d "$IMAGE_PACKAGE" ] || [ ! -s "$PROMPTS" ] || [ ! -s "$MANIFEST" ] || [ ! -s "$REPORT" ]; then
  rm -rf "$CONVERTED_DIR"
  mkdir -p "$CONVERTED_DIR"
  (
    cd "$VENDOR_DIR"
    python tools/MobileCLIPConversion/convert_mobileclip2_s2.py \
      --checkpoint "$CHECKPOINT_DIR/mobileclip2_s2.pt" \
      --output "$CONVERTED_DIR"
  )
fi

VERIFY_JSON="$CACHE_ROOT/conversion-verification.json"
(
  cd "$VENDOR_DIR"
  python tools/MobileCLIPConversion/verify_conversion.py \
    --checkpoint "$CHECKPOINT_DIR/mobileclip2_s2.pt" \
    --models "$CONVERTED_DIR" \
    --output "$VERIFY_JSON"
)

python - "$VERIFY_JSON" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
if data.get("passed") is not True:
    raise SystemExit(f"MobileCLIP conversion verification failed: {path}")
PY

rm -rf "$MODELS_DIR/MobileCLIP2S2ImageEncoder.mlpackage"
cp -R "$IMAGE_PACKAGE" "$MODELS_DIR/"
cp "$PROMPTS" "$MODELS_DIR/"
cp "$MANIFEST" "$MODELS_DIR/"
cp "$REPORT" "$MODELS_DIR/"
cp "$TOOLS_DIR/MODEL_LICENSE.md" "$MODELS_DIR/MobileCLIP2S2-MODEL-LICENSE.md"

# The direct tunnel and the embedded original UI both load from Bundle.main,
# so the Xcode project intentionally embeds the same verified assets in the host
# app and PacketTunnel extension bundles.
test -d "$MODELS_DIR/NudeNet320n.mlpackage"
test -d "$MODELS_DIR/MobileCLIP2S2ImageEncoder.mlpackage"
test -s "$MODELS_DIR/MobileCLIP2S2PromptEmbeddings.json"
test -s "$MODELS_DIR/MobileCLIP2S2ModelManifest.json"

echo "Image-filter models prepared from pinned AI-Image-Classifier commit $(git -C "$VENDOR_DIR" rev-parse HEAD)"
