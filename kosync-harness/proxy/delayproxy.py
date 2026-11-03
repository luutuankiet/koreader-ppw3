#!/usr/bin/env python3
"""Cold-start delay proxy in front of a local kosyncd.

Mimics a scale-to-zero server: the first request after IDLE_S seconds without
traffic is held for HOLD_S seconds before it is forwarded (the "boot"). Any
request arriving while that boot is running waits for the same boot to end, as
on Cloud Run, where one instance starts and every queued request waits for it.
The proxy starts cold.

Control routes, never forwarded and never counted as traffic (GET or POST):
  /_harness/state                       current config and cold/booting/warm
  /_harness/cold                        the next request triggers a boot
  /_harness/warm                        mark warm now, cancel a running boot
  /_harness/config?hold_s=40&idle_s=60&forward_abandoned=1
                                        change config at runtime

Every request is logged as one JSON line to stdout and to LOG_FILE.
Standard library only (Python 3.8+).
"""
import http.client
import json
import os
import select
import socket
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

UPSTREAM = urlsplit(os.environ.get("UPSTREAM", "http://kosyncd:8080"))
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8080"))
LOG_FILE = os.environ.get("LOG_FILE", "/logs/proxy.log")
HOP_BY_HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
              "te", "trailers", "transfer-encoding", "upgrade", "host", "content-length"}


def truthy(v):
    return str(v).strip().lower() in ("1", "true", "yes", "on")


class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.hold_s = float(os.environ.get("HOLD_S", "12"))
        self.idle_s = float(os.environ.get("IDLE_S", "60"))
        # A client that hung up during the hold: forward its request anyway?
        # Default no, so a timed-out push is really lost, as the client believes.
        self.forward_abandoned = truthy(os.environ.get("FORWARD_ABANDONED", "0"))
        self.last_activity = None  # monotonic; None means never, so cold
        self.boot_until = None     # monotonic end of the running boot
        self.force_cold = False
        self.seq = 0

    def snapshot(self):
        now = time.monotonic()
        if self.boot_until is not None and now < self.boot_until:
            phase, extra = "booting", {"boot_remaining_s": round(self.boot_until - now, 3)}
        elif self.force_cold or self.last_activity is None or now - self.last_activity >= self.idle_s:
            phase, extra = "cold", {}
        else:
            phase, extra = "warm", {"cold_in_s": round(self.idle_s - (now - self.last_activity), 3)}
        d = {"phase": phase, "hold_s": self.hold_s, "idle_s": self.idle_s,
             "forward_abandoned": self.forward_abandoned,
             "idle_for_s": None if self.last_activity is None else round(now - self.last_activity, 3)}
        d.update(extra)
        return d

    def admit(self):
        """Return (seq, wait_s, reason) for a new proxied request."""
        with self.lock:
            self.seq += 1
            now = time.monotonic()
            if self.boot_until is not None and now < self.boot_until:
                wait, reason = self.boot_until - now, "joined_boot"
            elif self.force_cold or self.last_activity is None or now - self.last_activity >= self.idle_s:
                if self.force_cold:
                    reason = "forced_cold"
                elif self.last_activity is None:
                    reason = "cold_start_of_proxy"
                else:
                    reason = "idle_%.1fs" % (now - self.last_activity)
                self.force_cold = False
                wait = self.hold_s
                self.boot_until = now + wait if wait > 0 else None
            else:
                wait, reason = 0.0, "warm"
            # The instance is busy until at least the end of the boot.
            self.last_activity = now + wait
            return self.seq, wait, reason

    def touch(self):
        with self.lock:
            now = time.monotonic()
            if self.last_activity is None or now > self.last_activity:
                self.last_activity = now


STATE = State()
LOG_LOCK = threading.Lock()


def iso(ts):
    return datetime.fromtimestamp(ts, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def log(rec):
    line = json.dumps(rec, sort_keys=False)
    with LOG_LOCK:
        print(line, flush=True)
        try:
            with open(LOG_FILE, "a") as f:
                f.write(line + "\n")
        except OSError as e:
            print(json.dumps({"log_error": str(e)}), file=sys.stderr, flush=True)


def client_gone(sock):
    """True if the client closed its side (readable with EOF)."""
    try:
        r, _, _ = select.select([sock], [], [], 0)
        if not r:
            return False
        return sock.recv(1, socket.MSG_PEEK) == b""
    except OSError:
        return True


class Handler(BaseHTTPRequestHandler):
    server_version = "kosync-harness-delayproxy"
    protocol_version = "HTTP/1.0"

    def log_message(self, fmt, *args):  # silence the default access log
        pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _control(self):
        u = urlsplit(self.path)
        q = {k: v[-1] for k, v in parse_qs(u.query).items()}
        action = u.path[len("/_harness/"):].strip("/")
        with STATE.lock:
            if action == "cold":
                STATE.force_cold = True
                STATE.boot_until = None
            elif action == "warm":
                STATE.force_cold = False
                STATE.boot_until = None
                STATE.last_activity = time.monotonic()
            elif action == "config":
                if "hold_s" in q:
                    STATE.hold_s = float(q["hold_s"])
                if "idle_s" in q:
                    STATE.idle_s = float(q["idle_s"])
                if "forward_abandoned" in q:
                    STATE.forward_abandoned = truthy(q["forward_abandoned"])
            elif action != "state":
                self._json(404, {"error": "unknown control " + action})
                return
            snap = STATE.snapshot()
        if action != "state":
            log({"ts": iso(time.time()), "control": action, "query": q, "state": snap})
        self._json(200, snap)

    def _proxy(self):
        t_arrive = time.time()
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        seq, wait, reason = STATE.admit()
        rec = {"id": seq, "ts_arrive": iso(t_arrive), "method": self.command, "path": self.path,
               "client": self.client_address[0], "held": wait > 0, "hold_s": round(wait, 3),
               "reason": reason}
        if wait > 0:
            time.sleep(wait)
        rec["ts_forward"] = iso(time.time())
        if wait > 0 and client_gone(self.connection):
            rec["client_gone_during_hold"] = True
            if not STATE.forward_abandoned:
                STATE.touch()
                rec.update(status=None, outcome="abandoned_not_forwarded", ts_done=iso(time.time()),
                           total_s=round(time.time() - t_arrive, 3))
                log(rec)
                return
        status, outcome = None, "ok"
        try:
            conn = http.client.HTTPConnection(UPSTREAM.hostname, UPSTREAM.port or 80, timeout=30)
            headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP_BY_HOP}
            conn.request(self.command, self.path, body=body, headers=headers)
            resp = conn.getresponse()
            data = resp.read()
            status = resp.status
            conn.close()
        except Exception as e:  # upstream down
            STATE.touch()
            rec.update(status=502, outcome="upstream_error: %s" % e)
            try:
                self._json(502, {"message": "harness: upstream error"})
            except OSError:
                pass
            rec.update(ts_done=iso(time.time()), total_s=round(time.time() - t_arrive, 3))
            log(rec)
            return
        STATE.touch()
        try:
            self.send_response(status)
            for k, v in resp.getheaders():
                if k.lower() not in HOP_BY_HOP and k.lower() not in ("date", "server"):
                    self.send_header(k, v)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            self.wfile.flush()
        except OSError as e:
            outcome = "client_gone_on_reply: %s" % e.__class__.__name__
        rec.update(status=status, outcome=outcome, ts_done=iso(time.time()),
                   total_s=round(time.time() - t_arrive, 3))
        log(rec)

    def _dispatch(self):
        if self.path.startswith("/_harness/"):
            self._control()
        else:
            self._proxy()

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_HEAD = _dispatch


def main():
    srv = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler)
    srv.daemon_threads = True
    log({"ts": iso(time.time()), "event": "start", "upstream": UPSTREAM.geturl(),
         "listen_port": LISTEN_PORT, "state": STATE.snapshot()})
    srv.serve_forever()


if __name__ == "__main__":
    main()
