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
#   dreamteam_uint <value> <max>   rc 0 when <value> is a decimal integer 0..max (no sign, no exponent, no fraction): used
#                                  for MEASURED numbers (free -m). Config numbers go through dreamteam_int (policy below).
dreamteam_host() {
  local h="${DREAMTEAM_HOST:-}"
  if [ -z "$h" ]; then h=$(hostname -s 2>/dev/null) || h=""; [ -n "$h" ] || { h=$(hostname 2>/dev/null); h=${h%%.*}; }; fi
  h=$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]')
  [[ "$h" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] && printf '%s' "$h"
}
dreamteam_config() { # rc 0 ok (with or without an overlay); rc 3 = this host's overlay EXISTS but is not one strict-JSON
  # object (the base is printed; callers must treat it as invalid: the overlay may hold floors the base does not have);
  # any other non-zero = the parser could not run (callers: invalid). ONE parser for every reader: config_merge.py
  # (xreview #230 r7: jq and Python disagreed on what a file says, e.g. 03000).
  python3 -I "$(dirname "${BASH_SOURCE[0]}")/config_merge.py" "$1" 2>/dev/null
}
dreamteam_uint() { [[ "$1" =~ ^[0-9]{1,9}$ ]] && [ "$((10#$1))" -le "$2" ]; }
# dreamteam_int <json> <section> <key> <default>: the integer (absent → default); rc 2 with the reason on stderr when it
# is present but not an integer 0..10^7, or the section is not an object
dreamteam_int() { # the VALUE is judged, numerically, so every jq version agrees with dashboard-data.sh (jq 1.7 keeps the
  # literal 750.0 / 7.5E+2, older jq normalises it; both are the integral number 750 and valid): a JSON number, integral,
  # 0..10^7. Strings ("3000", "1e4"), booleans, null and fractions are invalid (xreview #230 r5).
  local v n; v=$(dreamteam_cfg_raw "$1" "$2" "$3")
  case "$v" in ABSENT) printf '%s' "$((10#$4))"; return 0;; BADSECTION) echo "$2 is not an object" >&2; return 2;; esac
  n=$(jq -nr --argjson v "$v" '$v | if type == "number" and . == floor and . >= 0 and . <= 10000000 then (floor | if . == 0 then 0 else . end) else error("x") end' 2>/dev/null) \
    && dreamteam_uint "$n" 10000000 || { echo "$2.$3 is '$v', not an integer 0..10000000" >&2; return 2; }
  printf '%s' "$((10#$n))"
}
# dreamteam_bool <json> <section> <key> <default>: true|false (absent → default); rc 2 when present but not a boolean
dreamteam_bool() {
  local v; v=$(dreamteam_cfg_raw "$1" "$2" "$3")
  case "$v" in ABSENT) printf '%s' "$4";; true|false) printf '%s' "$v";;
    BADSECTION) echo "$2 is not an object" >&2; return 2;; *) echo "$2.$3 is '$v', not true/false" >&2; return 2;; esac
}
# dreamteam_cfg_raw <json> <section> <key>: "ABSENT" when the key is not there (or the section is absent), else the
# value as JSON text (so false, null, "" and "3000" stay visibly what they are). A section that is present but not an
# object prints "BADSECTION". Callers decide: ABSENT → their default; anything else must validate or they block.
dreamteam_cfg_raw() {
  jq -r --arg s "$2" --arg k "$3" 'if has($s) | not then "ABSENT" elif (.[$s] | type) != "object" then "BADSECTION"
    elif (.[$s] | has($k)) then (.[$s][$k] | tojson) else "ABSENT" end' <<<"$1" 2>/dev/null || printf 'BADSECTION'
}
