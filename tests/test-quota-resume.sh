#!/usr/bin/env bash
# quota_resume.py: it types "continue" only when the proxy says a seat can serve, and it waits the reset the notice
# names. 2026-11-21 (Sen, seat walls): it typed 146 times into two walls because it counted any seat with a sliver of
# 5h and week left, crashed (AttributeError) on a seat whose fiveHour bucket is null, and read "Quota resets in 1h 55m"
# as no reset at all (300 s).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf -- "$T"' EXIT
fail=0
t() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }

pane() {  # a claude pane whose latest output block is the proxy's wall notice ($1)
  printf '%s\n' '● Working on it' '' "● API Error: Server is temporarily limiting requests (not your usage limit) · No account can serve this request for claude-mythos-5-1: all 7 accounts are at their quota or rate limit. $1" '' '────────' '❯ ' '────────' > "$T/pane"
}
seat() {  # name status five week
  printf '{"name":"%s","disabled":false,"status":"%s","buckets":{"fiveHour":%s,"weeklyShared":{"utilization":%s,"remaining":%s}}}' \
    "$1" "$2" "$([ "$3" = null ] && echo null || echo "{\"utilization\":$3,\"remaining\":$(awk -v x="$3" 'BEGIN{print 1-x}')}")" "$4" "$(awk -v x="$4" 'BEGIN{print 1-x}')"
}
quota() { printf '{"aggregate":{"fiveHour":{"remaining":0.67}},%s"accounts":[%s]}' "$1" "$2" > "$T/q.json"; }
run() { QUOTA_RESUME_QUOTA_FILE="$T/q.json" python3 -I "$ROOT/scripts/quota_resume.py" --dry-run --fixture "$T/pane" 2>&1; }

pane 'Quota resets in 1h 55m.'
# the 2026-11-21 shape: five week-spent seats with empty 5h windows (raw 5h 67% left), the two week-room seats
# 5h-full or throttled, a null fiveHour bucket, and the proxy's own count 0
quota '"live_seats":0,' "$(seat claude3 active 0 1),$(seat jp active 0 1),$(seat claude active 0.98 0.95),$(seat claude2 error null 1),$(seat claude4 active 0 1),$(seat claude5 throttled 0.2 0.46),$(seat claude6 active 0 1)"
out=$(run)
t "the proxy's live_seats 0 holds, whatever the raw 5h says" grep -q 'serves=False' <<<"$out"
t "'Quota resets in 1h 55m' is 6900 s, not the 300 s default" grep -q 'wait=6900s' <<<"$out"

quota '"live_seats":2,' "$(seat claude active 0.98 0.95)"
t "live_seats 2 serves" grep -q 'serves=True' <<<"$(run)"

# an older proxy without live_seats: the seats are judged here by the proxy's rules, and a null bucket is no crash
quota '' "$(seat claude3 active 0 1),$(seat claude2 error null 1),$(seat claude active 0.98 0.95),$(seat claude5 throttled 0.2 0.46)"
out=$(run)
t "no live_seats: slivers, throttled and week-spent seats do not serve" grep -q 'serves=False' <<<"$out"
t "no live_seats: a null fiveHour bucket is no AttributeError" bash -c '! grep -q AttributeError <<<"$1"' _ "$out"
quota '' "$(seat claude2 error null 1),$(seat claude5 active 0.2 0.46)"
t "no live_seats: an active seat with room serves" grep -q 'serves=True' <<<"$(run)"

pane 'resets in 42s'
t "the older 'resets in 42s' still reads 42 s" grep -q 'wait=42s' <<<"$(run)"
pane 'Try again later.'
t "a notice naming no reset waits the 300 s default" grep -q 'wait=300s' <<<"$(run)"

exit $fail
