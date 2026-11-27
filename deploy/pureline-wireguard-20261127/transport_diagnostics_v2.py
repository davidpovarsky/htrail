"""Privacy-preserving transport telemetry with explicit process epochs.
Observes mitmproxy events without modifying traffic.
Never records hostnames, addresses, DNS questions, URLs, credentials, images or packet bytes.
"""
from collections import Counter, deque
from datetime import datetime, timezone
from pathlib import Path
from time import monotonic
import json
import os
import uuid

TARGET = Path(os.environ.get("PURELINE_TRANSPORT_DIAGNOSTICS_PATH",
    "/srv/pureline-poc/diagnostics/transport-path-diagnostics.json"))

class TransportDiagnostics:
    def __init__(self, target=None):
        self.target = Path(target) if target is not None else TARGET
        self.pid = os.getpid()
        self.epoch_id = uuid.uuid4().hex
        self.lifecycle = "starting"
        self.counts = Counter()
        self.recent = deque(maxlen=35)
        self.last_written = 0.0
        self.started_utc = datetime.now(timezone.utc).isoformat()

    def running(self):
        # Publish even with zero traffic; a prior process must never look current.
        self.lifecycle = "running"
        self._flush()

    @staticmethod
    def _category(value):
        msg = str(value or "").lower()
        if "certificate" in msg or "unknown ca" in msg or "verify" in msg:
            return "certificate_or_trust"
        if "reset" in msg or "broken pipe" in msg:
            return "reset"
        if "time" in msg or "deadline" in msg:
            return "timeout"
        if "eof" in msg or "closed" in msg:
            return "connection_closed"
        if "unreachable" in msg or "refused" in msg:
            return "network_unreachable"
        return "other"

    def mark(self, kind, category=None):
        key = kind + (":" + category if category else "")
        self.counts[key] += 1
        if kind.endswith("error") or kind.startswith("tls_failed"):
            self.recent.append({"utc":datetime.now(timezone.utc).isoformat(timespec="seconds"),
                                "kind":kind, "category":category or "none"})
        if self.counts[key] == 1 or monotonic()-self.last_written >= 3 or sum(self.counts.values())%30 == 0:
            self._flush()

    def _flush(self):
        temp = self.target.with_name(self.target.name + "." + self.epoch_id + ".tmp")
        try:
            self.target.parent.mkdir(parents=True, exist_ok=True)
            # A stale instance skips overwriting a newer observed epoch.
            # Readers must still match pid/epoch to the observed live process.
            if self.target.exists():
                try:
                    current = json.loads(self.target.read_text())
                    if (current.get("epoch_id") != self.epoch_id and
                            current.get("started_utc", "") > self.started_utc):
                        return
                except (ValueError, OSError):
                    pass
            payload = {"schema":2, "pid":self.pid, "epoch_id":self.epoch_id,
                       "lifecycle":self.lifecycle, "started_utc":self.started_utc,
                       "updated_utc":datetime.now(timezone.utc).isoformat(timespec="seconds"),
                       "counts":dict(sorted(self.counts.items())),
                       "recent_error_categories":list(self.recent)}
            raw = json.dumps(payload,ensure_ascii=True,indent=2)+"\n"
            descriptor = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(descriptor, "w") as file:
                file.write(raw)
            os.replace(temp,self.target)
            self.last_written=monotonic()
        except OSError:
            # Telemetry is best-effort and cannot alter a network response.
            pass
        finally:
            try:
                temp.unlink(missing_ok=True)
            except OSError:
                pass

    def tls_established_client(self, data):
        self.mark("tls_client_established")
    def tls_established_server(self, data):
        self.mark("tls_server_established")
    def tls_failed_client(self, data):
        self.mark("tls_failed_client", self._category(getattr(data.conn,"error",None)))
    def tls_failed_server(self, data):
        self.mark("tls_failed_server", self._category(getattr(data.conn,"error",None)))
    def quic_start_client(self, data):
        self.mark("quic_client_started")
    def dns_request(self, flow):
        self.mark("dns_query")
    def dns_response(self, flow):
        self.mark("dns_response")
    def dns_error(self, flow):
        self.mark("dns_error",self._category(getattr(flow,"error",None)))
    def request(self, flow):
        self.mark("http_request")
    def response(self, flow):
        code = getattr(getattr(flow,"response",None),"status_code",0)
        self.mark("http_response", "2xx" if 200<=code<300 else
                "3xx" if 300<=code<400 else
                "4xx" if 400<=code<500 else
                "5xx" if 500<=code<600 else "other")
    def error(self, flow):
        self.mark("http_error",self._category(getattr(getattr(flow,"error",None),"msg",None)))
    def server_connect_error(self, data):
        self.mark("server_connect_error",self._category(getattr(data.server,"error",None)))
    def done(self):
        self.lifecycle = "stopped"
        self._flush()

addons=[TransportDiagnostics()]
