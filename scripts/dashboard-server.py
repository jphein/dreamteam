#!/usr/bin/env python3
"""dreamteam — local mission-control dashboard server (stdlib only, no pip deps).

Serves the live dashboard as a small LAN-bound HTTP service instead of a
re-published Claude Artifact (JP's call, issue #11):

  GET /            → templates/dashboard.html (raw; the page fetches its own data)
  GET /api/data    → `dashboard-data.sh --json --all-teams` (5s timeout, 5s cache)
  GET /api/version → realm-sigil-style version JSON (imitated, NOT imported — no dep)
  GET /healthz     → "ok" (liveness)

Threaded, binds 127.0.0.1 by default (localhost only — safe); set config
`.dashboard.host` = "0.0.0.0" to expose on the LAN (the homelab norm, opt-in).
Port from config.json `.dashboard.port` (default 8383). Env overrides:
DREAMTEAM_DASHBOARD_PORT / DREAMTEAM_DASHBOARD_HOST (tests use an ephemeral port),
DREAMTEAM_DATA_SCRIPT (tests stub the collector). Graceful SIGTERM/SIGINT. The
data collector is capped + cached so a refresh storm can never fork-bomb the host.
"""
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.environ.get("CLAUDE_PLUGIN_ROOT") or os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))
CFG_PATH    = os.environ.get("DREAMTEAM_CONFIG") or os.path.join(ROOT, "config.json")
TEMPLATE    = os.path.join(ROOT, "templates", "dashboard.html")
# DREAMTEAM_DATA_SCRIPT lets tests point /api/data at a stub collector (hermetic).
DATA_SCRIPT = os.environ.get("DREAMTEAM_DATA_SCRIPT") or os.path.join(ROOT, "scripts", "dashboard-data.sh")
PLUGIN_JSON = os.path.join(ROOT, "plugin.json")

DATA_TIMEOUT = 5      # s — cap the collector so a slow subprocess can't hang a client
DATA_TTL     = 5.0    # s — cache window so a refresh storm can't fork-bomb the collector
DEFAULT_PORT = 8383


def _cfg():
    try:
        with open(CFG_PATH) as fh:
            c = json.load(fh)
        return c if isinstance(c, dict) else {}
    except Exception:
        return {}


def _port():
    env = os.environ.get("DREAMTEAM_DASHBOARD_PORT", "").strip()
    if env.isdigit():
        return int(env)
    dash = _cfg().get("dashboard")
    if isinstance(dash, dict):
        try:
            return int(dash.get("port", DEFAULT_PORT))
        except Exception:
            pass
    return DEFAULT_PORT


def _host():
    # Localhost by default (safe); set config .dashboard.host (or the env var) to
    # "0.0.0.0" to expose on the LAN — the homelab norm, but opt-in.
    env = os.environ.get("DREAMTEAM_DASHBOARD_HOST", "").strip()
    if env:
        return env
    dash = _cfg().get("dashboard")
    if isinstance(dash, dict) and dash.get("host"):
        return str(dash["host"])
    return "127.0.0.1"


# ── realm-sigil-style version (imitated, NOT imported — keeps this dep-free) ──
# Mirrors realm_sigil.generate_name(): deterministic adjective+noun seeded by the
# git hash, rendered "<adj> <noun> · <hash>". Wordlist is dream/candle themed to
# match the dashboard's aesthetic.
_ADJ = ["Luminous", "Silver", "Dreaming", "Waning", "Umbral", "Astral", "Lucid",
        "Nocturne", "Ivory", "Drifting", "Haloed", "Wistful", "Veiled", "Gentle"]
_NOUN = ["Moth", "Candle", "Lantern", "Moon", "Tide", "Ember", "Beacon", "Wisp",
         "Sigil", "Vigil", "Aurora", "Nimbus", "Reverie", "Warden"]


def _realm_word(h):
    try:
        seed = int(h, 16) if h and h != "dev" else 0
    except Exception:
        seed = 0
    return "%s %s · %s" % (_ADJ[seed % len(_ADJ)], _NOUN[(seed >> 8) % len(_NOUN)], h or "dev")


def _git(*args):
    try:
        return subprocess.run(["git", "-C", ROOT, *args], stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, text=True, timeout=3).stdout.strip()
    except Exception:
        return ""


def _plugin_meta():
    try:
        with open(PLUGIN_JSON) as fh:
            p = json.load(fh)
        return str(p.get("version", "0.0.0")), str(p.get("description", ""))
    except Exception:
        return "0.0.0", ""


STARTED_MONO = time.monotonic()
STARTED_ISO = time.strftime("%Y-%m-%dT%H:%M:%S%z")


def version_payload():
    ver, desc = _plugin_meta()
    h = _git("rev-parse", "--short", "HEAD") or "dev"
    branch = _git("rev-parse", "--abbrev-ref", "HEAD") or "unknown"
    dirty = bool(_git("status", "--porcelain"))
    built = _git("show", "-s", "--format=%cI", "HEAD") or "unknown"
    repo = "https://github.com/jphein/dreamteam"
    return {
        "name": "dreamteam-dashboard",
        "description": desc,
        "version": ver,                       # SemVer from plugin.json
        "codename": _realm_word(h),           # realm-sigil-style deterministic name
        "realm": "dream",
        "hash": h,
        "branch": branch,
        "dirty": dirty,
        "built": built,
        "repo": repo,
        "commit_url": (repo + "/commit/" + h) if h != "dev" else "",
        "host": socket.gethostname(),
        "pid": os.getpid(),
        "started": STARTED_ISO,
        "uptime": int(time.monotonic() - STARTED_MONO),
        "runtime": "python%d.%d" % (sys.version_info.major, sys.version_info.minor),
    }


# ── cached data collector ─────────────────────────────────────────────────────
_data_lock = threading.Lock()
_data_cache = {"at": 0.0, "body": None}


def collect_data():
    """Return (body_bytes, ok). 5s cache; on collector failure serve stale cache
    if we have one, else a small error object (503)."""
    now = time.monotonic()
    with _data_lock:
        if _data_cache["body"] is not None and (now - _data_cache["at"]) < DATA_TTL:
            return _data_cache["body"], True
    try:
        out = subprocess.run(["bash", DATA_SCRIPT, "--json", "--all-teams"],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             text=True, timeout=DATA_TIMEOUT).stdout
        json.loads(out)                       # don't cache a broken collector run
        body = out.encode("utf-8")
        with _data_lock:
            _data_cache["at"] = time.monotonic()
            _data_cache["body"] = body
        return body, True
    except Exception:
        with _data_lock:
            if _data_cache["body"] is not None:
                return _data_cache["body"], True   # serve stale rather than nothing
        return b'{"error":"data collector unavailable"}', False


class Handler(BaseHTTPRequestHandler):
    server_version = "dreamteam-dashboard"
    protocol_version = "HTTP/1.1"

    def _send(self, code, body, ctype):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path == "/":
            try:
                with open(TEMPLATE, "rb") as fh:
                    self._send(200, fh.read(), "text/html; charset=utf-8")
            except Exception:
                self._send(500, "dashboard template not found", "text/plain; charset=utf-8")
        elif path == "/api/data":
            body, ok = collect_data()
            self._send(200 if ok else 503, body, "application/json; charset=utf-8")
        elif path == "/api/version":
            self._send(200, json.dumps(version_payload(), indent=2),
                       "application/json; charset=utf-8")
        elif path == "/healthz":
            self._send(200, "ok", "text/plain; charset=utf-8")
        else:
            self._send(404, '{"error":"not found"}', "application/json; charset=utf-8")

    def log_message(self, fmt, *args):
        # Quiet per-request logging; startup/shutdown go to the journal via print().
        return


def main():
    host = _host()
    httpd = ThreadingHTTPServer((host, _port()), Handler)
    httpd.daemon_threads = True
    port = httpd.server_address[1]   # actual bound port (requested may be 0 → ephemeral)

    def shutdown(signum, _frame):
        print("dreamteam-dashboard: signal %d → shutting down" % signum, flush=True)
        threading.Thread(target=httpd.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    shown = "127.0.0.1" if host in ("0.0.0.0", "") else host
    print("dreamteam-dashboard: serving on http://%s:%d (bind %s) — root %s"
          % (shown, port, host, ROOT), flush=True)
    try:
        httpd.serve_forever(poll_interval=0.5)
    finally:
        httpd.server_close()
        print("dreamteam-dashboard: stopped", flush=True)


if __name__ == "__main__":
    main()
