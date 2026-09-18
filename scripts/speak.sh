#!/usr/bin/env bash
# dreamteam — speak.sh: fire-and-forget VOICE seam for attention events.
# Contract:  speak.sh "<text>" [--voice <voice-or-alias>] [--timeout <sec>] [--source <tag>]
#
# ROUTE (2026-09-18): the gnome-speaks QUEUE first (POST .speech.queueUrl, default
# http://127.0.0.1:7710/speak) — every gate JP relies on (quiet hours, video-call
# mute, extension master switch, FIFO, chronicle) lives there. 503 = gated, stay
# silent. The direct tts.py engine chain below runs ONLY when the queue is
# unreachable AND .speech.directFallback is true (default false). Outcomes are
# logged one line each to $STATE/voice.log.
#
# AGENT USAGE (#71): dream agents speak DIRECTLY through this bash seam — the MCP
# voice tools are NOT wired into subagent sessions, but speak.sh is bash-invokable by
# any agent. Call it with your persona voice alias at KEY MOMENTS only (task start, a
# blocker, completion) — never chatty:
#     bash "$CLAUDE_PLUGIN_ROOT/scripts/speak.sh" \
#          "Reverie — branch is green, opening the PR." --voice en-US-EmmaNeural
# It resolves the voice, applies the offline fallback (#17) + --timeout (#52), and
# detaches — returns instantly, never blocks you. listen.sh is the INPUT half; see
# SKILL.md "Agent Voice I/O" for the voice roster + the one-mic serialization rule.
#
# Audio channel for RED-tier / scope-pressure attention (team-events.sh). DETACHED
# + hard-timeout so a HOOK NEVER BLOCKS; SILENT NO-OP (exit 0) when python3/tts.py/
# creds are missing or synth fails — attention must never brick a hook.
#
# OFFLINE FALLBACK CHAIN (issue #17) ───────────────────────────────────────────
# Config .speech.engine (default "azure") + .speech.fallback (ordered array,
# default []) form an engine chain, e.g. azure → piper. The DETACHED child tries
# each engine IN ORDER and STOPS at the first that exits 0; a non-zero exit
# (missing creds, synth failure, cloud unreachable) falls through to the next
# engine. With the default single-engine [azure] chain there is nothing to fall
# back to, so behavior is byte-for-byte the pre-#17 seam: fire once, ignore result.
# Enable the offline path by setting .speech.fallback = ["piper"] once speech-to-cli
# ships local TTS. This never blocks the hook: the whole chain runs off the hook
# path (setsid), each engine hard-capped by its own `timeout`.
#
# SEAM CONTRACT (speech-to-cli side — documented, NOT vendored here; see that
# repo's local-TTS issue). speak.sh only sets env and reads exit codes:
#   • SPEECH_ENGINE=<engine>  selects the engine for this invocation (azure|piper|…).
#       Azure-only tts.py IGNORES it today → inert; piper support MUST honor it.
#   • Per-engine voice env (state.py:166 pattern): azure → AZURE_SPEECH_VOICE
#       (existing, verified); piper → PIPER_VOICE (expected analog). Alias
#       davis/sandman resolves to a per-engine identity so the orchestrator keeps
#       ONE Davis voice across engines: en-US-DavisNeural (azure) / en_US-ryan-high
#       (piper — Davis-adjacent deep US male). Override any pairing via
#       .speech.voices.<alias>.<engine>. Explicit voice ids pass through unchanged.
#   • Fallback REQUIRES tts.py to exit NON-ZERO on synth failure. It already does
#       for missing creds (state.py load_config_standalone → sys.exit(1)); the
#       cloud-unreachable path currently returns None and STILL exits 0, so the
#       azure→piper hop won't fire on a network drop until the piper issue makes
#       that path exit non-zero. Documented dependency, not worked around here.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CFG="${DREAMTEAM_CONFIG:-$ROOT/config.json}"

TEXT="${1:-}"; [ -z "$TEXT" ] && exit 0        # nothing to say → no-op
shift 2>/dev/null || true
VOICE=""; TIMEOUT_FLAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --voice)     VOICE="${2:-}"; shift 2 2>/dev/null || shift ;;
    --voice=*)   VOICE="${1#--voice=}"; shift ;;
    --timeout)   TIMEOUT_FLAG="${2:-}"; shift 2 2>/dev/null || shift ;;
    --timeout=*) TIMEOUT_FLAG="${1#--timeout=}"; shift ;;
    --source)    SPEAK_SOURCE="${2:-}"; shift 2 2>/dev/null || shift ;;
    --source=*)  SPEAK_SOURCE="${1#--source=}"; shift ;;
    *)           shift ;;
  esac
done

# Master mute (default on). ==false-safe: jq's // treats false as empty, which
# would make speech.enabled=false unreachable (the reuse-gate/scope-attach bug).
[ "$(jq -r 'if .speech.enabled == false then "false" else "true" end' "$CFG" 2>/dev/null || echo true)" = "false" ] && exit 0
# ── THE QUEUE FIRST (JP, 2026-09-06: "if they are speaking they need to use the
# gnome-speaks queue"; 2026-09-18: "nothing should ever speak when I'm on a video
# call ... including this dreamteam memory gate thingy"). Every gnome-speaks gate
# -- quiet hours, video-call mute, the extension master switch, FIFO
# serialization, the chronicle -- lives on POST /speak. Calling tts.py directly
# (what this seam did until now) bypassed all of them and spoke into a call.
# Contract: 2xx = queued, done. 503 = gated (quiet hours / on a call / extension
# off) -- STAY SILENT, that is the gate working. Other HTTP answers (400 bad
# voice, 429 queue full) = the service is up and said no -- silent. Only an
# UNREACHABLE queue (curl exit != 0) may fall through to the direct engine
# chain, and only when .speech.directFallback is true (default false: a host
# with no gnome-speaks has no call detection either, so direct speech there
# is the exact hazard this exists to remove). One line per outcome is appended
# to $STATE/voice.log so "why didn't it speak?" has an answer.
QUEUE_URL="$(jq -r '.speech.queueUrl // empty' "$CFG" 2>/dev/null || true)"
[ -z "$QUEUE_URL" ] && QUEUE_URL="${SPEAK_QUEUE_URL:-}"   # env: a test suite pins a dead port here
[ -z "$QUEUE_URL" ] && QUEUE_URL="http://127.0.0.1:7710/speak"
DIRECT_FALLBACK="$(jq -r 'if .speech.directFallback == true then "true" else "false" end' "$CFG" 2>/dev/null || echo false)"
SOURCE="${SPEAK_SOURCE:-}"
[ -z "$SOURCE" ] && SOURCE="$(jq -r '.speech.source // empty' "$CFG" 2>/dev/null || true)"
[ -z "$SOURCE" ] && SOURCE="dreamteam"
STATE="${DREAMTEAM_STATE:-$ROOT/state}"
VOICE_LOG="$STATE/voice.log"

# Resolve tts.py: config .speech.ttsPath override → default; expand a leading ~.
TTS="$(jq -r '.speech.ttsPath // empty' "$CFG" 2>/dev/null || true)"
[ -z "$TTS" ] && TTS="$HOME/Projects/speech-to-cli/tts.py"
TTS="${TTS/#\~/$HOME}"

PY="$(command -v python3 2>/dev/null || true)"
[ -n "$PY" ] || exit 0                          # no python → silent no-op
[ -f "$TTS" ] || exit 0                          # no tts.py → silent no-op

# Canonical alias for the requested voice. Empty defaults to the Davis attention
# voice so the seam never silently 400s on the region's absent DragonHD default;
# an explicit id (ALIAS="") passes through untouched.
case "$VOICE" in
  ""|davis|sandman|Davis|Sandman) ALIAS="davis" ;;
  *)                              ALIAS="" ;;
esac

# Engine chain = [.speech.engine // "azure"] + .speech.fallback, order-preserving dedup.
PRIMARY="$(jq -r '.speech.engine // "azure"' "$CFG" 2>/dev/null || echo azure)"
{ [ -z "$PRIMARY" ] || [ "$PRIMARY" = "null" ]; } && PRIMARY="azure"
CHAIN=()
_add(){ local e="$1" x; { [ -z "$e" ] || [ "$e" = "null" ]; } && return 0
        for x in ${CHAIN[@]+"${CHAIN[@]}"}; do [ "$x" = "$e" ] && return 0; done
        CHAIN+=("$e"); }
_add "$PRIMARY"
while IFS= read -r e; do _add "$e"; done < <(jq -r '.speech.fallback // [] | .[]?' "$CFG" 2>/dev/null || true)

# Per-engine voice id: alias → config override .speech.voices.<alias>.<engine>,
# else the baked identity; explicit id → passthrough (engine may ignore a foreign id).
resolve_voice(){
  local eng="$1" v
  if [ -n "$ALIAS" ]; then
    v="$(jq -r --arg a "$ALIAS" --arg e "$eng" '.speech.voices[$a][$e] // empty' "$CFG" 2>/dev/null || true)"
    if [ -z "$v" ]; then case "$eng" in
      azure) v="en-US-DavisNeural" ;;
      piper) v="en_US-ryan-high" ;;
      *)     v="" ;;
    esac; fi
    printf '%s' "$v"
  else
    printf '%s' "$VOICE"
  fi
}
# Env var each engine reads for its voice (mirrors AZURE_SPEECH_VOICE).
voice_env_name(){ case "$1" in azure) echo AZURE_SPEECH_VOICE ;; piper) echo PIPER_VOICE ;; *) echo SPEECH_VOICE ;; esac; }

# Queue payload: the text, the source tag (gnome-speaks tags every line and
# transcript by it), and the resolved AZURE voice id so the persona identity
# (Davis for the orchestrator) survives the hop -- the service sanitizes it.
QVOICE="$(resolve_voice azure)"
PAYLOAD="$(jq -cn --arg t "$TEXT" --arg s "$SOURCE" --arg v "$QVOICE" \
  '{text:$t, source:$s} + (if $v != "" then {voice:$v} else {} end)' 2>/dev/null || true)"
[ -n "$PAYLOAD" ] || PAYLOAD="{\"text\":$(printf '%s' "$TEXT" | jq -Rs .),\"source\":\"$SOURCE\"}"
mkdir -p "$STATE" 2>/dev/null || true
# Flatten the resolved chain into positional args for the detached child:
#   PAYLOAD URL DIRECT LOG  TEXT PY TTS N  then N × (engine, voiceEnvName, voiceId)
ARGS=("$PAYLOAD" "$QUEUE_URL" "$DIRECT_FALLBACK" "$VOICE_LOG" "$TEXT" "$PY" "$TTS" "${#CHAIN[@]}")
for eng in "${CHAIN[@]}"; do
  ARGS+=("$eng" "$(voice_env_name "$eng")" "$(resolve_voice "$eng")")
done

# Per-engine hard cap (seconds): bounds a hung TTS WITHOUT truncating legitimate
# speech. PRECEDENCE (#52): explicit --timeout flag > config .speech.timeoutSec >
# default 180. The attention path (team-events.sh) passes a SHORT --timeout so a
# hung synth can't pin a proc for 180s during a memory-pressure event; manual /
# briefing callers omit it and inherit the long config cap so long utterances are
# not chopped (nebula's 10s→180s fold). Each tier is guarded: empty / non-digit /
# non-positive falls through to the next, so TIMEOUT ends a validated POSITIVE
# integer — safe to interpolate into the CHILD string below.
TIMEOUT="$TIMEOUT_FLAG"                                  # 1) explicit flag wins
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT="" ;; esac       #    invalid flag → fall through
[ -z "$TIMEOUT" ] && TIMEOUT="$(jq -r '.speech.timeoutSec // empty' "$CFG" 2>/dev/null || true)"  # 2) config
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=180 ;; esac      # 3) default
[ "$TIMEOUT" -gt 0 ] 2>/dev/null || TIMEOUT=180          #    positive-int guard (reject 0)

# The child walks the chain, stopping at the first engine that exits 0. Data is
# passed POSITIONALLY (never interpolated into code) so arbitrary TEXT is injection-safe.
# ($TIMEOUT is the sole exception — a validated integer, baked in at construction.)
CHILD='payload=$1; url=$2; direct=$3; logf=$4; text=$5; py=$6; tts=$7; n=$8; shift 8
vlog(){ printf "%s %s | %s\n" "$(date +%FT%T)" "$1" "$(printf "%s" "$text" | head -c 80)" >> "$logf" 2>/dev/null || true; }
if command -v curl >/dev/null 2>&1; then
  code=$(curl -s -o /dev/null -w "%{http_code}" -m 4 -H "Content-Type: application/json" \
           -X POST --data-binary "$payload" "$url" 2>/dev/null); rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$code" ]; then
    case "$code" in
      2*)  vlog "queued $code"; exit 0 ;;
      503) vlog "gated 503 (quiet hours / on a call / extension off) -- silent"; exit 0 ;;
      *)   vlog "queue answered $code -- silent"; exit 0 ;;
    esac
  fi
  vlog "queue unreachable (curl rc=$rc)"
else
  vlog "no curl -- cannot reach the queue"
fi
[ "$direct" = true ] || { vlog "directFallback=false -- silent"; exit 0; }
vlog "directFallback=true -- engine chain"
i=0
while [ "$i" -lt "$n" ]; do
  eng=$1; ven=$2; vid=$3; shift 3; i=$((i+1))
  if env SPEECH_ENGINE="$eng" "$ven=$vid" timeout -k 2 '"$TIMEOUT"' "$py" "$tts" "$text" </dev/null >/dev/null 2>&1; then
    exit 0
  fi
done
exit 0'

# Fire FULLY DETACHED (new session survives the hook's exit), all fds closed.
# Returns immediately; result ignored — the chain runs entirely off the hook path.
if command -v setsid >/dev/null 2>&1; then
  setsid bash -c "$CHILD" _ "${ARGS[@]}" </dev/null >/dev/null 2>&1 &
else
  bash -c "$CHILD" _ "${ARGS[@]}" </dev/null >/dev/null 2>&1 &
fi
disown 2>/dev/null || true
exit 0
