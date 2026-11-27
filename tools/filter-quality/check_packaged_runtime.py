#!/usr/bin/env python3
"""Focused packaging/diagnostic failure check; no model inference or network."""
import importlib.metadata, json, py_compile, sys
from pathlib import Path
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE))
from runtime_contract import prepare_runtime
contract=prepare_runtime()
for f in HERE.rglob("*.py"):
    if not any(x in f.parts for x in [".data","results",".vendor-svg"]):py_compile.compile(str(f),doraise=True)
from downstream.pureline_addon_v2 import PurelineRemoteFilter
disabled=PurelineRemoteFilter();disabled._count("allow")
assert disabled._counts["allow"]==1 and disabled._health_file is None
broken=PurelineRemoteFilter();broken._health_file=Path("/dev/null/pureline-summary.json");broken._last_write=0
broken._count("allow")
assert broken._counts["allow"]==1 and broken._health_file is None
versions={name:importlib.metadata.version(name)for name in ["onnxruntime","numpy","Pillow","mitmproxy"]}
report={"passed":True,"classifier_files_verified":len(contract["classifier_files"]),"diagnostics_disabled_safe":True,"diagnostic_io_failure_safe":True,"python":sys.version.split()[0],"versions":versions}
(HERE/"evidence/packaging-check.json").write_text(json.dumps(report,indent=2)+"\n")
print(json.dumps(report))
