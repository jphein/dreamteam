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
t "the same notice a run later: said so, not resumed twice" bash -c 'grep -q "fx-luna (resumed once already, still on the notice)" <<<"$1" && [ "$(grep -c "would resume" "$2"/quota_resume.*.log)" = 1 ]' _ "$(line)" "$S"

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
echo "tmux \$*" >> "$T/tmux.log"
case "\$*" in
  list-panes*) [ -e "$T/tmux-mode" ] && { cat "$T/tmux-mode" >&2; exit 1; }; printf '%%7 morpheus-topology claude\n%%9 scratch bash\n' ;;
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
echo "tmux \$*" >> "$T/tmux.log"
case "\$*" in
  list-panes*) [ -e "$T/tmux-mode" ] && { cat "$T/tmux-mode" >&2; exit 1; }; printf '%%7 morpheus-topology claude\n%%9 scratch bash\n' ;;
  "capture-pane -e -p -t %7") n=\$(( \$(cat "$T/cap.count" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$T/cap.count"
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
    d = json.load(open(f)); [v.__setitem__("first", time.time() - float(sys.argv[2])) for v in d.values() if isinstance(v, dict)]; json.dump(d, open(f, "w"))' "$S" "$1"
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
t "no tmux server but claude processes of this user RUN: warn, wrong user or socket (never a silent 0 panes)" grep -q '^CHECK quota-resume-serialhub warn · no tmux server for this user, yet claude processes run here' <<<"$(L)"
rm -f "$T/tmux-mode"
t "the units are plain USER units: no User=, no socket setting, started by the user's timers.target" bash -c '! grep -qE "^(User|Group|Environment=.*TMUX)" "$1/systemd/quota-resume.service" "$1/systemd/quota-resume.timer" && grep -qx "WantedBy=timers.target" "$1/systemd/quota-resume.timer" && grep -q "^OnUnitActiveSec=2min" "$1/systemd/quota-resume.timer"' _ "$ROOT"
CTL="$ROOT/scripts/quota-resume-ctl.sh"; mkdir -p "$T/sbin"
printf '#!/usr/bin/env bash\necho "systemctl $*" >> "%s/sc.log"\n[ ! -e "%s/sc-fail" ]\n' "$T" "$T" > "$T/sbin/systemctl"; chmod +x "$T/sbin/systemctl"
: > "$T/sc.log"; PATH="$T/sbin:$PATH" bash "$CTL" install > "$T/out" 2>&1; rc=$?
t "quota-resume-ctl install: links both units into the user manager and enables the timer" bash -c '[ "$1" = 0 ] && grep -qxF "systemctl --user link $2/systemd/quota-resume.service $2/systemd/quota-resume.timer" "$3" && grep -qxF "systemctl --user enable --now quota-resume.timer" "$3" && ! grep -v -- "--user" "$3" | grep -q .' _ "$rc" "$ROOT" "$T/sc.log"
: > "$T/sc.log"; QUOTA_RESUME_CTL_UID=0 PATH="$T/sbin:$PATH" bash "$CTL" install > "$T/out" 2>&1; rc=$?
t "…refused as root (the timer must run as the lanes' user), nothing done" bash -c '[ "$1" = 2 ] && [ ! -s "$2" ]' _ "$rc" "$T/sc.log"
touch "$T/sc-fail"; PATH="$T/sbin:$PATH" bash "$CTL" install > /dev/null 2>&1; rc=$?; rm -f "$T/sc-fail"
t "…a systemctl step that fails is exit 1" [ "$rc" = 1 ]
: > "$T/sc.log"; PATH="$T/sbin:$PATH" bash "$CTL" uninstall > /dev/null 2>&1
t "quota-resume-ctl uninstall disables the timer" grep -qxF "systemctl --user disable --now quota-resume.timer" "$T/sc.log"
bash "$CTL" bogus > /dev/null 2>&1; t "an unknown verb is exit 22" [ "$?" = 22 ]

exit $fail
