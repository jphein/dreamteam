#!/usr/bin/env bash
# dreamteam — speak.sh: fire-and-forget VOICE seam for attention events.
# Contract:  speak.sh "<text>" [--voice <voice-or-alias>]
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
VOICE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --voice)   VOICE="${2:-}"; shift 2 2>/dev/null || shift ;;
    --voice=*) VOICE="${1#--voice=}"; shift ;;
    *)         shift ;;
  esac
done

# Master mute (default on). ==false-safe: jq's // treats false as empty, which
# would make speech.enabled=false unreachable (the reuse-gate/scope-attach bug).
[ "$(jq -r 'if .speech.enabled == false then "false" else "true" end' "$CFG" 2>/dev/null || echo true)" = "false" ] && exit 0

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

# Flatten the resolved chain into positional args for the detached child:
#   TEXT PY TTS N  then N × (engine, voiceEnvName, voiceId)
ARGS=("$TEXT" "$PY" "$TTS" "${#CHAIN[@]}")
for eng in "${CHAIN[@]}"; do
  ARGS+=("$eng" "$(voice_env_name "$eng")" "$(resolve_voice "$eng")")
done

# Per-engine hard cap (seconds): bounds a hung TTS WITHOUT truncating legitimate
# speech. Configurable via config.json .speech.timeoutSec (default 180). Was a fixed
# 10s — safe for RED-tier attention blips, but it chopped longer manual utterances
# mid-sentence (folded from nebula's fix, issue-adjacent). Coerce non-numeric→default;
# TIMEOUT is then a validated integer, so interpolating it into CHILD below is safe.
TIMEOUT="$(jq -r '.speech.timeoutSec // empty' "$CFG" 2>/dev/null || true)"
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=180 ;; esac

# The child walks the chain, stopping at the first engine that exits 0. Data is
# passed POSITIONALLY (never interpolated into code) so arbitrary TEXT is injection-safe.
# ($TIMEOUT is the sole exception — a validated integer, baked in at construction.)
CHILD='text=$1; py=$2; tts=$3; n=$4; shift 4; i=0
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
