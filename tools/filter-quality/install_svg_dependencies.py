#!/usr/bin/env python3
"""Install pinned SVG-only dependencies into this versioned package."""
import argparse,subprocess
from pathlib import Path
H=Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument("--python",default="/srv/pureline-poc/.venv/bin/python")
args=p.parse_args()
subprocess.check_call([args.python,"-m","pip","install","--disable-pip-version-check","--no-input",
 "--target",str(H/".vendor-svg"),"--requirement",str(H/"requirements-svg.lock")])
