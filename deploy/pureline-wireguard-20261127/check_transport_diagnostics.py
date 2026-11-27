#!/usr/bin/env python3
"""Focused offline regression for private, fresh transport process receipts."""
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import hashlib
import json
import os
import runpy
import sys
from datetime import datetime, timezone

source=Path(__file__).with_name("transport_diagnostics_v2.py")
module=runpy.run_path(str(source))
Diagnostics=module["TransportDiagnostics"]
rows=[]
with TemporaryDirectory(prefix="pureline-transport-epoch-") as temp:
    root=Path(temp)
    target=root/"transport.json"
    target.write_text(json.dumps({"started_utc":"2020-01-01T00:00:00+00:00","counts":{"http_request":999}}))
    first=Diagnostics(target)
    first.running()
    data=json.loads(target.read_text())
    assert data["schema"]==2 and data["pid"]==os.getpid() and data["epoch_id"]==first.epoch_id
    assert data["counts"]=={} and data["lifecycle"]=="running"
    rows.append({"case":"startup replaces stale receipt without traffic","passed":True})
    assert target.stat().st_mode & 0o077==0
    rows.append({"case":"receipt file permissions are private","passed":True})
    first.request(SimpleNamespace(url="https://private.invalid/?token=not-for-output"))
    first.response(SimpleNamespace(response=SimpleNamespace(status_code=200)))
    for _ in range(50):
        first.error(SimpleNamespace(error=SimpleNamespace(msg="reset https://private.invalid/?token=not-for-output")))
    first._flush()
    data=json.loads(target.read_text())
    assert data["counts"]["http_request"]==1 and data["counts"]["http_response:2xx"]==1
    assert data["counts"]["http_error:reset"]==50 and len(data["recent_error_categories"])==35
    assert "private.invalid" not in target.read_text() and "not-for-output" not in target.read_text()
    assert target.stat().st_size<16384 and not list(root.glob("*.tmp"))
    rows.append({"case":"aggregate counts and bounded sanitized error ring","passed":True})
    second=Diagnostics(target)
    second.running()
    assert first.epoch_id!=second.epoch_id and second.started_utc>first.started_utc
    first.done()
    assert json.loads(target.read_text())["epoch_id"]==second.epoch_id
    assert json.loads(target.read_text())["lifecycle"]=="running"
    rows.append({"case":"retired instance skips newer observed epoch","passed":True})
    second.done()
    assert json.loads(target.read_text())["lifecycle"]=="stopped"
    rows.append({"case":"terminal lifecycle is explicit","passed":True})
    parent_file=root/"not-a-directory"
    parent_file.write_text("fixture")
    broken=Diagnostics(parent_file/"transport.json")
    broken.running()
    broken.request(None)
    broken.done()
    rows.append({"case":"diagnostic filesystem failure does not alter hook control flow","passed":True})
report={"created_utc":datetime.now(timezone.utc).isoformat(),"passed":True,"cases":len(rows),
        "source_sha256":hashlib.sha256(source.read_bytes()).hexdigest(),"rows":rows,
        "production_files_modified":False,"scope":"Offline event-hook/receipt checks; not physical traffic acceptance."}
out=Path(sys.argv[1]) if len(sys.argv)>1 else source.with_name("transport-epoch-regression.json")
out.write_text(json.dumps(report,indent=2)+"\n")
print(json.dumps(report))
