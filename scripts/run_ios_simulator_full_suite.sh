#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/simulator-full-suite"
LOGS="$OUT/logs"
RESULTS="$OUT/xcresults"
ATTACHMENTS="$OUT/attachments"
DERIVED="$OUT/DerivedData"
FIXTURE="$ROOT/Vendor/AI-Image-Classifier/Screenshots/ClassificationImageSelected.png"
mkdir -p "$LOGS" "$RESULTS" "$ATTACHMENTS" "$OUT/app-data"

cd "$ROOT"

{
  echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "git_sha=$(git rev-parse HEAD)"
  echo "classifier_sha=$(git -C Vendor/AI-Image-Classifier rev-parse HEAD)"
  xcodebuild -version
  swift --version
  sw_vers
  echo "--- SDKs ---"
  xcodebuild -showsdks
  echo "--- Available simulators ---"
  xcrun simctl list devices available
} > "$OUT/environment.txt" 2>&1

xcodegen generate --spec iosapp/project.yml > "$LOGS/xcodegen.log" 2>&1
xcodebuild -project iosapp/HTTrailiOS.xcodeproj -list -json > "$OUT/xcode-project-list.json" 2> "$LOGS/xcode-project-list.err" || true

UDID="$(python3 - <<'PY'
import json, re, subprocess, sys
raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"], text=True)
data = json.loads(raw)
choices = []
for runtime, devices in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    nums = tuple(int(x) for x in re.findall(r"\d+", runtime))
    for d in devices:
        if d.get("isAvailable", True) and "iPad" in d.get("name", ""):
            choices.append((nums, d.get("name", ""), d["udid"]))
if choices:
    choices.sort(reverse=True)
    print(choices[0][2])
    sys.exit(0)

runtimes = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "available", "-j"], text=True)).get("runtimes", [])
runtimes = [r for r in runtimes if r.get("isAvailable", True) and r.get("platform") == "iOS"]
if not runtimes:
    raise SystemExit("No available iOS Simulator runtime")
runtimes.sort(key=lambda r: tuple(int(x) for x in re.findall(r"\d+", r.get("version", "0"))), reverse=True)
runtime = runtimes[0]["identifier"]
types = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devicetypes", "-j"], text=True)).get("devicetypes", [])
ipads = [d for d in types if "iPad" in d.get("name", "")]
if not ipads:
    raise SystemExit("No iPad simulator device type")
ipads.sort(key=lambda d: ("Pro" in d.get("name", ""), d.get("name", "")), reverse=True)
udid = subprocess.check_output(["xcrun", "simctl", "create", "HTTrail QA iPad", ipads[0]["identifier"], runtime], text=True).strip()
print(udid)
PY
)"

echo "$UDID" > "$OUT/simulator-udid.txt"
xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b | tee "$LOGS/simulator-boot.log"
xcrun simctl list devices | grep "$UDID" > "$OUT/simulator-device.txt" || true

# Seed the classifier's original screenshot into Photos so manual picker flows can
# be exercised later without downloading arbitrary test media.
if [ -f "$FIXTURE" ]; then
  xcrun simctl addmedia "$UDID" "$FIXTURE" > "$LOGS/addmedia.log" 2>&1 || true
fi

# Sample host-side simulator process RSS/CPU once per second. Simulator processes
# are native macOS processes, so this is useful for relative app/model memory
# behavior, but it is NOT the iPad PacketTunnel jetsam budget.
(
  echo -e "timestamp_utc\tpid\trss_kb\tcpu_pct\tcommand"
  while true; do
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    ps -axo pid=,rss=,%cpu=,command= | grep -E 'HTTrailiOS\.app/HTTrailiOS|HTTrailUITests-Runner|xctest' | grep -v grep | while IFS= read -r line; do
      printf '%s\t%s\n' "$ts" "$line"
    done
    sleep 1
  done
) > "$OUT/process-samples.tsv" 2>/dev/null &
SAMPLER_PID=$!

stop_sampler() {
  kill "$SAMPLER_PID" >/dev/null 2>&1 || true
  wait "$SAMPLER_PID" >/dev/null 2>&1 || true
}
trap stop_sampler EXIT

set +e
perl -e '$timeout = shift; alarm $timeout; exec @ARGV' 1500 xcodebuild test \
  -project iosapp/HTTrailiOS.xcodeproj \
  -scheme HTTrailRuntimeTests \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED" \
  -resultBundlePath "$RESULTS/runtime-tests.xcresult" \
  -enableCodeCoverage NO \
  -jobs 3 \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee "$LOGS/runtime-tests.log"
UNIT_EXIT=${PIPESTATUS[0]}
echo "$UNIT_EXIT" > "$OUT/runtime-tests-exit.txt"

if [ "${FAST_QA:-0}" = "1" ]; then
  echo "Fast QA: UI journeys skipped; runtime hardening tests and signed build cover changed code." | tee "$LOGS/ui-tests.log"
  UI_EXIT=0
else
  perl -e '$timeout = shift; alarm $timeout; exec @ARGV' 1500 xcodebuild test \
    -project iosapp/HTTrailiOS.xcodeproj \
    -scheme HTTrailUITests \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$DERIVED" \
    -resultBundlePath "$RESULTS/ui-tests.xcresult" \
    -enableCodeCoverage NO \
    -jobs 3 \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | tee "$LOGS/ui-tests.log"
  UI_EXIT=${PIPESTATUS[0]}
fi
echo "$UI_EXIT" > "$OUT/ui-tests-exit.txt"
set -e

stop_sampler
trap - EXIT

for kind in runtime-tests ui-tests; do
  bundle="$RESULTS/$kind.xcresult"
  if [ -d "$bundle" ]; then
    xcrun xcresulttool get test-results summary --path "$bundle" --format json \
      > "$OUT/$kind-summary.json" 2> "$LOGS/$kind-summary.err" || true
    mkdir -p "$ATTACHMENTS/$kind"
    xcrun xcresulttool export attachments --path "$bundle" --output-path "$ATTACHMENTS/$kind" \
      > "$LOGS/$kind-attachments.log" 2>&1 || true
  fi
done

xcrun simctl spawn "$UDID" log show --style compact --last 45m \
  --predicate 'process == "HTTrailiOS" OR process CONTAINS "HTTrail" OR process CONTAINS "xctest"' \
  > "$LOGS/simulator-unified.log" 2>&1 || true

APP_DATA="$(xcrun simctl get_app_container "$UDID" com.davidpovarsky.pureline data 2>/dev/null || true)"
if [ -n "$APP_DATA" ] && [ -d "$APP_DATA" ]; then
  echo "$APP_DATA" > "$OUT/app-data-container.txt"
  for rel in Documents "Library/Application Support" Library/Logs tmp; do
    if [ -d "$APP_DATA/$rel" ]; then
      mkdir -p "$OUT/app-data/$(dirname "$rel")"
      cp -R "$APP_DATA/$rel" "$OUT/app-data/$rel" 2>/dev/null || true
    fi
  done
fi

mkdir -p "$OUT/crash-reports"
find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -type f \
  \( -name '*HTTrailiOS*' -o -name '*HTTrail*' -o -name '*xctest*' \) \
  -mmin -60 -exec cp {} "$OUT/crash-reports/" \; 2>/dev/null || true

python3 - "$DERIVED" "$OUT/sizes.json" <<'PY'
import json, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])

def size(path):
    p = pathlib.Path(path)
    if not p.exists(): return None
    if p.is_file(): return p.stat().st_size
    total = 0
    for f in p.rglob('*'):
        try:
            if f.is_file(): total += f.stat().st_size
        except OSError:
            pass
    return total

products = root / 'Build' / 'Products' / 'Debug-iphonesimulator'
apps = list(products.glob('HTTrailiOS.app'))
app = apps[0] if apps else None
items = {}
if app:
    candidates = {
        'HTTrailiOS.app': app,
        'HTTrailiOS executable': app / 'HTTrailiOS',
        'PacketTunnel.appex': app / 'PlugIns' / 'PacketTunnel.appex',
        'EmbeddedImageFilter.framework': app / 'Frameworks' / 'EmbeddedImageFilter.framework',
        'Main MobileCLIP2S2ImageEncoder.mlmodelc': app / 'MobileCLIP2S2ImageEncoder.mlmodelc',
        'Main NudeNet320n.mlmodelc': app / 'NudeNet320n.mlmodelc',
        'PacketTunnel MobileCLIP2S2ImageEncoder.mlmodelc': app / 'PlugIns' / 'PacketTunnel.appex' / 'MobileCLIP2S2ImageEncoder.mlmodelc',
        'PacketTunnel NudeNet320n.mlmodelc': app / 'PlugIns' / 'PacketTunnel.appex' / 'NudeNet320n.mlmodelc',
        'PacketTunnel ImageFilterCore.framework': app / 'PlugIns' / 'PacketTunnel.appex' / 'Frameworks' / 'ImageFilterCore.framework',
    }
    for name, path in candidates.items():
        value = size(path)
        if value is not None: items[name] = {'bytes': value, 'path': str(path)}
for test in products.glob('*.xctest'):
    value = size(test)
    if value is not None: items[test.name] = {'bytes': value, 'path': str(test)}
out.write_text(json.dumps(items, indent=2, sort_keys=True))
PY

if [ "$UNIT_EXIT" -eq 0 ] && [ "$UI_EXIT" -eq 0 ]; then
  SUITE_EXIT=0
else
  SUITE_EXIT=1
fi
echo "$SUITE_EXIT" > "$OUT/suite-exit.txt"
exit "$SUITE_EXIT"
