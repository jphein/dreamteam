#!/usr/bin/env python3
"""dreamteam GPU fleet: the inventory, the claims ledger, windows, admission math, the board, and the
launch guard's decision. Spec: docs/superpowers/specs/2026-09-29-gpu-fleet-design.md.

Called by scripts/gpu.sh (the `dreamteam gpu` front door) and scripts/gpu-guard.sh (the PreToolUse
hook). Identity comes in as DREAMTEAM_AGENT_ID, which the bash callers compute with lib/agent-id.sh:
the ancestry walk lives in ONE place, so two copies cannot drift. Empty = an orchestrator or JP.

Env seams (tests): DREAMTEAM_GPU_FLEET (inventory), DREAMTEAM_GPU_STATE (ledger dir), DREAMTEAM_CONFIG,
DREAMTEAM_GPU_NOW (epoch seconds), DREAMTEAM_GPU_SSH (the ssh binary), DREAMTEAM_GPU_LOCAL_HOST.
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import fnmatch
import hashlib
import json
import math
import os
import re
import shlex
import socket
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REFUSED, NOPERM, USAGE = 75, 77, 2


# ── paths, config, time ───────────────────────────────────────────────────────────────────────────

def fleet_path() -> str:
    return os.environ.get("DREAMTEAM_GPU_FLEET") or os.path.join(ROOT, "gpu", "fleet.json")


def state_dir() -> str:
    return os.environ.get("DREAMTEAM_GPU_STATE") or os.path.expanduser("~/.claude/state/dreamteam/gpu")


def load_config() -> dict:
    path = os.environ.get("DREAMTEAM_CONFIG") or os.path.join(ROOT, "config.json")
    try:
        with open(path) as f:
            return json.load(f).get("gpu") or {}
    except (OSError, ValueError):
        return {}


def guard_mode(cfg: dict) -> str:
    """warn (the rollout default), enforce, or off. A missing or unreadable config is warn, never off:
    an absent switch is not a disabled guard (the no-poll-guard lesson)."""
    m = str(cfg.get("guard", "warn")).lower()
    return m if m in ("warn", "enforce", "off") else "warn"


def granters(cfg: dict) -> list:
    g = cfg.get("granters")
    return list(g) if isinstance(g, list) else ["nyx*", "morpheus-gems"]


def now() -> float:
    v = os.environ.get("DREAMTEAM_GPU_NOW")
    return float(v) if v else time.time()


def load_fleet() -> dict:
    with open(fleet_path()) as f:
        return json.load(f)


# ── parsing ───────────────────────────────────────────────────────────────────────────────────────

def parse_mb(v) -> int:
    """'2500M', '3G', '1.5G', '4096' (MB) -> MB. The systemd-style units safe_run and guest_run take."""
    s = str(v).strip().upper()
    m = re.fullmatch(r"(\d+(?:\.\d+)?)([KMGT]?)B?", s)
    if not m:
        raise ValueError(f"bad size {v!r} (use e.g. 2500M, 3G, or MB as a number)")
    n, u = float(m.group(1)), m.group(2)
    return int(math.ceil(n * {"": 1, "K": 1 / 1024, "M": 1, "G": 1024, "T": 1024 * 1024}[u]))


def parse_until(s: str, t0: float) -> float:
    """'2h', '90m', '1d', '18:00' (next occurrence, local), '2026-09-29T18:00' -> epoch seconds."""
    s = s.strip()
    m = re.fullmatch(r"(\d+(?:\.\d+)?)\s*([mhd])", s)
    if m:
        return t0 + float(m.group(1)) * {"m": 60, "h": 3600, "d": 86400}[m.group(2)]
    m = re.fullmatch(r"(\d{1,2}):(\d{2})", s)
    if m:
        lt = time.localtime(t0)
        target = time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, int(m.group(1)), int(m.group(2)), 0, 0, 0, -1))
        return target if target > t0 else target + 86400
    for fmt in ("%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M", "%Y-%m-%dT%H:%M:%S"):
        with contextlib.suppress(ValueError):
            return time.mktime(time.strptime(s, fmt))
    raise ValueError(f"bad --until {s!r} (use 2h, 90m, 18:00 or 2026-09-29T18:00)")


def window_open(spec: str, t: float) -> bool:
    """'always', 'never', or 'HH:MM-HH:MM' in local time; a window may cross midnight."""
    spec = (spec or "always").strip().lower()
    if spec == "always":
        return True
    if spec == "never":
        return False
    m = re.fullmatch(r"(\d{1,2}):(\d{2})-(\d{1,2}):(\d{2})", spec)
    if not m or int(m.group(1)) > 23 or int(m.group(3)) > 23 or int(m.group(2)) > 59 or int(m.group(4)) > 59:
        raise ValueError(f"bad window {spec!r} (use HH:MM-HH:MM with hours 00-23, always or never)")
    lt = time.localtime(t)
    cur = lt.tm_hour * 60 + lt.tm_min
    a = int(m.group(1)) * 60 + int(m.group(2))
    b = int(m.group(3)) * 60 + int(m.group(4))
    return a <= cur < b if a < b else (cur >= a or cur < b)


def cap_mb(peak_mb: float, grows: bool, fleet: dict) -> int:
    d = fleet.get("defaults", {})
    return int(math.ceil(peak_mb * (d.get("grows_margin", 1.5) if grows else d.get("cap_margin", 1.2))))


def fmt_t(t: float | None) -> str:
    return time.strftime("%a %H:%M", time.localtime(t)) if t else "-"


# ── identity ──────────────────────────────────────────────────────────────────────────────────────

def caller() -> str:
    """name@team for a teammate, '' for an orchestrator or JP (computed by lib/agent-id.sh)."""
    return os.environ.get("DREAMTEAM_AGENT_ID", "").strip()


def lane_of(agent_id: str) -> str:
    return agent_id.split("@", 1)[0] if agent_id else ""


def is_granter(agent_id: str, cfg: dict) -> bool:
    if not agent_id:
        return True  # an orchestrator session or JP's own shell
    lane = lane_of(agent_id)
    return any(fnmatch.fnmatch(lane, p) for p in granters(cfg))


# ── the ledger ────────────────────────────────────────────────────────────────────────────────────

class Ledger:
    """claims.json under an exclusive flock; written atomically (tmp + rename)."""

    def __init__(self, write: bool = False):
        self.dir, self.write = state_dir(), write
        self.path = os.path.join(self.dir, "claims.json")

    def __enter__(self):
        os.makedirs(self.dir, exist_ok=True)
        self._lock = open(os.path.join(self.dir, "claims.lock"), "a+")
        fcntl.flock(self._lock, fcntl.LOCK_EX if self.write else fcntl.LOCK_SH)
        try:
            with open(self.path) as f:
                self.data = json.load(f)
        except (OSError, ValueError):
            self.data = {}
        self.data.setdefault("claims", {})
        self.data.setdefault("windows", {})
        self.data.setdefault("history", [])
        return self

    def __exit__(self, exc_type, *_):
        try:
            if self.write and exc_type is None:
                tmp = self.path + ".tmp"
                with open(tmp, "w") as f:
                    json.dump(self.data, f, indent=1, sort_keys=True)
                os.replace(tmp, self.path)
        finally:
            fcntl.flock(self._lock, fcntl.LOCK_UN)
            self._lock.close()
        return False

    def live_claims(self, t: float) -> dict:
        return {c: v for c, v in self.data["claims"].items() if v.get("until", 0) > t}

    def log(self, event: str, **kw):
        self.data["history"].append({"ts": now(), "event": event, **kw})
        self.data["history"] = self.data["history"][-500:]


# ── admission ─────────────────────────────────────────────────────────────────────────────────────

class Refused(Exception):
    """An admission or permission refusal; .code is the exit code."""

    def __init__(self, msg: str, code: int = REFUSED):
        super().__init__(msg)
        self.code = code


def card_of(fleet: dict, card: str) -> dict:
    c = fleet["cards"].get(card)
    if not c:
        raise Refused(f"unknown card {card!r}; cards: {', '.join(sorted(fleet['cards']))}", USAGE)
    return c


def host_budget(fleet: dict, host: str, claims: dict, add: dict | None = None) -> list:
    """The host-level arithmetic, as lines. Raises Refused when the budget does not hold.

    claims: live claims {card: claim}; add: a new claim being checked (its caps counted in)."""
    h = fleet["hosts"][host]
    b = h.get("budget", {})
    on_host = [(c, v) for c, v in claims.items() if fleet["cards"].get(c, {}).get("host") == host]
    if add is not None:
        on_host.append((add["card"], add))
    caps = [(c, cap_mb(v["peak_ram_mb"], v.get("grows", False), fleet)) for c, v in on_host]
    lines = []
    form = h.get("launch_form")
    if any(v.get("solo") for _, v in on_host) and len(on_host) > 1:
        solo = [c for c, v in on_host if v.get("solo")]
        raise Refused(f"{host}: {', '.join(solo)} holds a SOLO claim (an unmeasured peak runs alone until measured)")
    if form == "remote":
        ram_mib = h["ram_mb"]
        lim = ram_mib - b.get("top_reserve_mib", 512)
        need = sum(m for _, m in caps) + b.get("os_reserve_mib", 1024) + b.get("overlap_mib", 512)
        lines.append(f"{host} pair rule: caps {' + '.join(f'{m} ({c})' for c, m in caps) or '0'}"
                     f" + {b.get('os_reserve_mib', 1024)} OS + {b.get('overlap_mib', 512)} overlap = {need} MB"
                     f" <= {ram_mib} - {b.get('top_reserve_mib', 512)} = {lim} MB")
        if need > lim:
            raise Refused(lines[-1].replace("<=", ">") + " (FAMILIAR-RULES rule 7)")
    elif form == "guest":
        tot = sum(m for _, m in caps)
        gtot = sum(v.get("peak_vram_mib", 0) for _, v in on_host)
        lines.append(f"{host} guest budget: RAM caps {tot} MB <= {b['guest_ram_mb']} MB; "
                     f"GPU {gtot} MiB <= {b['guest_gpu_mib']} MiB")
        if tot > b["guest_ram_mb"]:
            raise Refused(f"{host} guest budget: RAM caps {tot} MB > {b['guest_ram_mb']} MB (the sum of every guest "
                          f"scope, not each job alone: reverie's 6G + 8G + 4G stack, 2026-09-28 23:53)")
        if gtot > b["guest_gpu_mib"]:
            raise Refused(f"{host} guest budget: GPU {gtot} MiB > {b['guest_gpu_mib']} MiB")
    elif form == "familiar":
        heavy = [c for c, m in caps if m >= 1024]
        mx = b.get("max_heavy_jobs", 1)
        lines.append(f"{host}: heavy jobs {len(heavy)} <= {mx} (rule 2: one heavy job at a time)")
        if len(heavy) > mx:
            raise Refused(f"{host}: {len(heavy)} heavy claims > {mx} ({', '.join(heavy)}): one heavy job at a time (rule 2)")
    return lines


def check_claim(fleet: dict, claims: dict, new: dict, windows: dict, t: float, vulkan: bool = False) -> list:
    """Every static check a new claim must pass; returns the arithmetic lines, or raises Refused."""
    c = card_of(fleet, new["card"])
    lines = []
    if not c.get("compute_ok", True) and not vulkan:
        raise Refused(f"{new['card']} ({c['model']}) cannot run compute: {c.get('blocked_by', 'compute_ok is false')}."
                      f" Pass --vulkan for a Vulkan-only job.")
    held = claims.get(new["card"])
    if held and held.get("lane") != new["lane"]:
        raise Refused(f"{new['card']} is held by {held['lane']} until {fmt_t(held['until'])} ({held.get('purpose', '')})")
    if new.get("estimate") and not new.get("solo"):
        raise Refused("an estimated peak needs --solo: an unmeasured job runs alone on its host until measured "
                      "(FAMILIAR-RULES rule 7: '46 bands: unmeasured; run it solo first')", USAGE)
    spec = windows.get(new["card"], {}).get("spec", "always")
    if not window_open(spec, t):
        raise Refused(f"{new['card']}'s window is {spec!r} and it is closed now")
    margin = fleet.get("defaults", {}).get("vram_margin_mib", 1024)
    vr = new.get("peak_vram_mib", 0)
    res = resident_vram(c)
    room = c["vram_mib"] - margin - res
    lines.append(f"{new['card']} VRAM: {vr} MiB <= {c['vram_mib']} - {margin} margin"
                 + (f" - {res} resident services" if res else "") + f" = {room} MiB")
    if vr > room:
        raise Refused(lines[-1].replace("<=", ">"))
    others = {k: v for k, v in claims.items() if k != new["card"]}
    lines += host_budget(fleet, c["host"], others, add=new)
    return lines


# ── verbs: claim / release / window / admit ───────────────────────────────────────────────────────

def cmd_claim(a, fleet, cfg) -> int:
    me = caller()
    if not is_granter(me, cfg):
        raise Refused(f"only a granter (the orchestrator, or {', '.join(granters(cfg))}) claims cards; "
                      f"ask your lead: SendMessage \"please claim {a.card} for {lane_of(me)} ...\"", NOPERM)
    t = now()
    new = {"card": a.card, "lane": a.lane, "purpose": a.purpose or "", "since": t, "until": parse_until(a.until, t),
           "peak_ram_mb": parse_mb(a.peak_ram), "peak_vram_mib": parse_mb(a.peak_vram), "grows": a.grows,
           "protected": a.protected, "estimate": a.estimate, "solo": a.solo, "by": lane_of(me) or "orchestrator",
           "jobs": []}
    with Ledger(write=not a.dry_run) as L:
        lines = check_claim(fleet, L.live_claims(t), new, L.data["windows"], t, vulkan=a.vulkan)
        new["cap_mb"] = cap_mb(new["peak_ram_mb"], new["grows"], fleet)
        for ln in lines:
            print("  " + ln)
        if a.dry_run:
            print(f"DRY-RUN: would claim {a.card} for {a.lane} until {fmt_t(new['until'])}, cap {new['cap_mb']} MB")
            return 0
        L.data["claims"][a.card] = new
        L.log("claim", card=a.card, lane=a.lane, by=new["by"], until=new["until"])
    print(f"claimed {a.card} for {a.lane} until {fmt_t(new['until'])}: peak {new['peak_ram_mb']} MB RAM "
          f"(cap {new['cap_mb']} MB{', grows x1.5' if a.grows else ''}), {new['peak_vram_mib']} MiB VRAM")
    return 0


def _job_alive(job: dict) -> bool:
    """A recorded job is alive while its pid answers on its host (best effort; unknown = alive)."""
    host, pid = job.get("host"), job.get("pid")
    if not pid:
        return False
    try:
        rc = _ssh(host, f"kill -0 {int(pid)} 2>/dev/null", timeout=8).returncode
    except Exception:  # noqa: BLE001: unreachable reads as alive, the safe side for release
        return True
    return rc == 0


def cmd_release(a, fleet, cfg) -> int:
    me = caller()
    t = now()
    with Ledger(write=not a.dry_run) as L:
        cl = L.data["claims"].get(a.card)
        if not cl:
            print(f"{a.card} holds no claim")
            return 0
        if not is_granter(me, cfg) and lane_of(me) != cl.get("lane"):
            raise Refused(f"only a granter or the holder ({cl['lane']}) releases {a.card}", NOPERM)
        live = [j for j in cl.get("jobs", []) if _job_alive(j)]
        if live and not a.force:
            raise Refused(f"{a.card}: {len(live)} job(s) of this claim still run ({', '.join(str(j.get('pid')) for j in live)});"
                          f" stop them or pass --force")
        if a.dry_run:
            print(f"DRY-RUN: would release {a.card} ({cl['lane']})")
            return 0
        cl["released"] = t
        L.log("release", card=a.card, lane=cl["lane"], by=lane_of(me) or "orchestrator", forced=bool(a.force and live))
        del L.data["claims"][a.card]
    print(f"released {a.card} ({cl['lane']})")
    return 0


def cmd_window(a, fleet, cfg) -> int:
    me = caller()
    if not is_granter(me, cfg):
        raise Refused("only a granter sets windows", NOPERM)
    card_of(fleet, a.card)
    window_open(a.spec, now())  # validates the spec
    with Ledger(write=not a.dry_run) as L:
        if a.dry_run:
            print(f"DRY-RUN: would set {a.card} window {a.spec!r}")
            return 0
        L.data["windows"][a.card] = {"spec": a.spec.lower(), "note": a.note or "", "by": lane_of(me) or "orchestrator",
                                     "ts": now()}
        L.log("window", card=a.card, spec=a.spec.lower())
    print(f"{a.card} window: {a.spec.lower()} (open now: {window_open(a.spec, now())})")
    return 0


def _peaks_for_run(a, claim: dict, fleet: dict) -> tuple:
    peak = parse_mb(a.peak_ram) if a.peak_ram else claim["peak_ram_mb"]
    grows = bool(a.grows or claim.get("grows"))
    return peak, grows, cap_mb(peak, grows, fleet)


def _authorize_run(a, fleet, cfg, L, t) -> dict:
    me = caller()
    claim = L.live_claims(t).get(a.card)
    if not claim:
        raise Refused(f"{a.card} holds no live claim: a granter claims it first "
                      f"(dreamteam gpu claim {a.card} --lane <lane> --until … --peak-ram … --peak-vram …)", NOPERM)
    if me and lane_of(me) != claim["lane"]:
        raise Refused(f"{a.card} is held by {claim['lane']}, not {lane_of(me)}", NOPERM)
    spec = L.data["windows"].get(a.card, {}).get("spec", "always")
    if not window_open(spec, t):
        raise Refused(f"{a.card}'s window is {spec!r} and it is closed now")
    return claim


def live_vram_check(fleet: dict, card: str, peak_vram_mib: int) -> str:
    """Refuse when the card's LIVE free VRAM cannot hold the claim's peak + margin (another process, e.g.
    llama-server on familiar:0, may already hold it). An unreadable card (no nvidia-smi, asleep) passes with
    a note: the claim's static check still ran, and the launcher's preflight is next."""
    c = fleet["cards"][card]
    if not c.get("caps", {}).get("cuda"):
        return f"{card}: live VRAM not readable for {c['arch']} (no nvidia-smi); static check only"
    p = probe(fleet, c["host"])
    g = p.get("gpus", {}).get(c["index"]) if p.get("reachable") else None
    if not g:
        return f"{card}: live VRAM unreadable ({'asleep' if not p.get('reachable') else 'no nvidia-smi row'}); static check only"
    margin = fleet.get("defaults", {}).get("vram_margin_mib", 1024)
    free = g["total_mib"] - g["used_mib"]
    line = f"{card} live VRAM: free {free} MiB >= peak {peak_vram_mib} + {margin} margin"
    if free < peak_vram_mib + margin:
        holders = "; ".join(f"{x['pid']} {x['used_mib']}MiB {os.path.basename(x['name'])}"
                            for x in p.get("apps", []) if x.get("index") == c["index"])
        raise Refused(line.replace(">=", "<") + (f" (in use: {holders})" if holders else ""))
    return line


def cmd_admit(a, fleet, cfg) -> int:
    t = now()
    with Ledger() as L:
        claim = _authorize_run(a, fleet, cfg, L, t)
        peak, grows, cap = _peaks_for_run(a, claim, fleet)
        print(f"  cap: peak {peak} MB x {'1.5 (grows)' if grows else '1.2'} = {cap} MB")
        print("  " + live_vram_check(fleet, a.card, claim.get("peak_vram_mib", 0)))
        if a.peak_ram and peak > claim["peak_ram_mb"]:
            others = {k: v for k, v in L.live_claims(t).items() if k != a.card}
            for ln in host_budget(fleet, fleet["cards"][a.card]["host"], others,
                                  add={**claim, "peak_ram_mb": peak, "grows": grows}):
                print("  " + ln)
    print(f"ADMITTED (static): {a.card} for {claim['lane']}, cap {cap} MB. The launcher re-checks live memory on the host.")
    return 0


# ── the board ─────────────────────────────────────────────────────────────────────────────────────

PROBE = r"""
nvidia-smi --query-gpu=index,pci.bus_id,memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits 2>/dev/null | sed 's/^/GPU,/'
nvidia-smi --query-compute-apps=gpu_bus_id,pid,used_memory,process_name --format=csv,noheader,nounits 2>/dev/null | sed 's/^/APP,/'
awk '/MemAvailable/{a=$2}/SwapTotal/{t=$2}/SwapFree/{f=$2}END{print "MEM,"a","t","f}' /proc/meminfo
for p in __PATHS__; do printf 'DISK,%s,%s\n' "$p" "$(df -BG --output=avail "$p" 2>/dev/null | tail -1 | tr -dc 0-9)"; done
if [ -n "__PAUSE__" ] && [ -e "__PAUSE__" ]; then echo PAUSE,1; else echo PAUSE,0; fi
"""


def local_host() -> str:
    return os.environ.get("DREAMTEAM_GPU_LOCAL_HOST") or socket.gethostname().split(".")[0]


def _ssh(host: str, script: str, timeout: float = 12):
    if host == local_host() and not os.environ.get("DREAMTEAM_GPU_SSH"):   # a stubbed ssh serves tests for every host
        return subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=timeout)
    ssh = os.environ.get("DREAMTEAM_GPU_SSH", "ssh")
    return subprocess.run([ssh, "-o", "ConnectTimeout=5", "-o", "BatchMode=yes", host, script],
                          capture_output=True, text=True, timeout=timeout)


def probe(fleet: dict, host: str) -> dict:
    h = fleet["hosts"][host]
    paths = " ".join(shlex.quote(f["path"]) for f in h.get("disk_floors", [])) or "/"
    pause = (h.get("pause_file") or "").replace("~", "$HOME")
    script = PROBE.replace("__PATHS__", paths).replace("__PAUSE__", pause)
    try:
        r = _ssh(host, script)
    except subprocess.TimeoutExpired:
        return {"host": host, "reachable": False}
    if r.returncode == 255 or (not r.stdout.strip() and r.returncode != 0):
        return {"host": host, "reachable": False}
    out = {"host": host, "reachable": True, "gpus": {}, "apps": [], "disk": {}, "pause": False}
    bus_to_idx = {}
    for line in r.stdout.splitlines():
        parts = [p.strip() for p in line.split(",")]
        if parts[0] == "GPU" and len(parts) >= 6:
            bus_to_idx[parts[2].lower()] = int(parts[1])
            out["gpus"][int(parts[1])] = {"used_mib": int(parts[3]), "total_mib": int(parts[4]), "util": parts[5]}
        elif parts[0] == "APP" and len(parts) >= 5:
            out["apps"].append({"bus": parts[1].lower(), "pid": parts[2], "used_mib": parts[3], "name": parts[4]})
        elif parts[0] == "MEM" and len(parts) >= 4 and parts[1]:
            a, tot, free = (int(x or 0) for x in parts[1:4])
            out["avail_mb"] = a // 1024
            out["swap_pct"] = int(100 * (tot - free) / tot) if tot else 0
        elif parts[0] == "DISK" and len(parts) >= 3:
            out["disk"][parts[1]] = int(parts[2]) if parts[2].isdigit() else None
        elif parts[0] == "PAUSE":
            out["pause"] = parts[1] == "1"
    for app in out["apps"]:
        app["index"] = bus_to_idx.get(app["bus"])
    return out


DESKTOP_APPS = re.compile(r"(gnome|xorg|xwayland|xdg-|mutter|kwin|plasmashell|firefox|chrom|code|electron|ghostty|"
                          r"kitty|alacritty|obs|gsd-|evolution|nautilus|totem|thunderbird|slack|discord|spotify|"
                          r"crashpad|renderD\d+)", re.I)   # the full name: Chromium/Electron GPU procs report their args


def unclaimed_use(apps: list, residents: list | None = None) -> list:
    """Compute processes that look like jobs (not the desktop, not a known resident service) holding >= 256 MiB."""
    pats = [re.compile(r["match"]) for r in (residents or []) if r.get("match")]
    out = []
    for x in apps:
        with contextlib.suppress(ValueError):
            if (int(x["used_mib"]) >= 256 and not DESKTOP_APPS.search(x["name"])
                    and not any(pt.search(x["name"]) for pt in pats)):
                out.append(x)
    return out


def resident_vram(card: dict) -> int:
    return sum(int(r.get("vram_mib", 0)) for r in card.get("residents", []))


def board_data(fleet: dict) -> dict:
    t = now()
    with Ledger() as L:
        claims, windows = L.live_claims(t), dict(L.data["windows"])
    with ThreadPoolExecutor(max_workers=len(fleet["hosts"])) as ex:
        probes = dict(zip(fleet["hosts"], ex.map(lambda h: probe(fleet, h), fleet["hosts"])))
    cards = []
    for cid, c in fleet["cards"].items():
        p = probes.get(c["host"], {})
        live = p.get("gpus", {}).get(c["index"]) if c.get("caps", {}).get("cuda") else None
        cl = claims.get(cid)
        spec = windows.get(cid, {}).get("spec", "always")
        cards.append({
            "card": cid, "model": c["model"], "vram_mib": c["vram_mib"], "compute_ok": c.get("compute_ok", True),
            "holder": cl["lane"] if cl else None, "until": cl["until"] if cl else None,
            "purpose": cl.get("purpose") if cl else None,
            "cap_mb": cap_mb(cl["peak_ram_mb"], cl.get("grows", False), fleet) if cl else None,
            "window": spec, "window_open": window_open(spec, t),
            "used_mib": live["used_mib"] if live else None,
            "apps": [x for x in p.get("apps", []) if x.get("index") == c["index"]] if live else [],
            "host_reachable": p.get("reachable", False)})
        cards[-1]["unclaimed_use"] = [] if cl else unclaimed_use(cards[-1]["apps"], c.get("residents"))
        cards[-1]["resident_mib"] = resident_vram(c)
    hosts = {h: {k: v for k, v in p.items() if k in ("reachable", "avail_mb", "swap_pct", "disk", "pause")}
             for h, p in probes.items()}
    return {"ts": t, "cards": cards, "hosts": hosts}


def cmd_board(a, fleet, cfg) -> int:
    d = board_data(fleet)
    if a.json:
        print(json.dumps(d, indent=1, sort_keys=True))
        return 0
    print(f"GPU fleet, {fmt_t(d['ts'])} (guard: {guard_mode(cfg)})")
    for c in d["cards"]:
        state = "asleep" if not c["host_reachable"] else (f"{c['used_mib']}/{c['vram_mib']} MiB" if c["used_mib"] is not None
                                                           else ("compute blocked" if not c["compute_ok"] else "-"))
        who = (f"{c['holder']} until {fmt_t(c['until'])} (cap {c['cap_mb']} MB)" if c["holder"]
               else ("IN USE, NO CLAIM" if c.get("unclaimed_use") else "free"))
        win = "" if c["window"] == "always" else f"  window {c['window']} ({'open' if c['window_open'] else 'closed'})"
        apps = sorted(c["apps"], key=lambda x: -int(x["used_mib"]) if str(x["used_mib"]).isdigit() else 0)
        jobs = "; ".join(f"{x['pid']} {x['used_mib']}MiB {os.path.basename(x['name'])}" for x in apps[:3])
        if len(apps) > 3:
            jobs += f"; +{len(apps) - 3} more"
        print(f"  {c['card']:<14} {c['model'][:26]:<26} {state:<18} {who}{win}" + (f"  [{jobs}]" if jobs else ""))
    for h, s in d["hosts"].items():
        if not s.get("reachable"):
            print(f"  {h:<9} asleep or unreachable (the board never wakes a host)")
            continue
        disk = " ".join(f"{p} {g}G" for p, g in s.get("disk", {}).items())
        print(f"  {h:<9} RAM available {s.get('avail_mb', '?')} MB · swap {s.get('swap_pct', '?')}% · {disk}"
              f"{' · PAUSED' if s.get('pause') else ''}")
    return 0


def cmd_inventory(a, fleet, cfg) -> int:
    if a.check:
        p = probe(fleet, a.check)
        if not p.get("reachable"):
            print(f"{a.check}: unreachable (asleep?); not woken")
            return 3
        drift = 0
        for cid, c in fleet["cards"].items():
            if c["host"] != a.check or not c.get("caps", {}).get("cuda"):
                continue
            live = p["gpus"].get(c["index"])
            if not live or live["total_mib"] != c["vram_mib"]:
                drift += 1
                print(f"DRIFT {cid}: fleet.json says {c['vram_mib']} MiB, measured {live and live['total_mib']}")
        print(f"{a.check}: {'no drift' if not drift else f'{drift} drift(s)'} (cards checked against nvidia-smi)")
        return 1 if drift else 0
    if a.json:
        print(json.dumps(fleet, indent=1))
        return 0
    for cid, c in fleet["cards"].items():
        caps = ", ".join(k for k, v in c.get("caps", {}).items() if v is True) + f", fp16 {c['caps'].get('fp16')}"
        print(f"{cid:<14} {c['model']:<28} {c['vram_mib']:>6} MiB  {c['arch']:<10} cc {c.get('compute_cap') or '-':<4} "
              f"{caps}{'' if c.get('compute_ok', True) else '  [COMPUTE BLOCKED]'}")
    return 0


# ── run: the single launcher ──────────────────────────────────────────────────────────────────────

def _script(name: str) -> str:
    return os.path.join(ROOT, "scripts", "gpu", name)


def _install(host: str, name: str) -> str:
    """Copy a launcher to ~/.local/lib/dreamteam-gpu/<name>.<sha8> on a remote host (content-addressed,
    so a running copy is never overwritten) and verify it. Returns the remote path."""
    path = _script(name)
    with open(path, "rb") as f:
        body = f.read()
    sha = hashlib.sha256(body).hexdigest()
    dest = f"$HOME/.local/lib/dreamteam-gpu/{name}.{sha[:8]}"
    ssh = os.environ.get("DREAMTEAM_GPU_SSH", "ssh")
    cmd = (f"mkdir -p $HOME/.local/lib/dreamteam-gpu && f={dest} && "
           f"{{ [ -f \"$f\" ] || cat > \"$f.part\" && mv \"$f.part\" \"$f\"; }} && "
           f"echo \"$(sha256sum \"$f\" | cut -d' ' -f1) $f\"")
    r = subprocess.run([ssh, "-o", "ConnectTimeout=5", "-o", "BatchMode=yes", host, cmd], input=body,
                       capture_output=True, timeout=30)
    got = r.stdout.decode().split()
    if r.returncode != 0 or not got or got[0] != sha:
        raise Refused(f"could not install {name} on {host} (checksum {got[:1]} != {sha[:12]}): {r.stderr.decode()[:200]}", 5)
    return got[1]


def build_launch(a, fleet: dict, claim: dict) -> tuple:
    """(host, argv-or-remote-string, human description). Pure: no side effects (tested)."""
    c = fleet["cards"][a.card]
    host, h = c["host"], fleet["hosts"][c["host"]]
    peak, grows, cap = _peaks_for_run(a, claim, fleet)
    form = h["launch_form"]
    name = a.name or f"{claim['lane']}-{int(now())}"
    log = a.log or f"$HOME/.cache/dreamteam-gpu/{name}.log"
    cmd = " ".join(shlex.quote(x) for x in a.cmd)
    if form == "familiar":
        b = h.get("budget", {})
        env = (f"GPU_REGEN_HEADROOM_MB={b.get('regenerable_headroom_mb', 2048)} "
               f"GPU_PROT_MIN_AVAIL_MB={b.get('protected_min_available_mb', 6144)} "
               f"GPU_PROT_MAX_SWAP_PCT={b.get('protected_max_swap_pct', 50)} "
               f"GPU_ONE_HEAVY={1 if b.get('max_heavy_jobs', 1) == 1 else 0} "
               f"GPU_HEAVY_PATHS={shlex.quote(b.get('heavy_paths', 'fwork/gems|/archive/gems/'))} "
               f"CUDA_VISIBLE_DEVICES={c['index']}")
        launcher = "safe_run.sh"
        args = f"{'--protected ' if (a.protected or claim.get('protected')) else ''}{cap}M {cmd}"
    elif form == "guest":
        b = h["budget"]
        gpu_mem = a.gpu_mem if a.gpu_mem is not None else claim.get("peak_vram_mib", 0) / 1024
        floor = next((f["min_free_gb"] for f in h.get("disk_floors", []) if f["path"] == "/"), 0)
        env = (f"GUEST_MAX_MEM_MB={b['guest_ram_mb']} GUEST_MAX_GPU_MIB={b['guest_gpu_mib']} "
               f"GUEST_HEADROOM_MB={b['headroom_mb']} GUEST_ROOT_MIN_GB={floor} "
               f"GUEST_PAUSE={shlex.quote((h.get('pause_file') or '~/.gems-pause').replace('~', '$HOME'))} "
               f"CUDA_VISIBLE_DEVICES={c['index']}")
        launcher = "guest_run.sh"
        args = f"--mem {cap}M --gpu-mem {gpu_mem:.2f} --disk-need {a.disk_need or 0} -- {cmd}"
    elif form == "remote":
        env = ""
        launcher = "remote_run.sh"
        args = f"--gpu {c['index']} --cap {cap}M --name {shlex.quote(name)} --log {log} -- {cmd}"
    else:
        raise Refused(f"{host}: unknown launch_form {form!r}", USAGE)
    return host, launcher, env, args, log, cap


def cmd_run(a, fleet, cfg) -> int:
    if not a.cmd:
        raise Refused("usage: dreamteam gpu run --card <host:idx> [options] -- CMD...", USAGE)
    t = now()
    with Ledger() as L:
        claim = _authorize_run(a, fleet, cfg, L, t)
        if not fleet["cards"][a.card].get("compute_ok", True) and not a.vulkan:
            raise Refused(f"{a.card} cannot run compute: {fleet['cards'][a.card].get('blocked_by')}")
        peak, grows, cap = _peaks_for_run(a, claim, fleet)
        if peak > claim["peak_ram_mb"]:
            others = {k: v for k, v in L.live_claims(t).items() if k != a.card}
            host_budget(fleet, fleet["cards"][a.card]["host"], others, add={**claim, "peak_ram_mb": peak, "grows": grows})
    vram_line = live_vram_check(fleet, a.card, claim.get("peak_vram_mib", 0))
    host, launcher, env, args, log, cap = build_launch(a, fleet, claim)
    detach = host != local_host() or a.detach
    if a.dry_run:
        where = "locally" if host == local_host() else f"on {host} (installed, checksum-verified)"
        print(f"DRY-RUN: {a.card} for {claim['lane']}, cap {cap} MB, {launcher} {where}")
        print(f"  {vram_line}")
        print(f"  {env} bash <{launcher}> {args}" + (f"  (detached; log {log})" if detach else ""))
        return 0
    if host == local_host():
        path = _script(launcher)
        full = f"{env} bash {shlex.quote(path)} {args}"
        if not detach:
            return subprocess.call(["bash", "-c", full])
        remote = f"mkdir -p \"$(dirname {log})\"; {full} > {log} 2>&1 < /dev/null & echo $!"
        r = subprocess.run(["bash", "-c", f"setsid bash -c {shlex.quote(remote)}"], capture_output=True, text=True)
    else:
        path = _install(host, launcher)
        if launcher == "remote_run.sh":  # it detaches its own job and exits
            remote = f"{env} bash {path} {args}"
        else:
            remote = (f"mkdir -p \"$(dirname {log})\"; setsid nohup bash -c {shlex.quote(f'{env} bash {path} {args}')} "
                      f"> {log} 2>&1 < /dev/null & echo $!")
        r = _ssh(host, remote, timeout=60)
    sys.stdout.write(r.stdout)
    sys.stderr.write(r.stderr)
    if r.returncode != 0:
        return r.returncode
    pid = (re.findall(r"\b(\d+)\s*$", r.stdout.strip()) or [None])[-1]
    with Ledger(write=True) as L:
        cl = L.data["claims"].get(a.card)
        if cl:
            cl.setdefault("jobs", []).append({"host": host, "pid": pid, "log": log, "cap_mb": cap, "started": now(),
                                              "cmd": " ".join(a.cmd)[:300]})
            L.log("run", card=a.card, lane=cl["lane"], pid=pid, cap_mb=cap)
    print(f"launched on {a.card} ({host}) for {claim['lane']}: pid {pid}, cap {cap} MB, log {log}")
    return 0


# ── the guard's decision ──────────────────────────────────────────────────────────────────────────

SSH_OPTS_WITH_ARG = set("-B -b -c -D -E -e -F -I -i -J -L -l -m -O -o -p -Q -R -S -W -w".split())
LAUNCHERS = {"gpu1_launch.sh", "run_exp.sh", "remote_run.sh", "guest_run.sh", "safe_run.sh"}
GPU_ONLY_HOSTS_DEFAULT = ("gpu0", "gpu1", "game")
PY_LAUNCH = re.compile(r"(^|[\s;&|(/])(python3?|torchrun|accelerate|ollama\s+run)\b")


def _host_alias(tok: str, fleet: dict) -> str | None:
    h = tok.split("@", 1)[-1].lower()
    for suffix in (".lan", ".jphe.in", ".realm.watch"):
        if h.endswith(suffix):
            h = h[: -len(suffix)]
    return h if h in fleet["hosts"] else None


def _tokens(cmd: str) -> list:
    try:
        return shlex.split(cmd, posix=True)
    except ValueError:
        return cmd.split()


def _ssh_target(toks: list, fleet: dict):
    """(present, host, remote_command) for the first ssh in the command. present=False: no ssh at all.
    host=None with present=True: an ssh whose target does not resolve (a variable, an unknown name)."""
    for i, tok in enumerate(toks):
        if os.path.basename(tok) != "ssh":
            continue
        j = i + 1
        while j < len(toks) and toks[j].startswith("-"):
            j += 2 if toks[j] in SSH_OPTS_WITH_ARG else 1
        if j < len(toks):
            return True, _host_alias(toks[j], fleet), " ".join(toks[j + 1:])
        return True, None, ""
    return False, None, None


def detect(cmd: str, fleet: dict) -> dict:
    """Which cards a Bash command launches GPU work on.
    Returns {"launch", "via_run", "cards", "host_any", "why"}: host_any lists hosts where the command runs GPU
    work on an unnamed card (a lane must hold at least one card there)."""
    out = {"launch": False, "via_run": False, "cards": [], "host_any": [], "why": ""}
    flat = " ".join(cmd.split())
    if re.search(r"(^|[\s;&|(])(dreamteam\s+gpu|(\S*/)?scripts/gpu\.sh)\s+run\b", flat):
        out.update(launch=True, via_run=True, why="dreamteam gpu run (checked inside run)")
        return out
    toks = _tokens(cmd)
    has_ssh, ssh_host, remote = _ssh_target(toks, fleet)
    body = remote if has_ssh else flat
    btoks = _tokens(body or "")
    names = {os.path.basename(t) for t in btoks} | {os.path.basename(t) for t in toks}
    host = ssh_host if has_ssh else local_host()
    idx, prefix, why = None, "", ""
    m = re.search(r"\b(CUDA_VISIBLE_DEVICES|ZE_AFFINITY_MASK)=['\"]?([0-9][0-9,]*)", body or "")
    if m:
        idx = [int(x) for x in m.group(2).split(",") if x]
        prefix, why = ("xpu" if m.group(1) == "ZE_AFFINITY_MASK" else ""), f"{m.group(1)}={m.group(2)}"
    m2 = re.search(r"--device[= ]+(cuda|xpu):(\d+)", body or "")
    if m2 and idx is None:
        idx, prefix = [int(m2.group(2))], ("xpu" if m2.group(1) == "xpu" else "")
        why = f"--device {m2.group(1)}:{m2.group(2)}"
    if "gpu1_launch.sh" in names:
        mh = re.search(r"\bHOST=(\w+)", flat)
        host = _host_alias(mh.group(1), fleet) if mh else "gpu1"   # gpu1_launch does its own ssh
        allt = _tokens(flat)
        k = next((i for i, t in enumerate(allt) if t.endswith("gpu1_launch.sh")), None)
        if k is not None and k + 1 < len(allt) and allt[k + 1].isdigit():
            idx, prefix = [int(allt[k + 1])], ""
        why = "gpu1_launch.sh"
    elif "guest_run.sh" in names:
        mg = re.search(r"--gpu-mem[= ]+([0-9.]+)", body or "")
        if not (mg and float(mg.group(1)) == 0):
            why = why or "guest_run.sh (a GPU cap)"
        elif idx is None:
            why = ""   # --gpu-mem 0: a CPU-only guest job
    elif "safe_run.sh" in names and re.search(r"(^|\s)--protected(\s|$)", body or ""):
        why = why or "safe_run.sh --protected (a training run)"
    elif names & {"run_exp.sh", "remote_run.sh"}:
        why = why or ", ".join(sorted(names & {"run_exp.sh", "remote_run.sh"}))
    if not why and has_ssh and ssh_host in GPU_ONLY_HOSTS_DEFAULT and PY_LAUNCH.search(remote or ""):
        why = f"python on {ssh_host} over ssh"
    if not why:
        return out
    out["why"] = why
    if host is None or host not in fleet["hosts"]:
        out["why"] += " (host unresolved: fail open)"
        return out   # an ssh to a variable or unknown host cannot be attributed; never blame the wrong card
    out["launch"] = True
    host_cards = [cid for cid, c in fleet["cards"].items() if c["host"] == host]
    usable = [c for c in host_cards if fleet["cards"][c].get("compute_ok", True)]
    if idx is not None:
        want = [f"{host}:{prefix}{i}" for i in idx]
        out["cards"] = want
    elif len(usable) == 1:
        out["cards"] = usable
    elif len(host_cards) == 1:
        out["cards"] = host_cards
    else:
        out["host_any"] = [host]
    return out


def decide(cmd: str, fleet: dict, cfg: dict, agent_id: str, t: float) -> dict:
    mode = guard_mode(cfg)
    d = detect(cmd, fleet)
    res = {"action": "allow", "mode": mode, **d, "message": ""}
    if mode == "off" or not d["launch"] or d["via_run"] or not agent_id or "@" not in agent_id:
        return res  # not a launch, checked inside run, or an orchestrator/unknown identity (fail open)
    lane = lane_of(agent_id)
    with Ledger() as L:
        live = L.live_claims(t)
    held = {c for c, v in live.items() if v.get("lane") == lane}
    missing = [c for c in d["cards"] if c not in held]
    for host in d["host_any"]:
        if not any(fleet["cards"].get(c, {}).get("host") == host for c in held):
            missing.append(f"{host}:<any card>")
    if not missing:
        return res
    who = "; ".join(f"{c} held by {live[c]['lane']} until {fmt_t(live[c]['until'])}" for c in missing if c in live)
    msg = (f"GPU launch without a claim: {lane} does not hold {', '.join(missing)} ({d['why']})."
           + (f" {who}." if who else "")
           + f" Ask your lead (SendMessage): 'please claim {missing[0]} for {lane} --until … --peak-ram <measured MB>"
             f" --peak-vram <MiB>'. Then launch with `dreamteam gpu run --card {missing[0]} -- CMD`.")
    res.update(action="block" if mode == "enforce" else "warn", message=msg)
    return res


def cmd_guard(a, fleet, cfg) -> int:
    """Read the PreToolUse payload on stdin; print the decision as JSON; log warns and blocks."""
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        print(json.dumps({"action": "allow", "message": "unparseable payload (fail open)"}))
        return 0
    command = (payload.get("tool_input") or {}).get("command") or ""
    res = decide(command, fleet, cfg, caller(), now())
    if res["action"] != "allow":
        with contextlib.suppress(OSError):
            os.makedirs(state_dir(), exist_ok=True)
            with open(os.path.join(state_dir(), "guard.log"), "a") as f:
                f.write(json.dumps({"ts": now(), "agent": caller(), "action": res["action"], "cards": res["cards"],
                                    "host_any": res["host_any"], "why": res["why"], "cmd": command[:400]}) + "\n")
    print(json.dumps(res))
    return 0


def cmd_detect(a, fleet, cfg) -> int:
    print(json.dumps(detect(" ".join(a.command), fleet), indent=1))
    return 0


# ── CLI ───────────────────────────────────────────────────────────────────────────────────────────

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="dreamteam gpu", description="The GPU fleet: board, claims, windows, one launcher.")
    sub = ap.add_subparsers(dest="verb", required=True)
    p = sub.add_parser("board", help="who holds which card, windows, live VRAM and host memory")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_board)
    p = sub.add_parser("inventory", help="the cards and their capabilities (--check HOST re-measures)")
    p.add_argument("--json", action="store_true")
    p.add_argument("--check", metavar="HOST")
    p.set_defaults(fn=cmd_inventory)
    p = sub.add_parser("claim", help="(granters) give a lane a card until a time, with its measured peaks")
    p.add_argument("card")
    p.add_argument("--lane", required=True)
    p.add_argument("--until", required=True)
    p.add_argument("--peak-ram", required=True, help="measured peak host RAM, e.g. 2900M or 2.81G")
    p.add_argument("--peak-vram", required=True, help="measured peak VRAM, e.g. 3500M")
    p.add_argument("--purpose", default="")
    p.add_argument("--grows", action="store_true", help="memory grows with run length: cap x1.5")
    p.add_argument("--protected", action="store_true", help="a training run (familiar: -300, strict admission)")
    p.add_argument("--estimate", action="store_true", help="the peak is not measured yet (needs --solo)")
    p.add_argument("--solo", action="store_true", help="alone on its host until measured")
    p.add_argument("--vulkan", action="store_true", help="a Vulkan-only job on a compute-blocked card")
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(fn=cmd_claim)
    p = sub.add_parser("release", help="(granters or the holder) free a card")
    p.add_argument("card")
    p.add_argument("--force", action="store_true")
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(fn=cmd_release)
    p = sub.add_parser("window", help="(granters) when a card may be used: HH:MM-HH:MM, always, never")
    p.add_argument("card")
    p.add_argument("spec")
    p.add_argument("--note", default="")
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(fn=cmd_window)
    for verb, fn, hlp in (("admit", cmd_admit, "dry-run the admission for a run"),
                          ("run", cmd_run, "the single launcher: run CMD on a card you hold")):
        p = sub.add_parser(verb, help=hlp)
        p.add_argument("--card", required=True)
        p.add_argument("--peak-ram")
        p.add_argument("--grows", action="store_true")
        p.add_argument("--protected", action="store_true")
        p.add_argument("--gpu-mem", type=float, default=None, help="GiB of VRAM for the guest form's watchdog")
        p.add_argument("--disk-need", type=float, default=0)
        p.add_argument("--log")
        p.add_argument("--name")
        p.add_argument("--vulkan", action="store_true")
        p.add_argument("--detach", action="store_true")
        p.add_argument("--dry-run", action="store_true")
        p.add_argument("cmd", nargs=argparse.REMAINDER)
        p.set_defaults(fn=fn)
    p = sub.add_parser("guard", help="(the hook) read a PreToolUse payload on stdin, print the decision")
    p.set_defaults(fn=cmd_guard)
    p = sub.add_parser("detect", help="(debug) which cards a command would launch on")
    p.add_argument("command", nargs=argparse.REMAINDER)
    p.set_defaults(fn=cmd_detect)
    a = ap.parse_args(argv)
    if getattr(a, "cmd", None) and a.cmd[:1] == ["--"]:
        a.cmd = a.cmd[1:]
    try:
        return a.fn(a, load_fleet(), load_config())
    except Refused as e:
        print(f"REFUSED: {e}", file=sys.stderr)
        return e.code
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return USAGE


if __name__ == "__main__":
    sys.exit(main())
