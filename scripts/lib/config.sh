# dreamteam per-host config overlay (Sen 2026-11-17). Sourced by every config reader: mem-gate.sh, mem-budget.sh,
# overnight-guarded.sh, lane-check.sh (dashboard-data.sh mirrors it in Python; tests/test-roster.sh guards that they agree).
#
#   dreamteam_host                 this host's short name: DREAMTEAM_HOST, else `hostname -s` (else `hostname` up to its
#                                  first dot), lower-cased. It must then be ^[a-z0-9][a-z0-9-]{0,62}$ AS IS: an invalid name
#                                  is never "cleaned" into another host's name (fami_liar must not become familiar); it
#                                  prints nothing, and no overlay applies. tests/run.sh pins DREAMTEAM_HOST=dreamteam-test.
#   dreamteam_config <config.json> the config as ONE JSON object on stdout: <config.json> deep-merged (jq `*`) with
#                                  config.<host>.json beside it. Each file must hold exactly one JSON object. An overlay that
#                                  is not that is ignored (the base, the stricter shared floors, applies); a base that is
#                                  not that gives "{}" (every reader then uses its baked defaults, as before).
#   dreamteam_uint <value> <max>   rc 0 when <value> is a decimal integer 0..max (no sign, no exponent, no fraction)
dreamteam_host() {
  local h="${DREAMTEAM_HOST:-}"
  if [ -z "$h" ]; then h=$(hostname -s 2>/dev/null) || h=""; [ -n "$h" ] || { h=$(hostname 2>/dev/null); h=${h%%.*}; }; fi
  h=$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]')
  [[ "$h" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] && printf '%s' "$h"
}
_dreamteam_one_object() { # file → its single object, compact, or rc 1
  local o; o=$(jq -cs 'if length == 1 and (.[0] | type) == "object" then .[0] else error("not one object") end' "$1" 2>/dev/null) \
    && [ -n "$o" ] && printf '%s' "$o"
}
dreamteam_config() {
  local base="$1" host b o
  b=$(_dreamteam_one_object "$base") || b='{}'
  host=$(dreamteam_host)
  if [ -n "$host" ] && [ -f "${base%.json}.$host.json" ] && o=$(_dreamteam_one_object "${base%.json}.$host.json"); then
    jq -cn --argjson b "$b" --argjson o "$o" '$b * $o' 2>/dev/null && return 0
  fi
  printf '%s\n' "$b"
}
dreamteam_uint() { [[ "$1" =~ ^[0-9]{1,9}$ ]] && [ "$((10#$1))" -le "$2" ]; }
