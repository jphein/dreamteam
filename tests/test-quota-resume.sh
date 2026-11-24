#!/usr/bin/env bash
# quota_resume.py: it types "continue" only when the proxy says a seat can serve, and it waits the reset the notice
# names. 2026-11-21 (Sen, seat walls): it typed 146 times into two walls because it counted any seat with a sliver of
# 5h and week left, crashed (AttributeError) on a seat whose fiveHour bucket is null, and read "Quota resets in 1h 55m"
# as no reset at all (300 s).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'tmux -S "$T/lanes.sock" kill-server 2>/dev/null; rm -rf -- "$T"' EXIT
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

# ── 2026-11-21 (Sen, row 55bd0a23): the CHECK line names the walled panes; a lane host runs this itself ─────────
# Fixture names are fx-…, never a real tmux session's name: nothing here may ever reach a live lane's pane.
# Real (not --dry-run) runs over FIXTURE panes: every decision is taken, the state and the line are written, and a
# fixture is never typed into. State, log and line go to temp dirs through the script's seams.
S="$T/state"; C="$T/checks"; mkdir -p "$S" "$C"
WALL='● API Error: Server is temporarily limiting requests (not your usage limit) · No account can serve this request for claude-mythos-5-1: all 7 accounts are at their quota or rate limit.'
mk() {  # mk <name> <reset text> <box line> [extra line before the box]
  printf '%s\n' '● Working on it' '' "$WALL $2" '' ${4:+"$4"} '────────' "$3" '────────' > "$T/$1"
}
live() {  # live <fixture names…>   (env H = host name, default familiar)
  local fx=(); for f in "$@"; do fx+=("$T/$f"); done
  QUOTA_RESUME_QUOTA_FILE="$T/q.json" QUOTA_RESUME_STATE_DIR="$S" DREAMTEAM_CHECKS_DIR="$C" DREAMTEAM_CHECK_HOST="${H:-familiar}" \
    python3 -I "$ROOT/scripts/quota_resume.py" --fixture "${fx[@]}" > "$T/out" 2>&1
}
line() { cat "$C/${1:-quota-resume}.line" 2>/dev/null; }
seed() {  # make every wall in the state file 2 hours old, so its reset has passed
  python3 -I -c 'import json, sys, time, glob
for f in glob.glob(sys.argv[1] + "/quota_resume_state.*.json"):
    d = json.load(open(f)); [v.__setitem__("first", time.time() - 7200) for v in d.values() if isinstance(v, dict)]; json.dump(d, open(f, "w"))' "$S"
}
fresh_state() { rm -f "$S"/quota_resume_state.*.json "$S"/quota_resume.*.log "$C"/*.line; }
quota '"live_seats":2,' "$(seat claude active 0.2 0.4)"

printf '%s\n' '● All done.' '' '────────' '❯ ' '────────' > "$T/calm"
fresh_state; live calm
t "no walled pane: ok, the count of panes read, exactly three segments" bash -c '[ "$1" = "CHECK quota-resume ok · 1 panes read, 0 walled · every 2 min, owner Sen" ]' _ "$(line)"
H=serialhub live calm
t "off familiar the line carries the host (quota-resume-serialhub)" grep -q '^CHECK quota-resume-serialhub ok · 1 panes read, 0 walled' <<<"$(line quota-resume-serialhub)"

mk fx-luna 'Quota resets in 5m.' '❯ '
fresh_state; live calm fx-luna
t "a wall still inside its reset: warn, the pane NAMED, and how long it waits" grep -qE '^CHECK quota-resume warn · 2 panes read, 1 walled: fx-luna \(waits [0-9]+ s for the reset\) · every 2 min, owner Sen$' <<<"$(line)"
seed; live calm fx-luna
t "reset passed and a seat serves: resumed, named in the line" grep -q '1 walled: fx-luna (resumed) · ' <<<"$(line)"
t "…a fixture is never typed into: the log says what it would have done" grep -q 'would resume fx-luna (a fixture is never typed into)' "$S"/quota_resume.*.log
live calm fx-luna
t "the same notice a run later: said so, not resumed twice" bash -c 'grep -q "fx-luna (resumed once already, still on the same turn)" <<<"$1" && [ "$(grep -c "would resume" "$2"/quota_resume.*.log)" = 1 ]' _ "$(line)" "$S"

quota '"live_seats":0,' "$(seat claude active 0.99 1)"
fresh_state; live fx-luna; seed; live fx-luna
t "reset passed but NO seat can serve: held, named, not marked resumed" bash -c 'grep -q "fx-luna (no seat can serve)" <<<"$1" && ! grep -qs "would resume" "$2"/quota_resume.*.log' _ "$(line)" "$S"
quota '"live_seats":2,' "$(seat claude active 0.2 0.4)"
live fx-luna
t "…and it is resumed on the run after a seat is back" grep -q 'fx-luna (resumed)' <<<"$(line)"

mk fx-roam 'Quota resets in 5m.' '❯ half a sentence someone typed'
fresh_state; live fx-roam; seed; live fx-roam
t "typed text in the box: never resumed, and the line says why (the case that sat unseen)" bash -c 'grep -q "1 walled: fx-roam (typed text in its box)" <<<"$1" && ! grep -qs "would resume" "$2"/quota_resume.*.log' _ "$(line)" "$S"
mk fx-ghost 'Quota resets in 5m.' "$(printf '❯ \033[2mResend your message to try again\033[0m')"
fresh_state; live fx-ghost; seed; live fx-ghost
t "a FAINT placeholder in the box is not typed text: the pane is resumed" grep -q 'fx-ghost (resumed)' <<<"$(line)"
mk fx-dialog 'Quota resets in 5m.' '❯ ' 'Do you want to proceed?'
fresh_state; live fx-dialog; seed; live fx-dialog
t "a dialog on a walled pane: not touched, named with the reason" bash -c 'grep -q "fx-dialog (a dialog is open)" <<<"$1" && ! grep -qs "would resume" "$2"/quota_resume.*.log' _ "$(line)" "$S"
printf '%s\n' '● Working on it' '' "$WALL Quota resets in 5m." '✢ Wibbling… (3m 49s · ↓ 17.0k tokens)' '────────' '❯ ' '────────' > "$T/busy"
fresh_state; live busy
t "a pane that is working again is not walled" grep -q '1 panes read, 0 walled' <<<"$(line)"
printf '%s\n' '● Working on it' '' "$WALL Quota resets in 5m." '✢ Wibbling… (3m 49s · ↓ 17.0k tokens)' 'Do you want to proceed?' '────────' '❯ ' '────────' > "$T/busydialog"
fresh_state; live busydialog
t "…also when a dialog is open on it (working is not walled, dialog or not)" grep -q '1 panes read, 0 walled' <<<"$(line)"
for i in 1 2 3 4 5 6 7 8 9 10; do mk "fx-lane$i" 'Quota resets in 5m.' '❯ '; done
fresh_state; live fx-lane1 fx-lane2 fx-lane3 fx-lane4 fx-lane5 fx-lane6 fx-lane7 fx-lane8 fx-lane9 fx-lane10
t "nothing was written beside the script (state and log go to the state dir)" bash -c '[ -z "$(ls "$1"/scripts/quota_resume_state.* "$1"/scripts/quota_resume.*.log 2>/dev/null)" ] || git -C "$1" diff --quiet -- scripts' _ "$ROOT"

# the REAL path, against a stub tmux: the line names the SESSION, the keys go to the PANE
mkdir -p "$T/bin"; mk realpane 'Quota resets in 5m.' '❯ '
cat > "$T/bin/tmux" <<EOF
#!/usr/bin/env bash
if [ "\$1" = -S ]; then echo "\$2" >> "$T/sock.log"; shift 2; else echo "NO-SOCKET \$*" >> "$T/sock.log"; fi
echo "tmux \$*" >> "$T/tmux.log"
case "\$*" in
  list-panes*) [ -e "$T/tmux-mode" ] && { cat "$T/tmux-mode" >&2; exit 1; }; printf '%%7 4242 morpheus-topology claude\n%%9 4243 scratch bash\n' ;;
  "capture-pane -e -p -t %7") cat "$T/realpane" ;;
  "capture-pane -e -p -t %9") printf 'jp@host:~\$ \n' ;;
esac
EOF
chmod +x "$T/bin/tmux"
real() { PATH="$T/bin:$PATH" QUOTA_RESUME_QUOTA_FILE="$T/q.json" QUOTA_RESUME_STATE_DIR="$S" DREAMTEAM_CHECKS_DIR="$C" DREAMTEAM_CHECK_HOST=serialhub python3 -I "$ROOT/scripts/quota_resume.py" > "$T/out" 2>&1; }
fresh_state; : > "$T/tmux.log"; real
t "real path, first sighting: nothing typed, the SESSION named" bash -c 'grep -q "2 panes read, 1 walled: morpheus-topology (waits" <<<"$1" && ! grep -q "send-keys" "$2"' _ "$(line quota-resume-serialhub)" "$T/tmux.log"
seed; real
t "real path, reset passed: 'continue' is typed into that pane and Enter pressed" bash -c 'grep -qF "tmux send-keys -t %7 -l continue (jp-ab auto-resume after quota reset)" "$1" && grep -qxF "tmux send-keys -t %7 Enter" "$1" && ! grep -q "send-keys -t %9" "$1"' _ "$T/tmux.log"
t "…and the line says resumed" grep -q 'morpheus-topology (resumed)' <<<"$(line quota-resume-serialhub)"
echo "protocol version mismatch (client 8, server 7)" > "$T/tmux-mode"; fresh_state; real
t "tmux cannot be read: fail, with the reason, never an ok" grep -q '^CHECK quota-resume-serialhub fail · tmux cannot be read (protocol version mismatch' <<<"$(line quota-resume-serialhub)"
rm -f "$T/tmux-mode"
t "the unit runs this script from the repo checkout" grep -qx 'ExecStart=/usr/bin/python3 %h/Projects/dreamteam/scripts/quota_resume.py' "$ROOT/systemd/quota-resume.service"

# ── the failover turn (measured 2026-11-23: 19 in six days on serialhub; each "pane hung" report matches one) ───
FO='● ⚠ FAILOVER: local qwen36-coder served this turn; no tools ran; treat as unavailable'
fo() {  # fo <name> <a line of the small model's answer> <box line>
  printf '%s\n' '● Working on it' '' "$FO" '' "  $2" '' '────────' "$3" '────────' > "$T/$1"
}
quota '"live_seats":2,' "$(seat claude active 0.2 0.4)"
fo fx-fo 'I cannot run tools.' '❯ '
fresh_state; live fx-fo
t "a failover-served turn is a stall: warn, named, a short wait (not the 300 s default)" bash -c '[[ "$1" =~ 1\ walled:\ fx-fo\ \(failover\ turn,\ waits\ ([0-9]+)\ s\) ]] && [ "${BASH_REMATCH[1]}" -le 150 ]' _ "$(line)"
seed; live fx-fo
t "…after the wait, with a seat serving: resumed, and the log says after what" bash -c 'grep -q "fx-fo (failover turn, resumed)" <<<"$1" && grep -q "after a failover turn" "$2"/quota_resume.*.log' _ "$(line)" "$S"
quota '"live_seats":0,' "$(seat claude active 0.99 1)"
fresh_state; live fx-fo; seed; live fx-fo
t "…with no seat serving: held (the proxy would only fail over again)" grep -q 'fx-fo (failover turn, no seat can serve)' <<<"$(line)"
quota '"live_seats":2,' "$(seat claude active 0.2 0.4)"
fo fx-fotyped 'I cannot run tools.' '❯ a half-typed order'
fresh_state; live fx-fotyped; seed; live fx-fotyped
t "…with typed text in the box: never typed over, said so" bash -c 'grep -q "fx-fotyped (failover turn, typed text in its box)" <<<"$1" && ! grep -qs "would resume" "$2"/quota_resume.*.log' _ "$(line)" "$S"
fresh_state
for n in 1 2 3; do fo fx-fo "answer number $n" '❯ '; live fx-fo; seed; live fx-fo; done
t "three failover turns in an hour on one pane are each resumed" bash -c '[ "$(grep -c "would resume fx-fo" "$1"/quota_resume.*.log)" = 3 ]' _ "$S"
fo fx-fo 'answer number 4' '❯ '; live fx-fo; seed; live fx-fo
t "…the fourth is HELD: a proxy that keeps failing over is not fed forever" bash -c 'grep -q "fx-fo (failover turn, 3 resumes already this hour: held)" <<<"$1" && [ "$(grep -c "would resume fx-fo" "$2"/quota_resume.*.log)" = 3 ]' _ "$(line)" "$S"
printf '%s\n' '● Working on it' '' '● I saw the mark ⚠ FAILOVER: local qwen36-coder served this turn in another pane.' '' '────────' '❯ ' '────────' > "$T/fx-quote"
fresh_state; live fx-quote
t "a pane that only QUOTES the mark mid-sentence is not stalled" grep -q '1 panes read, 0 walled' <<<"$(line)"
printf '%s\n' '● Working on it' '' "$FO" '✢ Wibbling… (3m 49s · ↓ 17.0k tokens)' '────────' '❯ ' '────────' > "$T/fx-fobusy"
fresh_state; live fx-fobusy
t "a failover mark with the agent working again below it is not stalled" grep -q '1 panes read, 0 walled' <<<"$(line)"
fo realpane 'I cannot run tools.' '❯ '
fresh_state; : > "$T/tmux.log"; real; seed; real
t "real path: the failover message is what gets typed, into that pane" bash -c 'grep -qF "tmux send-keys -t %7 -l continue (auto-resume: your last turn was served by the local failover model" "$1" && grep -qxF "tmux send-keys -t %7 Enter" "$1"' _ "$T/tmux.log"

# ── xreview #283 round 1 (Sen 2026-11-23) ───────────────────────────────────────────────────────────────────
# A stub tmux with modes: `capture-pane` of %7 answers the first file on its first call and the second file after
# (a pane that CHANGED between the first look and the send); `send-keys` can be made to refuse one kind of key.
cat > "$T/bin/tmux" <<EOF
#!/usr/bin/env bash
if [ "\$1" = -S ]; then echo "\$2" >> "$T/sock.log"; shift 2; else echo "NO-SOCKET \$*" >> "$T/sock.log"; fi
echo "tmux \$*" >> "$T/tmux.log"
case "\$*" in
  list-panes*) [ -e "$T/tmux-mode" ] && { cat "$T/tmux-mode" >&2; exit 1; }; printf '%%7 4242 morpheus-topology claude\n%%9 4243 scratch bash\n' ;;
  "capture-pane -e -p -t %7") n=\$(( \$(cat "$T/cap.count" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$T/cap.count"
     if [ "\$n" -ge 2 ] && [ -e "$T/append-on-second" ]; then cat "$T/append-on-second" >> "\$(cat "$T/append-to")"; fi
     if [ "\$n" -ge 2 ] && [ -e "$T/realpane.second" ]; then cat "$T/realpane.second"; else cat "$T/realpane"; fi ;;
  "capture-pane -e -p -t %9") printf 'jp@host:~\$ \n' ;;
  "send-keys -t %7 C-u") [ "\$(cat "$T/tmux-fail" 2>/dev/null)" != cu ] ;;
  "send-keys -t %7 -l "*) [ "\$(cat "$T/tmux-fail" 2>/dev/null)" != text ] ;;
  "send-keys -t %7 Enter") [ "\$(cat "$T/tmux-fail" 2>/dev/null)" != enter ] ;;
esac
EOF
chmod +x "$T/bin/tmux"
mkdir -p "$T/noclaude"
real() { PATH="$T/bin:$PATH" QUOTA_RESUME_QUOTA_FILE="$T/q.json" QUOTA_RESUME_STATE_DIR="$S" DREAMTEAM_CHECKS_DIR="$C" DREAMTEAM_CHECK_HOST=serialhub QUOTA_RESUME_PROC="${PROCFIX:-$T/noclaude}" python3 -I "$ROOT/scripts/quota_resume.py" > "$T/out" 2>&1; }
age() {  # make every recorded stall <seconds> old
  python3 -I -c 'import json, sys, time, glob
for f in glob.glob(sys.argv[1] + "/quota_resume_state.*.json"):
    d = json.load(open(f))
    for v in d.values():
        if isinstance(v, dict):
            v["first"] = time.time() - float(sys.argv[2])
            if v.get("done_at"): v["done_at"] = time.time() - float(sys.argv[2])
    json.dump(d, open(f, "w"))' "$S" "$1"
}
start() { fresh_state; rm -f "$T/cap.count" "$T/realpane.second" "$T/tmux-fail"; : > "$T/tmux.log"; real; age 7200; rm -f "$T/cap.count"; : > "$T/tmux.log"; }
sent() { grep -c '^tmux send-keys' "$T/tmux.log" || true; }
L() { line quota-resume-serialhub; }
quota '"live_seats":2,' "$(seat claude active 0.2 0.4)"
mk realpane 'Quota resets in 5m.' '❯ '

# (1) the pane is captured AGAIN right before the send; a pane that changed meanwhile gets no key
start; mk realpane.second 'Quota resets in 5m.' '❯ words someone typed just now'; real
t "a pane that gained TYPED TEXT between the first look and the send gets NO key" bash -c '[ "$1" = 0 ] && grep -q "morpheus-topology (changed while being looked at" <<<"$2"' _ "$(sent)" "$(L)"
t "…and it was looked at twice (the second capture is the one right before the send)" bash -c '[ "$(grep -c "capture-pane -e -p -t %7" "$1")" = 2 ]' _ "$T/tmux.log"
start; printf '%s\n' '● Working on it' '' "$WALL Quota resets in 5m." '✢ Wibbling… (3m 49s · ↓ 17.0k tokens)' '────────' '❯ ' '────────' > "$T/realpane.second"; real
t "a pane that started WORKING meanwhile gets no key" bash -c '[ "$1" = 0 ]' _ "$(sent)"
# the dialog is drawn BELOW the box, so the stalled block itself reads exactly as before: only the dialog check sees it
start; printf '%s\n' '● Working on it' '' "$WALL Quota resets in 5m." '' '────────' '❯ ' '────────' ' Do you want to proceed?' '   1. Yes   2. No' > "$T/realpane.second"; real
t "a pane where a DIALOG opened meanwhile (the stalled block unchanged) gets no key" bash -c '[ "$1" = 0 ]' _ "$(sent)"
start; printf '%s\n' '● Working on it' '' '● All done, tests pass.' '' '────────' '❯ ' '────────' > "$T/realpane.second"; real
t "a pane whose stall is GONE meanwhile (idle, empty box, another block) gets no key" bash -c '[ "$1" = 0 ] && grep -q "changed while being looked at" <<<"$2"' _ "$(sent)" "$(L)"
start; real
order() { awk '/capture-pane -e -p -t %7/ {c=NR} /send-keys -t %7 C-u/ {u=NR} /send-keys -t %7 -l continue \(jp-ab auto-resume/ {x=NR} /send-keys -t %7 Enter/ {e=NR} END {exit !(c && u && x && e && c < u && u < x && x < e)}' "$T/tmux.log"; }
t "an unchanged pane: the second capture, then Ctrl-U, the text, Enter, in that order, and nothing else" bash -c '[ "$1" = 3 ]' _ "$(sent)"
t "…in exactly that order" order

# (2) no seat: the pane is not touched at all
quota '"live_seats":0,' "$(seat claude active 0.99 1)"; start; real
t "no seat can serve: ZERO send-keys calls (not even the clearing key), and no second capture" bash -c '[ "$1" = 0 ] && [ "$(grep -c "capture-pane -e -p -t %7" "$2")" = 1 ] && grep -q "morpheus-topology (no seat can serve)" <<<"$3"' _ "$(sent)" "$T/tmux.log" "$(L)"
quota '"live_seats":2,' "$(seat claude active 0.2 0.4)"

# (3) a key tmux refuses stops the sequence, is reported, and is not a resume
start; echo text > "$T/tmux-fail"; real
t "the text refused: no Enter is sent, the line says so, nothing is recorded as resumed" bash -c '! grep -q "send-keys -t %7 Enter" "$1" && grep -q "morpheus-topology (send failed (the text was refused: nothing sent))" <<<"$2" && ! grep -q "resumed %7" "$3"/quota_resume.*.log' _ "$T/tmux.log" "$(L)" "$S"
rm -f "$T/tmux-fail" "$T/cap.count"; : > "$T/tmux.log"; real
t "…and the next run tries again (a failed send is not 'done')" bash -c 'grep -q "morpheus-topology (resumed)" <<<"$1"' _ "$(L)"
start; echo enter > "$T/tmux-fail"; real
t "Enter refused: reported as typed-but-not-sent, not as resumed" bash -c 'grep -q "send failed (the text is typed but Enter was refused: it sits in the box)" <<<"$1" && ! grep -q "resumed %7" "$2"/quota_resume.*.log' _ "$(L)" "$S"
start; echo cu > "$T/tmux-fail"; real
t "the clearing key refused: nothing else is sent" bash -c '[ "$1" = 1 ] && grep -q "the clearing key was refused: nothing typed" <<<"$2"' _ "$(sent)" "$(L)"
fo realpane 'I cannot run tools.' '❯ '; start; echo enter > "$T/tmux-fail"; real; rm -f "$T/tmux-fail"
t "a failed send does not use up the failover allowance" bash -c '! grep -q "_failover" "$1"/quota_resume_state.*.json' _ "$S"
mk realpane 'Quota resets in 5m.' '❯ '

# (5) every walled pane is named
fresh_state; live fx-lane1 fx-lane2 fx-lane3 fx-lane4 fx-lane5 fx-lane6 fx-lane7 fx-lane8 fx-lane9 fx-lane10
t "ten walled panes: ALL TEN are named with their reason, in one line of three segments" bash -c 'for i in 1 2 3 4 5 6 7 8 9 10; do grep -q "fx-lane$i (waits [0-9]* s for the reset)" <<<"$1" || exit 1; done; ! grep -q "more" <<<"$1" && [ "$(grep -o " · " <<<"$1" | wc -l)" = 2 ]' _ "$(line)"

# (6) the failover wait is 120 s exactly; the 30 s of grace is the quota notice's
fo fx-fo 'I cannot run tools.' '❯ '
fresh_state; live fx-fo; age 119; live fx-fo
t "a failover turn 119 s old still waits" grep -qE 'fx-fo \(failover turn, waits [01] s\)' <<<"$(line)"
age 121; live fx-fo
t "…and is resumed at 121 s (120, not 150)" grep -q 'fx-fo (failover turn, resumed)' <<<"$(line)"
mk fx-q 'resets in 42s' '❯ '
fresh_state; live fx-q; age 71; live fx-q
t "a quota notice naming 42 s still waits at 71 s (42 + 30 of grace)" grep -qE 'fx-q \(waits [01] s for the reset\)' <<<"$(line)"
age 73; live fx-q
t "…and is resumed at 73 s" grep -q 'fx-q (resumed)' <<<"$(line)"

# (4) the timer on a lane host: the user's own manager, the user's own tmux server, and a line when that is wrong
echo "no server running on /tmp/tmux-1000/default" > "$T/tmux-mode"; fresh_state; real
t "no tmux server and no claude process of this user: ok, 0 panes (a host without lanes)" grep -q '^CHECK quota-resume-serialhub ok · 0 panes read, 0 walled' <<<"$(L)"
mkdir -p "$T/withclaude/4242"; echo claude > "$T/withclaude/4242/comm"
fresh_state; PROCFIX="$T/withclaude" real
t "no tmux server but claude processes of this user RUN: warn, wrong user or socket (never a silent 0 panes)" grep -q '^CHECK quota-resume-serialhub warn · no tmux server for this user at /tmp/tmux-[0-9]*/default, yet claude processes run here' <<<"$(L)"
rm -f "$T/tmux-mode"
t "the units are plain USER units: no User=, no socket setting, started by the user's timers.target" bash -c '! grep -qE "^(User|Group|Environment=.*TMUX)" "$1/systemd/quota-resume.service" "$1/systemd/quota-resume.timer" && grep -qx "WantedBy=timers.target" "$1/systemd/quota-resume.timer" && grep -q "^OnUnitActiveSec=2min" "$1/systemd/quota-resume.timer"' _ "$ROOT"
CTL="$ROOT/scripts/quota-resume-ctl.sh"; mkdir -p "$T/sbin"
# systemctl: logs; `show … Environment` answers what the manager would: a file, else what a drop-in in the test's
# config dir sets, else nothing; everything else succeeds unless sc-fail exists
cat > "$T/sbin/systemctl" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >> "$T/sc.log"
case "\$*" in
  "--user show quota-resume.service -p Environment --value")
    [ -e "$T/ctl-show-fail" ] && exit 1
    if [ -e "$T/ctl-env" ]; then cat "$T/ctl-env"; else sed -n 's/^Environment=//p' "$T/xdg/systemd/user/quota-resume.service.d/"*.conf 2>/dev/null | tail -1; fi; exit 0 ;;
esac
[ ! -e "$T/sc-fail" ]
EOF
chmod +x "$T/sbin/systemctl"
# the ctl's view of tmux (this shell) and of the user manager (systemd-run): each answers from a file
cat > "$T/sbin/tmux" <<EOF
#!/usr/bin/env bash
echo "tmux \$*" >> "$T/ctl-tmux.log"
case "\$*" in
  "display-message -p #{socket_path}") [ -s "$T/ctl-display" ] && cat "$T/ctl-display" || exit 1 ;;
  "-S "*" list-panes -a -F #{pane_id}") [ -e "$T/ctl-here" ] && cat "$T/ctl-here" || { echo "no server running on \$2" >&2; exit 1; } ;;
esac
EOF
cat > "$T/sbin/systemd-run" <<EOF
#!/usr/bin/env bash
echo "systemd-run \$*" >> "$T/sc.log"
# what the manager-side probe prints: the panes (ctl-mgr), then its last line, unless ctl-mgr-probe says otherwise:
#   none = the probe never ran (no last line)    <number> = it ran and tmux exited with that status
[ -e "$T/ctl-mgr" ] && cat "$T/ctl-mgr"
case "\$(cat "$T/ctl-mgr-probe" 2>/dev/null)" in
  none) exit 1 ;;
  "") echo "probe-ran rc=\$([ -e "$T/ctl-mgr" ] && echo 0 || echo 1)" ;;
  *) echo "probe-ran rc=\$(cat "$T/ctl-mgr-probe")" ;;
esac
EOF
chmod +x "$T/sbin/tmux" "$T/sbin/systemd-run"
: > "$T/sc.log"; XDG_CONFIG_HOME="$T/xdg" TMUX= QUOTA_RESUME_TMUX_SOCKET= PATH="$T/sbin:$PATH" bash "$CTL" install > "$T/out" 2>&1; rc=$?
t "quota-resume-ctl install: links both units into the user manager and enables the timer" bash -c '[ "$1" = 0 ] && grep -qxF "systemctl --user link $2/systemd/quota-resume.service $2/systemd/quota-resume.timer" "$3" && grep -qxF "systemctl --user enable --now quota-resume.timer" "$3" && ! grep -v -- "--user" "$3" | grep -q .' _ "$rc" "$ROOT" "$T/sc.log"
: > "$T/sc.log"; QUOTA_RESUME_CTL_UID=0 XDG_CONFIG_HOME="$T/xdg" TMUX= QUOTA_RESUME_TMUX_SOCKET= PATH="$T/sbin:$PATH" bash "$CTL" install > "$T/out" 2>&1; rc=$?
t "…refused as root (the timer must run as the lanes' user), nothing done" bash -c '[ "$1" = 2 ] && [ ! -s "$2" ]' _ "$rc" "$T/sc.log"
touch "$T/sc-fail"; XDG_CONFIG_HOME="$T/xdg" TMUX= QUOTA_RESUME_TMUX_SOCKET= PATH="$T/sbin:$PATH" bash "$CTL" install > /dev/null 2>&1; rc=$?; rm -f "$T/sc-fail"
t "…a systemctl step that fails is exit 1" [ "$rc" = 1 ]
: > "$T/sc.log"; XDG_CONFIG_HOME="$T/xdg" TMUX= QUOTA_RESUME_TMUX_SOCKET= PATH="$T/sbin:$PATH" bash "$CTL" uninstall > /dev/null 2>&1
t "quota-resume-ctl uninstall disables the timer" grep -qxF "systemctl --user disable --now quota-resume.timer" "$T/sc.log"
bash "$CTL" bogus > /dev/null 2>&1; t "an unknown verb is exit 22" [ "$?" = 22 ]


# ── xreview #283 round 2 (Sen 2026-11-24), final ────────────────────────────────────────────────────────────
DEF="/tmp/tmux-$(id -u)/default"
# (1) a working marker BELOW the input box (where Claude Code draws its footer) is work; one ABOVE the stall is
#     not judged and not typed into
printf '%s\n' '● Working on it' '' "$WALL Quota resets in 5m." '' '────────' '❯ ' '────────' '  esc to interrupt' > "$T/fx-footer"
fresh_state; live fx-footer; seed; live fx-footer
t "'esc to interrupt' BELOW the box: the agent works, the pane is not walled and gets nothing" bash -c 'grep -q "1 panes read, 0 walled" <<<"$1" && ! grep -qs "would resume" "$2"/quota_resume.*.log' _ "$(line)" "$S"
printf '%s\n' '● Working on it' '' "$FO" '' '  I cannot run tools.' '' '────────' '❯ ' '────────' '✢ Wibbling… (3m 49s · ↓ 17.0k tokens)' > "$T/fx-footer2"
fresh_state; live fx-footer2; seed; live fx-footer2
t "a spinner BELOW the box on a failover turn: not walled, nothing typed" bash -c 'grep -q "1 panes read, 0 walled" <<<"$1" && ! grep -qs "would resume" "$2"/quota_resume.*.log' _ "$(line)" "$S"
mk realpane 'Quota resets in 5m.' '❯ '
start; printf '%s\n' '● Working on it' '' "$WALL Quota resets in 5m." '' '────────' '❯ ' '────────' '  esc to interrupt' > "$T/realpane.second"; real
t "RE-CAPTURE: 'esc to interrupt' appeared below the box meanwhile (block and box unchanged): NO key" bash -c '[ "$1" = 0 ]' _ "$(sent)"
start; printf '%s\n' '● Working on it' '' "$WALL Quota resets in 5m." '' '────────' '❯ ' '────────' '✻ Pondering… (12s · ↓ 1.2k tokens)' > "$T/realpane.second"; real
t "RE-CAPTURE: a spinner appeared below the box meanwhile: NO key" bash -c '[ "$1" = 0 ]' _ "$(sent)"
# the second capture differs from the first ONLY above the previous output block: same stall, same turn, empty box
start; printf '%s\n' '  esc to interrupt' '● Working on it' '' "$WALL Quota resets in 5m." '' '────────' '❯ ' '────────' > "$T/realpane.second"; real
t "RE-CAPTURE: a working marker now stands ABOVE the stall (same stall block, same turn, empty box): NO key" bash -c '[ "$1" = 0 ] && grep -q "changed while being looked at" <<<"$2"' _ "$(sent)" "$(L)"
printf '%s\n' '● Earlier output' '✢ Wibbling… (3m 49s · ↓ 17.0k tokens)' '' "$WALL Quota resets in 5m." '' '────────' '❯ ' '────────' > "$T/fx-above"
fresh_state; live fx-above; seed; live fx-above
t "a working marker ABOVE the stall (history or a quote, not judged): never typed into, and NAMED with that reason" bash -c 'grep -q "1 walled: fx-above (a working marker is on screen above the stall: not typed into)" <<<"$1" && ! grep -qs "would resume" "$2"/quota_resume.*.log' _ "$(line)" "$S"

# (2) RULING fix 1: a turn is identified by a DURABLE element, the id of the transcript's last assistant record,
#     not by anything on the screen. The screen below is byte-identical in every step: the stall block and an
#     empty box, nothing else (our stamped message has scrolled away).
resumes() { grep -c "would resume fx-turn" "$S"/quota_resume.*.log 2>/dev/null || true; }
fresh_state; fo fx-turn 'I cannot run tools.' '❯ '; scr=$(sha256sum < "$T/fx-turn"); echo "rec-0001" > "$T/fx-turn.turn"
live fx-turn; age 121; live fx-turn
t "turn 1 (transcript record rec-0001): resumed" bash -c 'grep -q "fx-turn (failover turn, resumed)" <<<"$1" && [ "$2" = 1 ]' _ "$(line)" "$(resumes)"
age 7200; live fx-turn
t "the SAME record id two hours later: still that turn, resumed once already, never typed into again (no clock re-arms a known turn)" bash -c 'grep -q "fx-turn (failover turn, resumed once already, still on the same turn)" <<<"$1" && [ "$2" = 1 ]' _ "$(line)" "$(resumes)"
echo "rec-0002" > "$T/fx-turn.turn"; live fx-turn
t "a NEW record id, the screen byte-identical (the resume message scrolled off): a NEW turn, it waits" bash -c 'grep -qE "fx-turn \(failover turn, waits [0-9]+ s\)" <<<"$1" && [ "$(sha256sum < "$3")" = "$2" ]' _ "$(line)" "$scr" "$T/fx-turn"
age 121; live fx-turn
t "…and is resumed after its own 120 s (2 resumes)" bash -c 'grep -q "fx-turn (failover turn, resumed)" <<<"$1" && [ "$2" = 2 ]' _ "$(line)" "$(resumes)"
echo "rec-0003" > "$T/fx-turn.turn"; live fx-turn; age 121; live fx-turn
t "a third identical answer, another record id: resumed (3 resumes)" bash -c '[ "$1" = 3 ]' _ "$(resumes)"
echo "rec-0004" > "$T/fx-turn.turn"; live fx-turn; age 121; live fx-turn
t "the fourth reaches the hourly allowance and is HELD there (identical turns are counted, not lost)" bash -c 'grep -q "fx-turn (failover turn, 3 resumes already this hour: held)" <<<"$1" && [ "$2" = 3 ]' _ "$(line)" "$(resumes)"
t "with a transcript, the line carries no fallback note" bash -c '! grep -q "no transcript found" <<<"$1"' _ "$(line)"
# no transcript to read (no sidecar): time tells the turns apart, and the line says so; never held for ever
rm -f "$T/fx-turn.turn"; fresh_state; live fx-turn; age 121; live fx-turn
t "NO transcript: resumed, and the line says turns are told apart by time for that pane" bash -c 'grep -q "fx-turn (failover turn, resumed); no transcript found for fx-turn: turns told apart by time" <<<"$1" && [ "$2" = 1 ]' _ "$(line)" "$(resumes)"
live fx-turn
t "NO transcript, a moment later: resumed once already (not typed into twice in a row)" bash -c 'grep -q "fx-turn (failover turn, resumed once already" <<<"$1" && [ "$2" = 1 ]' _ "$(line)" "$(resumes)"
age 121; live fx-turn
t "NO transcript, still stalled a full wait later: treated as a new turn and resumed (2), not held for ever" bash -c '[ "$1" = 2 ]' _ "$(resumes)"
age 121; live fx-turn; age 121; live fx-turn
t "…and the hourly allowance still ends it (3 resumes, then held)" bash -c 'grep -q "3 resumes already this hour: held" <<<"$1" && [ "$2" = 3 ]' _ "$(line)" "$(resumes)"
mk fx-qwall 'Quota resets in 5m.' '❯ '; fresh_state; live fx-qwall; age 7200; live fx-qwall; age 7200; live fx-qwall
t "a QUOTA notice without a transcript is not re-armed by time (the fallback is for failover turns only)" bash -c 'grep -q "fx-qwall (resumed once already" <<<"$1" && [ "$(grep -c "would resume fx-qwall" "$2"/quota_resume.*.log)" = 1 ]' _ "$(line)" "$S"

# the REAL path: the pane's shell → its claude process → that process's directory and session id → the transcript
SIDX=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee; mkdir -p "$T/lanecwd" "$T/proj"
LC=$(cd "$T/lanecwd" && pwd -P); TX="$T/proj/$(printf '%s' "$LC" | sed 's/[^A-Za-z0-9]/-/g')/$SIDX.jsonl"; mkdir -p "$(dirname "$TX")"
pfix() {  # pfix <argv, NUL-separated by spaces here>: a fake /proc: 4242 the pane's shell, 4300 its child named claude
  rm -rf "$T/pf"; mkdir -p "$T/pf/4242" "$T/pf/4300" "$T/pf/4243"
  echo "4242 (bash) S 1 4242 4242 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 100 0 0" > "$T/pf/4242/stat"; echo bash > "$T/pf/4242/comm"
  echo "4243 (bash) S 1 4243 4243 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 100 0 0" > "$T/pf/4243/stat"; echo bash > "$T/pf/4243/comm"
  echo "4300 (claude) S 4242 4300 4242 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 200 0 0" > "$T/pf/4300/stat"; echo claude > "$T/pf/4300/comm"
  printf '%s\0' "$@" > "$T/pf/4300/cmdline"; ln -s "$LC" "$T/pf/4300/cwd"
}
arec() { printf '{"type":"assistant","uuid":"%s","message":{"model":"qwen (failover)"}}\n' "$1"; }
rreal() { PROCFIX="$T/pf" QUOTA_RESUME_PROJECTS_DIR="$T/proj" real; }
fo realpane 'I cannot run tools.' '❯ '; pfix claude --resume "$SIDX" --permission-mode bypassPermissions; arec uuid-0001 > "$TX"
fresh_state; rm -f "$T/cap.count" "$T/realpane.second" "$T/tmux-fail" "$T/append-on-second"; : > "$T/tmux.log"; rreal; age 121; rm -f "$T/cap.count"; : > "$T/tmux.log"; rreal
t "REAL path: the transcript is found through the pane's process (--resume <id>, its directory): resumed, no fallback note" bash -c 'grep -q "morpheus-topology (failover turn, resumed)" <<<"$1" && ! grep -q "no transcript found" <<<"$1" && [ "$2" = 3 ]' _ "$(L)" "$(sent)"
printf '{"type":"last-prompt","sessionId":"x"}\n{"type":"user","uuid":"user-0001","message":{"content":"queued"}}\n{"type":"system","uuid":"sys-0001","subject":"assistant"}\n{"type":"mode","mode":"x"}\n' >> "$TX"; age 7200; rm -f "$T/cap.count"; : > "$T/tmux.log"; rreal
t "REAL path: records after it that are NOT the model's (bookkeeping; a user and a system record with ids of their own, one holding the string \"assistant\" as a value) do not make a new turn: resumed once already, no key" bash -c 'grep -q "resumed once already" <<<"$1" && [ "$2" = 0 ]' _ "$(L)" "$(sent)"
arec uuid-0002 >> "$TX"; rm -f "$T/cap.count"; : > "$T/tmux.log"; rreal
t "REAL path: a NEW assistant record, the pane's screen unchanged: a new turn, it waits" bash -c 'grep -qE "morpheus-topology \(failover turn, waits [0-9]+ s\)" <<<"$1" && [ "$2" = 0 ]' _ "$(L)" "$(sent)"
# the turn changes BETWEEN the first look and the send: the stub appends a record to the transcript at the second capture
age 121; arec uuid-0003 > "$T/append-on-second"; echo "$TX" > "$T/append-to"; rm -f "$T/cap.count"; : > "$T/tmux.log"; rreal; rm -f "$T/append-on-second"
t "RE-CAPTURE: a new transcript record arrived between the two looks (the screen identical): NO key" bash -c '[ "$1" = 0 ] && grep -q "changed while being looked at" <<<"$2"' _ "$(sent)" "$(L)"
pfix claude "--resume=$SIDX"; arec uuid-0009 > "$TX"; fresh_state; rm -f "$T/cap.count"; : > "$T/tmux.log"; rreal
t "REAL path: the id given as --resume=<id> is found too" bash -c '! grep -q "no transcript found" <<<"$1" && grep -q "failover turn, waits" <<<"$1"' _ "$(L)"
pfix claude --model x; fresh_state; rm -f "$T/cap.count"; rreal
t "REAL path: a claude process with NO id on its command line: the line says no transcript was found for that lane" bash -c 'grep -q "no transcript found for morpheus-topology: turns told apart by time" <<<"$1"' _ "$(L)"
pfix claude --resume "$SIDX"; chmod 000 "$TX"; fresh_state; rm -f "$T/cap.count"; rreal; chmod 600 "$TX"
t "REAL path: a transcript that cannot be read: the same note, no crash" bash -c 'grep -q "no transcript found for morpheus-topology" <<<"$1" && ! grep -q Traceback "$2"' _ "$(L)" "$T/out"
M1='continue (auto-resume: your last turn was served by the local failover model and did nothing; a seat serves again) [12:00:01]'
# between the first look and the send a NEW turn arrived with the very same answer: same stall block, another turn
printf '%s\n' '● Working on it' '' '> do the thing' '' "$FO" '' '  I cannot run tools.' '' '────────' '❯ ' '────────' > "$T/realpane"; start
printf '%s\n' "$FO" '' '  I cannot run tools.' '' "> $M1" '' "$FO" '' '  I cannot run tools.' '' '────────' '❯ ' '────────' > "$T/realpane.second"; real
t "RE-CAPTURE: the same answer text but ANOTHER turn (someone resumed it meanwhile): NO key, looked at again next run" bash -c '[ "$1" = 0 ] && grep -q "changed while being looked at" <<<"$2"' _ "$(sent)" "$(L)"
fo realpane 'I cannot run tools.' '❯ '; start; real
t "the typed message carries the time of the resume (what makes the next turn differ)" grep -qE 'tmux send-keys -t %7 -l continue \(auto-resume: .*\) \[[0-9]{2}:[0-9]{2}:[0-9]{2}\]$' "$T/tmux.log"
mk realpane 'Quota resets in 5m.' '❯ '; start; real
t "…the quota message too" grep -qE 'tmux send-keys -t %7 -l continue \(jp-ab auto-resume after quota reset\) \[[0-9]{2}:[0-9]{2}:[0-9]{2}\]$' "$T/tmux.log"

# (3) the tmux socket is explicit in every call
: > "$T/sock.log"; start; real
t "every tmux call names the socket: the default one of this user, with no setting" bash -c '[ -s "$1" ] && ! grep -q NO-SOCKET "$1" && [ "$(sort -u "$1")" = "$2" ] && [ "$(wc -l < "$1")" -ge 6 ]' _ "$T/sock.log" "$DEF"
: > "$T/sock.log"; fresh_state; rm -f "$T/cap.count"; QUOTA_RESUME_TMUX_SOCKET=/run/user/77/lanes.sock real
t "…and QUOTA_RESUME_TMUX_SOCKET when set, in every call" bash -c '[ "$(sort -u "$1")" = /run/user/77/lanes.sock ]' _ "$T/sock.log"
echo "no server running on /run/user/77/lanes.sock" > "$T/tmux-mode"; fresh_state; QUOTA_RESUME_TMUX_SOCKET=/run/user/77/lanes.sock PROCFIX="$T/withclaude" real; rm -f "$T/tmux-mode"
t "the wrong-socket warning NAMES the socket it looked at" grep -q 'warn · no tmux server for this user at /run/user/77/lanes.sock, yet claude processes run here' <<<"$(L)"
out=$(PATH="$T/bin:$PATH" QUOTA_RESUME_TMUX_SOCKET=/run/user/77/lanes.sock QUOTA_RESUME_QUOTA_FILE="$T/q.json" python3 -I "$ROOT/scripts/quota_resume.py" --dry-run 2>&1)
t "a dry run ends by saying how many panes it read and through which socket" grep -qx 'dry-run: 2 panes read via /run/user/77/lanes.sock' <<<"$out"

# the installer: finds the lanes' socket, proves the user manager reaches it, and only then enables
ctl() { XDG_CONFIG_HOME="$T/xdg" PATH="$T/sbin:$PATH" bash "$CTL" "$@" > "$T/out" 2>&1; }
DROPF="$T/xdg/systemd/user/quota-resume.service.d/10-tmux-socket.conf"
cclean() { rm -rf "$T/xdg" "$T/ctl-display" "$T/ctl-here" "$T/ctl-mgr" "$T/ctl-mgr-probe" "$T/ctl-env" "$T/ctl-show-fail"; : > "$T/sc.log"; : > "$T/ctl-tmux.log"; }
cclean; echo "$DEF" > "$T/ctl-display"; printf '%%1\n%%2\n' > "$T/ctl-here"; printf '%%2\n%%1\n' > "$T/ctl-mgr"; TMUX= QUOTA_RESUME_TMUX_SOCKET= ctl install; rc=$?
t "install, lanes on the default socket: proved through the user manager, enabled, NO drop-in" bash -c '[ "$1" = 0 ] && grep -q "proof: a process started by the user manager lists the same 2 pane(s) on $2 as this shell" "$3" && grep -q "^systemd-run --user --wait --pipe --quiet --collect sh -c .*probe-ran rc=.* _ $2\$" "$4" && grep -q "enable --now quota-resume.timer" "$4" && [ ! -e "$5" ]' _ "$rc" "$DEF" "$T/out" "$T/sc.log" "$DROPF"
cclean; printf '%%1\n' > "$T/ctl-here"; printf '%%1\n' > "$T/ctl-mgr"; TMUX="/var/lanes/tmux.sock,4321,0" QUOTA_RESUME_TMUX_SOCKET= ctl install; rc=$?
t "install from inside a lane's tmux on ANOTHER socket: that socket is used, proved, and written to the drop-in" bash -c '[ "$1" = 0 ] && grep -q "tmux socket: /var/lanes/tmux.sock (from this shell.s TMUX)" "$2" && grep -q "^systemd-run .* _ /var/lanes/tmux.sock\$" "$3" && grep -qxF "Environment=QUOTA_RESUME_TMUX_SOCKET=/var/lanes/tmux.sock" "$4" && grep -qx "\[Service\]" "$4"' _ "$rc" "$T/out" "$T/sc.log" "$DROPF"
: > "$T/sc.log"; TMUX= QUOTA_RESUME_TMUX_SOCKET= ctl status; rc=$?
t "status: the socket in force is the drop-in's, and the proof is run on it" bash -c '[ "$1" = 0 ] && grep -q "tmux socket in force: /var/lanes/tmux.sock (from what the user manager says the service uses" "$2" && grep -q "^systemd-run .* _ /var/lanes/tmux.sock\$" "$3" && grep -q "^proof: " "$2"' _ "$rc" "$T/out" "$T/sc.log"
echo "$DEF" > "$T/ctl-display"; TMUX= QUOTA_RESUME_TMUX_SOCKET= ctl install
t "a later install on the default socket removes OUR drop-in" [ ! -e "$DROPF" ]
# RULING fix 2: a drop-in that is NOT ours names another socket. It is left alone, AND the install is refused: the
# service would use that socket, not the one that was chosen and would be proved
mkdir -p "$(dirname "$DROPF")"; printf '[Service]\nEnvironment=QUOTA_RESUME_TMUX_SOCKET=/someone/elses\n' > "$DROPF"; : > "$T/sc.log"; TMUX= QUOTA_RESUME_TMUX_SOCKET= ctl install; rc=$?
t "a foreign drop-in names ANOTHER socket: exit 3, the timer is NOT enabled, and the message names both sockets" bash -c '[ "$1" = 3 ] && ! grep -q "enable" "$2" && grep -q "the service would use /someone/elses, not $4" "$3"' _ "$rc" "$T/sc.log" "$T/out" "$DEF"
t "…and nothing was proved on a socket the service would not use (no probe ran)" bash -c '! grep -q "^systemd-run" "$1"' _ "$T/sc.log"
TMUX= QUOTA_RESUME_TMUX_SOCKET= ctl uninstall
t "…the foreign drop-in itself is left alone by install and uninstall" grep -qx 'Environment=QUOTA_RESUME_TMUX_SOCKET=/someone/elses' "$DROPF"
: > "$T/sc.log"; printf '%%1\n' > "$T/ctl-here"; printf '%%1\n' > "$T/ctl-mgr"; TMUX= QUOTA_RESUME_TMUX_SOCKET=/someone/elses ctl install; rc=$?
t "…installing FOR that socket by name is accepted: the chosen, the effective and the proved socket are one" bash -c '[ "$1" = 0 ] && grep -q "^systemd-run .* _ /someone/elses\$" "$2" && grep -q "enable --now" "$2"' _ "$rc" "$T/sc.log"
rm -rf "$T/xdg"
cclean; echo "$DEF" > "$T/ctl-display"; printf '%%1\n' > "$T/ctl-here"; printf '%%1\n' > "$T/ctl-mgr"; echo "QUOTA_RESUME_TMUX_SOCKET=/from/an/environment.d" > "$T/ctl-env"; TMUX= QUOTA_RESUME_TMUX_SOCKET= ctl install; rc=$?
t "the manager reports another socket for the service from ANYWHERE (not a drop-in of ours): exit 3, not enabled" bash -c '[ "$1" = 3 ] && ! grep -q "enable" "$2"' _ "$rc" "$T/sc.log"
cclean; echo "$DEF" > "$T/ctl-display"; printf '%%1\n' > "$T/ctl-here"; printf '%%1\n' > "$T/ctl-mgr"; touch "$T/ctl-show-fail"; TMUX= QUOTA_RESUME_TMUX_SOCKET= ctl install; rc=$?
t "the manager cannot say which socket the service will use: exit 3, not enabled" bash -c '[ "$1" = 3 ] && ! grep -q "enable" "$2"' _ "$rc" "$T/sc.log"
cclean; printf '%%1\n' > "$T/ctl-here"; printf '%%1\n' > "$T/ctl-mgr"; TMUX="/var/lanes/tmux.sock,4321,0" QUOTA_RESUME_TMUX_SOCKET=/srv/x/explicit.sock ctl install
t "QUOTA_RESUME_TMUX_SOCKET wins over TMUX" grep -qxF "Environment=QUOTA_RESUME_TMUX_SOCKET=/srv/x/explicit.sock" "$DROPF"
TMUX= QUOTA_RESUME_TMUX_SOCKET= ctl uninstall
t "uninstall removes our drop-in" [ ! -e "$DROPF" ]
cclean; echo "$DEF" > "$T/ctl-display"; printf '%%1\n%%2\n' > "$T/ctl-here"; printf '%%9\n' > "$T/ctl-mgr"; TMUX= QUOTA_RESUME_TMUX_SOCKET= ctl install; rc=$?
t "the user manager sees OTHER panes than this shell (another server): exit 3, the timer is NOT enabled" bash -c '[ "$1" = 3 ] && grep -q "proof FAILED" "$2" && ! grep -q "enable" "$3"' _ "$rc" "$T/out" "$T/sc.log"
cclean; echo "$DEF" > "$T/ctl-display"; printf '%%1\n%%2\n' > "$T/ctl-here"; printf '%%1\n%%2\n' > "$T/ctl-mgr"; echo none > "$T/ctl-mgr-probe"; TMUX= QUOTA_RESUME_TMUX_SOCKET= ctl install; rc=$?
t "the manager's probe did not RUN (no last line), whatever was printed: exit 3, not enabled" bash -c '[ "$1" = 3 ] && ! grep -q "enable" "$2" && grep -q "the probe did not run in the user manager" "$3"' _ "$rc" "$T/sc.log" "$T/out"
# RULING fix 3: EMPTY outputs on both sides and a probe that did not run. This used to read "no server, alike".
cclean; echo "$DEF" > "$T/ctl-display"; echo none > "$T/ctl-mgr-probe"; TMUX= QUOTA_RESUME_TMUX_SOCKET= ctl install; rc=$?
t "EMPTY output from both sides and the manager's probe did not run: a FAILURE (exit 3, not enabled), never 'no server'" bash -c '[ "$1" = 3 ] && ! grep -q "enable" "$2" && ! grep -q "neither finds a tmux server" "$3"' _ "$rc" "$T/sc.log" "$T/out"
cclean; echo "$DEF" > "$T/ctl-display"; echo 127 > "$T/ctl-mgr-probe"; TMUX= QUOTA_RESUME_TMUX_SOCKET= ctl install; rc=$?
t "the manager's probe ran but could not execute tmux (rc 127), empty output: exit 3, not enabled" bash -c '[ "$1" = 3 ] && ! grep -q "enable" "$2" && grep -q "tmux could not be run" "$3"' _ "$rc" "$T/sc.log" "$T/out"
cclean; echo "$DEF" > "$T/ctl-display"; TMUX= QUOTA_RESUME_TMUX_SOCKET= ctl install; rc=$?
t "both probes RAN and neither finds a server (tmux rc 1 on both sides): said so, and enabled" bash -c '[ "$1" = 0 ] && grep -q "both probes ran and neither finds a tmux server" "$3" && grep -q "enable --now" "$2"' _ "$rc" "$T/sc.log" "$T/out"
cclean; TMUX="/var/lanes/tmux.sock,1,0" QUOTA_RESUME_TMUX_SOCKET= ctl install; rc=$?
t "another socket with the manager not reaching it and this shell seeing none: no drop-in guesswork is hidden (said, enabled)" bash -c '[ "$1" = 0 ] && grep -q "proof: both probes ran and neither finds a tmux server on /var/lanes/tmux.sock" "$2"' _ "$rc" "$T/out"
cclean; TMUX= QUOTA_RESUME_TMUX_SOCKET='/x y; touch /nope' ctl install; rc=$?
t "a socket path that is not plain: exit 2, nothing linked, nothing written" bash -c '[ "$1" = 2 ] && ! grep -q "link\|enable" "$2" && [ ! -e "$3" ]' _ "$rc" "$T/sc.log" "$DROPF"

# THE SOCKET PATH, FOR REAL (where this host has a user manager): a throwaway tmux server on a private socket holds
# a pane showing a wall; quota_resume.py is started BY THE USER MANAGER (systemd-run --user, its environment, not
# this shell's) and must read that pane, then type into it. Every call names the private socket, so no other
# server can be reached; a dry run through the manager must first name that socket, or the real runs do not happen.
if systemd-run --user --wait --pipe --quiet --collect true 2>/dev/null && command -v tmux > /dev/null; then
  RS="$T/rstate"; RC="$T/rchecks"; mkdir -p "$RS" "$RC"; mk wallfx 'Quota resets in 5m.' '❯ '
  env -u TMUX tmux -S "$T/lanes.sock" new-session -d -s fx-sock -x 170 -y 30 "cat '$T/wallfx'; sleep 90" 2>/dev/null; sleep 0.8
  mgr() { systemd-run --user --wait --pipe --quiet --collect -E QUOTA_RESUME_TMUX_SOCKET="$1" -E QUOTA_RESUME_QUOTA_FILE="$T/q.json" -E QUOTA_RESUME_STATE_DIR="$RS" \
            -E DREAMTEAM_CHECKS_DIR="$RC" -E DREAMTEAM_CHECK_HOST=fxhost -E QUOTA_RESUME_PROC="$T/noclaude" /usr/bin/python3 -I "$ROOT/scripts/quota_resume.py" "${@:2}" 2>&1; }
  out=$(mgr "$T/lanes.sock" --dry-run)
  if grep -qx "dry-run: 1 panes read via $T/lanes.sock" <<<"$out"; then
    echo "PASS: REAL: started by the user manager, the script reads the one pane of the server on the private socket"
    t "REAL: …and sees that pane's wall" grep -q '^match %' <<<"$out"
    out=$(mgr "$T/none.sock" --dry-run)
    t "REAL control: another socket path reaches no server (0 panes), so the socket is what decides" grep -qx "dry-run: 0 panes read via $T/none.sock (no server on that socket)" <<<"$out"
    mgr "$T/lanes.sock" > /dev/null
    t "REAL: first run through the manager: the line names the tmux SESSION on that socket, waiting" grep -q 'warn · 1 panes read, 1 walled: fx-sock (waits' "$RC/quota-resume-fxhost.line"
    python3 -I -c 'import json, sys, time, glob
for f in glob.glob(sys.argv[1] + "/quota_resume_state.*.json"):
    d = json.load(open(f)); [v.__setitem__("first", time.time() - 7200) for v in d.values() if isinstance(v, dict)]; json.dump(d, open(f, "w"))' "$RS"
    mgr "$T/lanes.sock" > /dev/null; sleep 0.5
    t "REAL: reset passed: the run started by the user manager TYPES into that pane (the text is on its screen)" bash -c 'tmux -S "$1" capture-pane -p -t fx-sock | grep -q "continue (jp-ab auto-resume after quota reset) \[[0-9:]*\]" && grep -q "fx-sock (resumed)" "$2"' _ "$T/lanes.sock" "$RC/quota-resume-fxhost.line"
  else
    echo "FAIL: REAL: the user manager's run did not read the private socket's pane: $out"; fail=1
  fi
  tmux -S "$T/lanes.sock" kill-server 2>/dev/null
else
  echo "SKIP: REAL socket-path cases: no user manager reachable here (systemd-run --user failed)"
fi

exit $fail
