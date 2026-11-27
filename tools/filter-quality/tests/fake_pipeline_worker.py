"""Deterministic process-boundary fixture, never used by the candidate runtime."""
import base64
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import time
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from downstream.worker_protocol import encode_message, read_message


def send(value):
    sys.stdout.buffer.write(encode_message(value))
    sys.stdout.buffer.flush()


if os.environ.get("PURELINE_TEST_START_DELAY"):
    time.sleep(float(os.environ["PURELINE_TEST_START_DELAY"]))
send({"ready": True})
while True:
    request = read_message(sys.stdin.buffer)
    if request is None:
        break
    body = base64.b64decode(request["body"])
    if body == b"crash":
        os._exit(7)
    if body == b"invalid-message":
        sys.stdout.buffer.write(struct.pack("!I", 2**31))
        sys.stdout.buffer.flush()
        time.sleep(30)
    if body == b"spawn-sleep":
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        Path(sys.argv[1]).write_text(json.dumps({"child": child.pid}))
        time.sleep(30)
    if body.startswith(b"sleep:"):
        time.sleep(float(body.split(b":", 1)[1]))
    send({"ok": True, "outcome": {
        "pid": os.getpid(), "content_hash": hashlib.sha256(body).hexdigest(),
        "response": {"pipeline": {}}, "decision": {
            "action": "allow", "reasons": ["test-fixture"],
            "evidenceIds": [], "modelEvidenceComplete": True,
        }, "cache_hit": False, "replacement": None, "replacement_mime_type": None,
    }})
