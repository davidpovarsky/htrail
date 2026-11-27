"""Pinned classifier dependency and existing Oracle runtime paths."""
from __future__ import annotations
import hashlib, json, os, sys
from pathlib import Path
PACKAGE=Path(__file__).resolve().parent
SOURCE=Path(os.environ.get("PURELINE_CLASSIFIER_SOURCE","/srv/pureline-poc/source")).resolve()
RUNTIME=Path(os.environ.get("PURELINE_RUNTIME_ROOT","/srv/pureline-poc")).resolve()
def prepare_runtime():
    contract=json.loads((PACKAGE/"runtime-contract.json").read_text())
    for rel,expected in contract["classifier_files"].items():
        p=SOURCE/rel
        if not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest()!=expected:
            raise RuntimeError("Classifier source differs from pinned5291eed contract: "+rel)
    for rel,expected in contract["external_files"].items():
        p=RUNTIME/rel
        if not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest()!=expected:
            raise RuntimeError("Runtime dependency differs from pinned contract: "+rel)
    for p in (SOURCE/"CrossPlatformImageFilter/src",PACKAGE,RUNTIME/"official-candidate/vendor"):
        if str(p) not in sys.path:sys.path.insert(0,str(p))
    return contract
