#!/usr/bin/env python3
import base64
import html
import json
import re
import statistics
import sys
from pathlib import Path

root = Path(sys.argv[1] if len(sys.argv) > 1 else "build/simulator-full-suite")
root.mkdir(parents=True, exist_ok=True)
logs = root / "logs"

def read(path, default=""):
    p = Path(path)
    try:
        return p.read_text(errors="replace")
    except OSError:
        return default

def exit_code(name):
    raw = read(root / name).strip()
    try: return int(raw)
    except Exception: return None

def extract_json_marker(text, marker):
    for line in text.splitlines():
        if marker in line:
            payload = line.split(marker, 1)[1].strip()
            try: return json.loads(payload)
            except Exception: pass
    return None

def extract_server_marker(text, marker):
    for line in text.splitlines():
        if marker in line:
            tail = line.split(marker, 1)[1].strip()
            values = {}
            for key in ("status", "attempts", "latencyMs", "fixtureBytes"):
                m = re.search(rf"(?:^|\s){key}=([^\s]+)", tail)
                if m:
                    try: values[key] = int(m.group(1))
                    except ValueError: values[key] = m.group(1)
            m = re.search(r"(?:^|\s)body=([^\s]+)", tail)
            if m:
                try:
                    values["body"] = base64.b64decode(m.group(1)).decode("utf-8", "replace")
                except Exception:
                    values["bodyBase64"] = m.group(1)
            return values
    return None

def ui_steps(text):
    found = {}
    for m in re.finditer(r"HTTRAIL_UI_STEP\s+([A-Za-z0-9_]+)=([A-Za-z0-9_-]+)", text):
        found[m.group(1)] = m.group(2)
    return found

def runtime_steps(text):
    found = {}
    for m in re.finditer(r"HTTRAIL_RUNTIME_STEP\s+([A-Za-z0-9_]+)=([A-Za-z0-9_-]+)", text):
        found[m.group(1)] = m.group(2)
    return found

runtime_log = read(logs / "runtime-tests.log")
ui_log = read(logs / "ui-tests.log")
core_log = read(logs / "swift-test.log")
metrics = extract_json_marker(runtime_log, "HTTRAIL_RUNTIME_METRICS") or {}
health = extract_server_marker(ui_log, "HTTRAIL_SERVER_HEALTH") or {}
server_classify = extract_server_marker(ui_log, "HTTRAIL_SERVER_CLASSIFY") or {}
steps = ui_steps(ui_log)
rsteps = runtime_steps(runtime_log)

sizes = {}
try: sizes = json.loads(read(root / "sizes.json", "{}"))
except Exception: pass

process_rows = []
for line in read(root / "process-samples.tsv").splitlines()[1:]:
    if not line.strip(): continue
    try:
        ts, rest = line.split("\t", 1)
    except ValueError:
        continue
    m = re.match(r"\s*(\d+)\s+(\d+)\s+([0-9.]+)\s+(.*)", rest)
    if not m: continue
    pid, rss, cpu, command = m.groups()
    if "HTTrailiOS.app/HTTrailiOS" in command:
        process_rows.append({"timestamp": ts, "pid": int(pid), "rssKB": int(rss), "cpuPercent": float(cpu), "command": command})

process_stats = {}
if process_rows:
    rss = [r["rssKB"] for r in process_rows]
    cpu = [r["cpuPercent"] for r in process_rows]
    process_stats = {
        "samples": len(process_rows),
        "rssKBMin": min(rss),
        "rssKBMax": max(rss),
        "rssKBMean": round(statistics.mean(rss), 1),
        "cpuPercentMax": max(cpu),
        "cpuPercentMean": round(statistics.mean(cpu), 2),
    }

core_exit = exit_code("core-tests-exit.txt")
runtime_exit = exit_code("runtime-tests-exit.txt")
ui_exit = exit_code("ui-tests-exit.txt")
suite_exit = exit_code("suite-exit.txt")

def state(ok, skipped=False):
    if skipped: return "DEVICE-ONLY"
    return "PASS" if ok else "FAIL"

coverage = [
    ("HTTrailCore unit/integration suite", state(core_exit == 0), "Includes the repository's Swift core tests and live HTTPS MITM test on the macOS runner."),
    ("Capture tab UI", state(steps.get("tab_capture") == "pass"), "User-level tab navigation and screenshot; PacketTunnel itself is not runnable in Simulator."),
    ("Compose UI", state(steps.get("tab_compose") == "pass"), "Tab opened and request-editor controls exercised when available."),
    ("Rules UI", state(steps.get("tab_rules") == "pass"), "Tab opened; certificate-pinning toggle exercised/restored when exposed."),
    ("Realtime UI", state(steps.get("tab_realtime") == "pass"), "Tab opened; protocol selector exercised when available."),
    ("Setup UI", state(steps.get("tab_setup") == "pass"), "Tab opened and rendered in Simulator."),
    ("Embedded Image Filter tab", state(steps.get("tab_image_filter") == "pass"), "Full vendored UI opened inside HTTrail."),
    ("Direct VPN filtering control", state(steps.get("direct_filter_toggle") == "pass"), "Real UI toggle exercised and restored; no real PacketTunnel data plane in Simulator."),
    ("Analyze Image UI", state(steps.get("classifier_analyze_ui") == "pass"), "Navigated through the real embedded classifier UI."),
    ("Voice Assistant UI", state(steps.get("classifier_voice_ui") == "pass"), "UI/navigation tested; microphone/speech hardware semantics are device-only."),
    ("Live Camera UI", state(steps.get("classifier_camera_simulator_fallback") == "pass"), "Verified the classifier's explicit Simulator camera fallback."),
    ("Diagnostics UI", state(steps.get("classifier_diagnostics_ui") == "pass"), "Diagnostics screen opened through the real UI."),
    ("Local inference server", state(health.get("status") == 200), f"GET /health status={health.get('status')} after {health.get('attempts')} attempts."),
    ("Local-server image classification", state(server_classify.get("status") == 200), f"POST /v1/image-safety-classify status={server_classify.get('status')} latency={server_classify.get('latencyMs')} ms."),
    ("Direct image-filter bridge", state(rsteps.get("direct_image_filter") == "pass"), "Calls ImageFilterCore directly with the pinned MobileCLIP2 + NudeNet pipeline, bypassing HTTP."),
    ("ImageSniffer", state(rsteps.get("image_sniffer") == "pass"), "Validates image detection on the classifier fixture."),
    ("Real PacketTunnel/VPN routing", state(False, skipped=True), "Apple Simulator does not provide a valid end-to-end Network Extension PacketTunnel environment."),
    ("PacketTunnel jetsam/memory ceiling", state(False, skipped=True), "Simulator memory is host-process memory and cannot prove the iPad Network Extension memory ceiling."),
    ("Real camera / microphone / ANE behavior", state(False, skipped=True), "Requires a physical iPad for representative hardware and background inference behavior."),
]

errors = []
warnings = []
for source, text in (("runtime-tests", runtime_log), ("ui-tests", ui_log), ("swift-test", core_log)):
    for line in text.splitlines():
        low = line.lower()
        if " error:" in low or "fatal error" in low:
            errors.append(f"[{source}] {line.strip()}")
        elif " warning:" in low:
            warnings.append(f"[{source}] {line.strip()}")

report = {
    "overall": "PASS" if core_exit == 0 and suite_exit == 0 else "FAIL",
    "exitCodes": {"core": core_exit, "runtime": runtime_exit, "ui": ui_exit, "simulatorSuite": suite_exit},
    "environment": read(root / "environment.txt"),
    "simulator": read(root / "simulator-device.txt").strip(),
    "runtimeMetrics": metrics,
    "serverHealth": health,
    "serverClassification": server_classify,
    "processStats": process_stats,
    "bundleSizes": sizes,
    "coverage": [{"area": a, "status": s, "notes": n} for a, s, n in coverage],
    "errors": errors[:100],
    "warnings": warnings[:200],
    "artifacts": {
        "runtimeXCResult": "xcresults/runtime-tests.xcresult",
        "uiXCResult": "xcresults/ui-tests.xcresult",
        "screenshotsAndAttachments": "attachments/",
        "logs": "logs/",
        "appData": "app-data/",
        "processSamples": "process-samples.tsv",
        "sizes": "sizes.json"
    },
    "limitations": [
        "Simulator cannot run a representative NEPacketTunnelProvider/VPN data plane; final VPN interception must be validated on a properly provisioned physical iPad.",
        "Simulator RSS/CPU numbers are useful for relative regression analysis but are not the physical iPad jetsam or Network Extension memory limit.",
        "Simulator does not reproduce Neural Engine, camera, microphone, thermal, or background execution behavior of the target iPad.",
    ]
}
(root / "report.json").write_text(json.dumps(report, indent=2, sort_keys=True))

lines = []
lines.append("# HTTrail Full iOS Simulator QA Report")
lines.append("")
lines.append(f"**Overall:** {report['overall']}")
lines.append(f"**Simulator:** {report['simulator'] or 'unknown'}")
lines.append(f"**Exit codes:** core={core_exit}, runtime={runtime_exit}, UI={ui_exit}, simulator suite={suite_exit}")
lines.append("")
lines.append("## Coverage")
lines.append("")
lines.append("| Area | Status | Notes |")
lines.append("|---|---|---|")
for area, status, notes in coverage:
    lines.append(f"| {area} | **{status}** | {notes.replace('|', '/')} |")

lines.append("")
lines.append("## Image-filter runtime metrics")
lines.append("")
if metrics:
    lines.append("```json")
    lines.append(json.dumps(metrics, indent=2, sort_keys=True))
    lines.append("```")
else:
    lines.append("No runtime metrics marker was produced.")

lines.append("")
lines.append("## Local server")
lines.append("")
lines.append("```json")
lines.append(json.dumps({"health": health, "classification": server_classify}, indent=2, sort_keys=True))
lines.append("```")

lines.append("")
lines.append("## Simulator process memory / CPU")
lines.append("")
lines.append("```json")
lines.append(json.dumps(process_stats or {"note": "No HTTrailiOS process samples captured"}, indent=2, sort_keys=True))
lines.append("```")

lines.append("")
lines.append("## Bundle and model sizes")
lines.append("")
lines.append("| Component | Bytes | MiB |")
lines.append("|---|---:|---:|")
for name, item in sorted(sizes.items()):
    b = item.get("bytes", 0)
    lines.append(f"| {name} | {b:,} | {b / 1024 / 1024:.2f} |")

lines.append("")
lines.append("## Diagnostics")
lines.append("")
lines.append(f"Compiler/test errors captured: **{len(errors)}**; warnings captured: **{len(warnings)}**.")
if errors:
    lines.append("")
    lines.append("### Errors")
    for item in errors[:30]: lines.append(f"- `{item[:500]}`")
if warnings:
    lines.append("")
    lines.append("### First warnings")
    for item in warnings[:30]: lines.append(f"- `{item[:500]}`")

lines.append("")
lines.append("## What is inside this artifact")
lines.append("")
lines.append("- `report.html`, `report.md`, `report.json` — this summary in three formats.")
lines.append("- `xcresults/` — complete XCTest/XCUITest result bundles.")
lines.append("- `attachments/` — exported screenshots and XCTest attachments when xcresulttool supports export.")
lines.append("- `logs/` — Xcode build/test logs, unified Simulator logs, XcodeGen logs, and core Swift test output.")
lines.append("- `app-data/` — diagnostic files copied from the Simulator app container when available.")
lines.append("- `process-samples.tsv` — 1-second RSS/CPU sampling for the Simulator app process.")
lines.append("- `sizes.json` — byte-accurate built product/model/framework size breakdown.")

lines.append("")
lines.append("## Device-only limitations")
lines.append("")
for item in report["limitations"]: lines.append(f"- {item}")
lines.append("")
lines.append("**Important:** a green Simulator report validates the merged application, embedded UI/server, models, direct bridge and host-side proxy/core logic. It does **not** prove that both models fit inside the physical iPad PacketTunnel extension memory budget.")

markdown = "\n".join(lines) + "\n"
(root / "report.md").write_text(markdown)

rows = "".join(
    f"<tr><td>{html.escape(a)}</td><td class='{s.lower().replace('-', '')}'>{html.escape(s)}</td><td>{html.escape(n)}</td></tr>"
    for a, s, n in coverage
)
size_rows = "".join(
    f"<tr><td>{html.escape(name)}</td><td>{item.get('bytes',0):,}</td><td>{item.get('bytes',0)/1024/1024:.2f}</td></tr>"
    for name, item in sorted(sizes.items())
)
html_doc = f"""<!doctype html>
<html><head><meta charset='utf-8'><title>HTTrail Simulator QA Report</title>
<style>
body{{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;max-width:1180px;margin:40px auto;padding:0 24px;color:#1b1b1f;background:#fafafa}}
h1,h2{{color:#111827}} .summary{{padding:18px;border:1px solid #ddd;border-radius:12px;background:#fff}}
table{{border-collapse:collapse;width:100%;background:#fff;margin:12px 0 28px}}th,td{{border:1px solid #ddd;padding:9px;text-align:left;vertical-align:top}}th{{background:#f1f5f9}}
.pass{{color:#087f23;font-weight:700}} .fail{{color:#b42318;font-weight:700}} .deviceonly{{color:#8a5a00;font-weight:700}}
pre{{white-space:pre-wrap;word-break:break-word;background:#111827;color:#f8fafc;padding:16px;border-radius:10px;overflow:auto}}code{{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}}
</style></head><body>
<h1>HTTrail Full iOS Simulator QA Report</h1>
<div class='summary'><b>Overall:</b> {html.escape(report['overall'])}<br><b>Simulator:</b> {html.escape(report['simulator'] or 'unknown')}<br><b>Exit codes:</b> core={core_exit}, runtime={runtime_exit}, UI={ui_exit}, suite={suite_exit}</div>
<h2>Coverage</h2><table><tr><th>Area</th><th>Status</th><th>Notes</th></tr>{rows}</table>
<h2>Image-filter runtime metrics</h2><pre>{html.escape(json.dumps(metrics, indent=2, sort_keys=True))}</pre>
<h2>Local server</h2><pre>{html.escape(json.dumps({'health':health,'classification':server_classify}, indent=2, sort_keys=True))}</pre>
<h2>Simulator process memory / CPU</h2><pre>{html.escape(json.dumps(process_stats, indent=2, sort_keys=True))}</pre>
<h2>Bundle/model sizes</h2><table><tr><th>Component</th><th>Bytes</th><th>MiB</th></tr>{size_rows}</table>
<h2>Diagnostics</h2><p>Errors captured: <b>{len(errors)}</b>; warnings captured: <b>{len(warnings)}</b>.</p><pre>{html.escape(chr(10).join(errors[:30] + warnings[:30]))}</pre>
<h2>Device-only limitations</h2><ul>{''.join('<li>'+html.escape(x)+'</li>' for x in report['limitations'])}</ul>
<p><b>Important:</b> Simulator results do not establish the physical iPad PacketTunnel memory ceiling.</p>
</body></html>"""
(root / "report.html").write_text(html_doc)
print(root / "report.html")
