#!/usr/bin/env bash
# dreamteam — listen.sh: mic → text seam so an agent can HEAR JP's spoken reply.
# Contract:  listen.sh [--mode streaming|vad|whisper|fixed] [--seconds N]
#                      [--lock-wait S] [-h]   →   recognized text on STDOUT
#
# The INPUT half of agent voice I/O; speak.sh is the OUTPUT half (#9/#17/#52). Wraps
# speech-to-cli's stt.stt(seconds, mode) — the SAME entry mcp_speech.py uses — via that
# repo's python, and prints the transcript to STDOUT (empty line = nothing heard). Use
# it when an agent is blocked on a decision and wants JP's spoken answer.
#
# ── ONE MIC — HARD SERIALIZATION ──────────────────────────────────────────────
# There is a SINGLE microphone on the host, shared by every dreamteam session and
# project. Concurrent listens would fight over it, so every listen is gated by a
# GLOBAL flock ($DREAMTEAM_MIC_LOCK, default ~/.claude/dreamteam-mic.lock). If the mic
# is busy this waits up to --lock-wait seconds (default 2) then GIVES UP with exit 3
# (MIC_BUSY) — it NEVER blocks a caller indefinitely. Listening is meant to be
# COORDINATOR/MANAGER-MEDIATED: Sandman/Hypnos initiates ONE listen and relays JP's
# answer to the blocked agent — NOT every agent grabbing the mic. The flock is the
# mechanism; mediation is the policy (see SKILL.md "Agent Voice I/O").
#
# ── GRACEFUL NO-OP (mirrors speak.sh's never-brick contract) ──────────────────
# Missing python / stt module / mic / Azure creds → empty stdout + a stderr diagnostic
# + exit 0. A voice seam must never brick the caller. "mic busy" (exit 3) is the ONLY
# distinguished non-zero, so a mediator can choose to retry; everything else is exit 0.
#
# ── SEAM (speech-to-cli side — NOT vendored here) ─────────────────────────────
# stt.stt(seconds=, mode=) → {"text": …}. Runs under speech-to-cli's python
# (.speech.sttPython → its venv → python3), from the CLI dir (.speech.cliDir →
# dirname of .speech.ttsPath → ~/Projects/speech-to-cli) so `import stt` resolves.
# STT is stdout-hygienic: the module's progress printing is redirected to stderr so
# STDOUT carries the transcript ALONE. Override the whole STT step with
# .speech.sttPath (a script taking "<mode> <seconds>", printing text) — the tests use
# this to run hermetically without a real mic.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CFG="${DREAMTEAM_CONFIG:-$ROOT/config.json}"

MODE=""; SECS=""; LOCKWAIT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mode)        MODE="${2:-}"; shift 2 2>/dev/null || shift ;;
    --mode=*)      MODE="${1#--mode=}"; shift ;;
    --seconds)     SECS="${2:-}"; shift 2 2>/dev/null || shift ;;
    --seconds=*)   SECS="${1#--seconds=}"; shift ;;
    --lock-wait)   LOCKWAIT="${2:-}"; shift 2 2>/dev/null || shift ;;
    --lock-wait=*) LOCKWAIT="${1#--lock-wait=}"; shift ;;
    -h|--help)     sed -n '2,20p' "$0"; exit 0 ;;
    *)             shift ;;
  esac
done

# Master mute (shared with speak.sh): speech.enabled=false silences BOTH directions.
[ "$(jq -r 'if .speech.enabled == false then "false" else "true" end' "$CFG" 2>/dev/null || echo true)" = "false" ] && exit 0

# Resolve mode: flag > config .speech.stt.mode > "" (empty = stt() auto-selects).
[ -z "$MODE" ] && MODE="$(jq -r '.speech.stt.mode // empty' "$CFG" 2>/dev/null || true)"
case "$MODE" in streaming|vad|whisper|fixed) ;; *) MODE="" ;; esac
# Resolve seconds: flag > config .speech.stt.seconds > 15. Positive-int guard
# (stt() itself clamps to 1..30). lock-wait: flag or 2s; non-negative int.
[ -z "$SECS" ] && SECS="$(jq -r '.speech.stt.seconds // empty' "$CFG" 2>/dev/null || true)"
case "$SECS" in ''|*[!0-9]*) SECS=15 ;; esac; [ "$SECS" -gt 0 ] 2>/dev/null || SECS=15
case "$LOCKWAIT" in ''|*[!0-9]*) LOCKWAIT=2 ;; esac

# STT step. .speech.sttPath override → run "<py> <sttPath> <mode> <seconds>" (tests
# inject a mic-less fake here); default → call stt.stt() in speech-to-cli via its python.
STT_PATH="$(jq -r '.speech.sttPath // empty' "$CFG" 2>/dev/null || true)"; STT_PATH="${STT_PATH/#\~/$HOME}"
CLI_DIR="$(jq -r '.speech.cliDir // empty' "$CFG" 2>/dev/null || true)"; CLI_DIR="${CLI_DIR/#\~/$HOME}"
if [ -z "$CLI_DIR" ]; then
  _tts="$(jq -r '.speech.ttsPath // empty' "$CFG" 2>/dev/null || true)"; _tts="${_tts/#\~/$HOME}"
  [ -n "$_tts" ] && CLI_DIR="$(dirname "$_tts")"
fi
[ -z "$CLI_DIR" ] && CLI_DIR="$HOME/Projects/speech-to-cli"

PY="$(jq -r '.speech.sttPython // empty' "$CFG" 2>/dev/null || true)"; PY="${PY/#\~/$HOME}"
if [ -z "$PY" ]; then
  if   [ -x "$CLI_DIR/venv/bin/python" ];  then PY="$CLI_DIR/venv/bin/python"
  elif [ -x "$CLI_DIR/.venv/bin/python" ]; then PY="$CLI_DIR/.venv/bin/python"
  else PY="$(command -v python3 2>/dev/null || true)"; fi
fi
[ -n "$PY" ] || { echo "listen: no python — no-op" >&2; exit 0; }

# Existence guards (graceful no-op, exit 0) BEFORE we ever grab the mic.
if [ -n "$STT_PATH" ]; then
  [ -f "$STT_PATH" ] || { echo "listen: sttPath not found ($STT_PATH) — no-op" >&2; exit 0; }
else
  [ -f "$CLI_DIR/stt.py" ] || { echo "listen: stt.py not found in $CLI_DIR — no-op" >&2; exit 0; }
fi

# ── acquire the ONE mic (global flock, bounded wait) ──────────────────────────
LOCK="${DREAMTEAM_MIC_LOCK:-$HOME/.claude/dreamteam-mic.lock}"
mkdir -p "$(dirname "$LOCK")" 2>/dev/null || true
exec 9>"$LOCK" 2>/dev/null || { echo "listen: cannot open mic lock — no-op" >&2; exit 0; }
if command -v flock >/dev/null 2>&1; then
  flock -w "$LOCKWAIT" 9 || { echo "listen: mic busy (>${LOCKWAIT}s) — mediator should retry" >&2; exit 3; }
fi
# fd 9 auto-closes on exit → lock released; no explicit unlock needed.

# ── capture ───────────────────────────────────────────────────────────────────
if [ -n "$STT_PATH" ]; then
  "$PY" "$STT_PATH" "$MODE" "$SECS" || true
else
  ( cd "$CLI_DIR" 2>/dev/null && "$PY" -c '
import sys
mode = sys.argv[1] or None
try:    secs = int(sys.argv[2])
except Exception: secs = 15
text = ""
_real = sys.stdout
sys.stdout = sys.stderr          # keep OUR stdout clean: stt progress goes to stderr
try:
    import stt
    r = stt.stt(seconds=secs, mode=mode)
    text = (r or {}).get("text", "") if isinstance(r, dict) else (r or "")
except Exception as e:
    sys.stderr.write("listen: stt unavailable (%s) — no-op\n" % e)
finally:
    sys.stdout = _real
sys.stdout.write((text or "").strip())
' "$MODE" "$SECS" || true )
fi
echo    # terminate the transcript line (empty line = nothing heard)
exit 0
