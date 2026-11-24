#!/usr/bin/env bash
# dreamteam — PERTURBATIONS for the GPU lane footprint, the host lock and the reservations (dreamteam #280, PR A of
# the #256 split): one mutation per rule, applied to a COPY of the tree, its suite run from the copy; every mutation
# must turn at least one case red. The table in the PR body is this script's output at the PR head.
#
#   bash tests/perturb-gpu-reservations.sh [tree]     # exit 0 iff every mutation is red; default tree = this repo
#
# Not a test-*.sh: run.sh would run two suites once per mutation. Run it by hand before asking for a review.
set -u
SRC="${1:-$(cd "$(dirname "$0")/.." && pwd)}"; TMP=$(mktemp -d -p "${TMPDIR:-$HOME/.cache/tmp}"); trap 'rm -rf -- "$TMP"' EXIT
# name@file@sed expression@suite  (the @ separator: expressions carry | and /)
MUT=(
  'subtraction-dropped@scripts/lib/gpu_fleet.py@s/^        eff_lim = lim - lane_mb$/        eff_lim = lim/@tests/test-gpu.sh'
  'asleep-admits@scripts/lib/gpu_fleet.py@s/^    if not p.get("reachable"):$/    if False:/@tests/test-gpu.sh'
  'lane-err-as-zero@scripts/lib/gpu_fleet.py@s/^    if p.get("lane_err"):$/    if False:/@tests/test-gpu.sh'
  'no-lane-line-admits@scripts/lib/gpu_fleet.py@s/^    if "lane_mb" not in p or "resv_mb" not in p:$/    if "resv_mb" not in p:/@tests/test-gpu.sh'
  'lock-failure-admits@scripts/lib/gpu_fleet.py@s/^        if line != "LOCKED":$/        if False:/@tests/test-gpu.sh'
  'ledger-before-hostlock-in-claim@scripts/lib/gpu_fleet.py@s/^    with HostLock(fleet, host), Ledger(write=not a.dry_run) as L:/    with Ledger(write=not a.dry_run) as L, HostLock(fleet, host):/@tests/test-gpu.sh'
  'ledger-before-hostlock-in-admit@scripts/lib/gpu_fleet.py@s/^    with HostLock(fleet, host), Ledger(write=True) as L:   # the lock spans the peak recheck/    with Ledger(write=True) as L, HostLock(fleet, host):   # the lock spans the peak recheck/@tests/test-gpu.sh'
  'sampler-failure-as-zero@scripts/lib/gpu_fleet.py@s/; else echo LANE,ERR; fi$/; else echo LANE,OK,0; fi/@tests/test-gpu.sh'
  'lanes-flag-ignored@scripts/lib/gpu_fleet.py@s/^    if not h.get("lanes"):$/    if True:/@tests/test-gpu.sh'
  'reservation-ignored@scripts/lib/gpu_fleet.py@s/^    total = p\["lane_mb"\] + p\["resv_mb"\]$/    total = p["lane_mb"]/@tests/test-gpu.sh'
  'no-resv-line-admits@scripts/lib/gpu_fleet.py@s/^    if "lane_mb" not in p or "resv_mb" not in p:$/    if "lane_mb" not in p:/@tests/test-gpu.sh'
  'resv-err-as-zero@scripts/lib/gpu_fleet.py@s/else echo "RESV,ERR"; fi$/else echo "RESV,OK,0"; fi/@tests/test-gpu.sh'
  'probe-started-expires@scripts/lib/gpu_fleet.py@s/if \[ "\$st" != 0 \] || \[ "\$((10#\$exp))" -gt "\$now" \]; then r=\$((r + 10#\$mb)); fi; done/if [ "$((10#$exp))" -gt "$now" ]; then r=$((r + 10#$mb)); fi; done/@tests/test-gpu.sh'
  'probe-mutates@scripts/lib/gpu_fleet.py@s/if \[ "\$st" != 0 \] || \[ "\$((10#\$exp))" -gt "\$now" \]; then r=\$((r + 10#\$mb)); fi; done/if [ "$st" != 0 ] || [ "$((10#$exp))" -gt "$now" ]; then r=$((r + 10#$mb)); else mv -f -- "$f" "$f.expired"; fi; done/@tests/test-gpu.sh'
  'probe-exp-digits-unchecked@scripts/lib/gpu_fleet.py@s/\*\[!0-9\]\*|0\[0-9\]\*) ok=0; break ;; esac; case "\${st:-}"/*[!0-9]*|0[0-9]*) true ;; esac; case "${st:-}"/@tests/test-gpu.sh'
  'probe-leading-zero-accepted@scripts/lib/gpu_fleet.py@s/case "\$mb" in '"'"''"'"'|\*\[!0-9\]\*|0\[0-9\]\*) ok=0/case "$mb" in '"'"''"'"'|*[!0-9]*) ok=0/@tests/test-gpu.sh'
  'probe-rule-drift-started-field@scripts/lib/gpu_fleet.py@s/case "\${st:-}" in '"'"''"'"'|\*\[!0-9\]\*) ok=0; break ;; esac/true/@tests/test-gpu.sh'
  'probe-dir-not-checked@scripts/lib/gpu_fleet.py@s/if ! \[ -d "\$d" \] || ! \[ -r "\$d" \] || ! \[ -x "\$d" \]; then ok=0; else/if false; then ok=0; else/@tests/test-gpu.sh'
  'resv-line-dropped@scripts/lib/gpu_fleet.py@s/^if \[ "\$ok" = 1 \]; then echo "RESV,OK,\$r"; else echo "RESV,ERR"; fi$/true/@tests/test-gpu.sh'
  'gate-lock-not-taken@scripts/mem-gate.sh@s/^flock -w "\$HLOCK_WAIT" 9 || invalid/true || invalid/@tests/test-gates.sh'
  'gate-no-reservation@scripts/mem-gate.sh@s/^bash "\$RSV" add "\$PER_AGENT" 90 "\$SESSION" "\$ATYPE" --locked >\/dev\/null || invalid/true || invalid/@tests/test-gates.sh'
  'gate-reservations-not-subtracted@scripts/mem-gate.sh@s/^AVAIL=\$(( AVAIL - RESV_MB ))/AVAIL=$(( AVAIL - 0 ))/@tests/test-gates.sh'
  'gate-reserved-slots-uncounted@scripts/mem-gate.sh@s/^NAGENTS=\$(( NAGENTS + RESV_N ))/NAGENTS=$(( NAGENTS + 0 ))/@tests/test-gates.sh'
  'start-not-locked@scripts/reservation.sh@s/^take_lock() {   # the host lock/take_lock() { return 0;   # the host lock/@tests/test-gates.sh'
  'read-unlocked@scripts/reservation.sh@s/^  \[ "\$LOCKED" = 1 \] \&\& return 0$/  return 0/@tests/test-gates.sh'
  'start-ignores-token@scripts/reservation.sh@s/if \[ "\$6" = counting \] \&\& \[ "\$3" = "\$ses" \] \&\& \[ "\$4" = "\$typ" \] \&\& \[ "\$5" = 0 \]; then/if [ "$6" = counting ] \&\& [ "$5" = 0 ]; then/@tests/test-gates.sh'
  'scan-deletes-malformed@scripts/reservation.sh@s/|| { echo "reservation: malformed \$1" >\&2; return 1; }/|| { rm -f -- "$1"; return 1; }/@tests/test-gates.sh'
  'scan-not-all-or-nothing@scripts/reservation.sh@0,/^    parse "\$f" || return 1$/s//    parse "$f" || continue/@tests/test-gates.sh'
  'prune-before-scan@scripts/reservation.sh@s/scan acc || { echo "reservation: scan failed, nothing counted" >\&2; exit 1; }; prune || { echo "reservation: prune failed" >\&2; exit 1; }/prune; scan acc || exit 1/@tests/test-gates.sh'
  'tombstones-validated-after-prune@scripts/reservation.sh@s/^    for f in "\$DIR"\/\*.expired; do \[ -e "\$f" \] || continue; parse "\$f" || exit 1; done   # tombstones validated/    true   # tombstones validated/@tests/test-gates.sh'
  'unreadable-dir-as-zero@scripts/reservation.sh@s/|| { echo "reservation: \$DIR is not a readable directory" >\&2; return 1; }/|| return 2/@tests/test-gates.sh'
  'started-expires@scripts/reservation.sh@s/^expired() { \[ "\$fst" = 0 \] \&\& /expired() { true \&\& /@tests/test-gates.sh'
  'tombstone-dropped@scripts/reservation.sh@s/    if expired; then mv -f -- "\$f" "\$f.expired" || return 1; fi/    if expired; then rm -f -- "$f"; fi/@tests/test-gates.sh'
  'tombstone-deleted-before-append@scripts/reservation.sh@s/^        if printf '"'"'%s late start:/        rm -f -- "$f"; if printf '"'"'%s late start:/@tests/test-gates.sh'
  'leading-zero-accepted@scripts/reservation.sh@s/^valid() { case "\${1:-}" in '"'"''"'"'|\*\[!0-9\]\*|0\[0-9\]\*) return 1 ;; esac;/valid() { case "${1:-}" in '"'"''"'"'|*[!0-9]*) return 1 ;; esac;/@tests/test-gates.sh'
  'stop-ignores-id@scripts/reservation.sh@s/^      \[ "\$id" != - \] \&\& \[ "\$7" = "\$id" \] \&\& byid="\$1"$/      true/@tests/test-gates.sh'
  'tombstones-read-after-scan@scripts/reservation.sh@0,/^    late_start "\$ses" "\$typ" "\$ag"      # tombstones BEFORE/s//    true   # tombstones BEFORE/@tests/test-gates.sh'
  'eacces-as-never-existed@scripts/reservation.sh@s/^  echo "reservation: cannot reach \$DIR: \$st" >\&2; return 1$/  return 2/@tests/test-gates.sh'
  'probe-eacces-as-zero@scripts/lib/gpu_fleet.py@s/else case "\$dst" in \*"No such file or directory"\*) : ;; \*) ok=0 ;; esac; fi$/else :; fi/@tests/test-gpu.sh'
  'id-not-stamped@scripts/mem-gate.sh@s/\.prompt = ("\[dreamteam reservation " + \$id + "\]\\n" + (\.prompt \/\/ ""))/.prompt = (.prompt \/\/ "")/@tests/test-gates.sh'
  'permission-decision-added@scripts/mem-gate.sh@s/{hookSpecificOutput: {hookEventName: "PreToolUse",$/{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow",/@tests/test-gates.sh'
  'id-not-random@scripts/mem-gate.sh@s/^RID=\$(od -An -tx1 -N16 \/dev\/urandom 2>\/dev\/null | tr -d '"'"' \\n'"'"')/RID="r-$$-$RANDOM"/@tests/test-gates.sh'
  'id-length-unchecked@scripts/mem-gate.sh@s/^\[ "\${#RID}" -eq 32 \] || invalid/true || invalid/@tests/test-gates.sh'
  'id-repeat-accepted@scripts/reservation.sh@s/^      \[ "\$seen" = 0 \] || { echo "reservation: id \$id is already on the ledger" >\&2; exit 2; }/      true/@tests/test-gates.sh'
  'id-shape-unchecked-on-add@scripts/reservation.sh@0,/^    valid_id "\$id" || { echo "reservation: an id is 32 hex (or absent)" >\&2; exit 2; }/s//    true/@tests/test-gates.sh'
  'transcript-symlink-followed@scripts/reservation.sh@s/os.O_RDONLY | os.O_NOFOLLOW | os.O_NOCTTY/os.O_RDONLY | os.O_NOCTTY/@tests/test-gates.sh'
  'transcript-path-unchecked@scripts/reservation.sh@s/\&\& \[ "\$tp" = "\$(dirname -- "\$ptp")\/\$ses\/subagents\/agent-\$aid.jsonl" \]; then/; then/@tests/test-gates.sh'
  'validation-skipped-in-live@scripts/reservation.sh@s/^    if \[ "\$st" = 0 \]; then validate_all; scan acc; prune$/    if [ "$st" = 0 ]; then scan acc; prune/@tests/test-gates.sh'
  'stop-dir-error-ignored@scripts/reservation.sh@s/^    dir_ok; case \$? in 1) exit 1 ;; 2) echo "reservation: no reservations directory" >\&2; exit 3 ;; esac$/    dir_ok; case $? in 1) echo "reservation: no reservations directory" >\&2; exit 3 ;; 2) echo "reservation: no reservations directory" >\&2; exit 3 ;; esac/@tests/test-gates.sh'
  'rm-unchecked-in-stop@scripts/reservation.sh@s/rm -f -- "\$f" || { echo "reservation: cannot release \$f" >\&2; exit 1; }; echo "\$f"; exit 0;/rm -f -- "$f"; echo "$f"; exit 0;/@tests/test-gates.sh'
  'mkdir-unchecked@scripts/reservation.sh@s/2) mkdir -p "\$DIR" || { echo "reservation: cannot create \$DIR" >\&2; exit 1; } ;; esac; }/2) mkdir -p "$DIR" 2>\/dev\/null ;; esac; }/@tests/test-gates.sh'
  'probe-id-shape-unchecked@scripts/lib/gpu_fleet.py@s/case "\$rid" in -) ;; \*) { \[ "\${#rid}" -eq 32 \] \&\& case "\$rid" in \*\[!0-9a-f\]\*) false ;; \*) true ;; esac; } || { ok=0; break; } ;; esac;/true;/@tests/test-gpu.sh'
  'probe-eight-fields-accepted@scripts/lib/gpu_fleet.py@s/\[ -z "\${extra:-}" \] || { ok=0; break; };/true;/@tests/test-gpu.sh'
  'replay-add-accepted@scripts/reservation.sh@s/^      seen_has "\$id" \&\& { echo "reservation: id \$id was released before (seen-set)" >\&2; exit 2; }$/      true/@tests/test-gates.sh'
  'replay-stop-falls-back@scripts/reservation.sh@s/^    \[ "\$id" != - \] \&\& seen_has "\$id" \&\& { echo "reservation: id \$id was released before: a replayed stop is refused" >\&2; exit 2; }$/    true/@tests/test-gates.sh'
  'transcript-root-from-hook-input@scripts/reservation.sh@s/^      \[ -f "\$SESSIONS\/\$sses" \] \&\& \[ ! -L "\$SESSIONS\/\$sses" \] \&\& read -r root < "\$SESSIONS\/\$sses"$/      root=$(dirname -- "$(dirname -- "$(dirname -- "$tp")")")/@tests/test-gates.sh'
  'transcript-realpath-skipped@scripts/reservation.sh@s/^if os.path.realpath(tp) != expect or os.path.realpath(os.path.dirname(tp)) != os.path.dirname(expect):$/if False:/@tests/test-gates.sh'
  'transcript-line-bound-dropped@scripts/reservation.sh@s/^        if len(line) > 65536:          # a line past the bound/        if False:          # a line past the bound/@tests/test-gates.sh'
  'enumeration-symlink-accepted@scripts/reservation.sh@s/^    \[ -L "\$f" \] \&\& { echo "reservation: cannot stat \$f as a record/    false \&\& { echo "reservation: cannot stat $f as a record/@tests/test-gates.sh'
  'entropy-tail-only@scripts/mem-gate.sh@s/^RID=\$(set -o pipefail; od -An -tx1 -N16 \/dev\/urandom | tr -d/RID=$(od -An -tx1 -N16 \/dev\/urandom | tr -d/@tests/test-gates.sh'
  'session-dir-unrecorded@scripts/mem-gate.sh@s/^if \[ -n "\$TPATH" \]; then bash "\$RSV" record-session/if false; then bash "$RSV" record-session/@tests/test-gates.sh'
  'probe-tombstones-unvalidated@scripts/lib/gpu_fleet.py@s/case "\$f" in \*.tmp) ok=0; break ;; esac; \[ -f "\$f" \]/case "$f" in *.tmp) ok=0; break ;; *.expired) continue ;; esac; [ -f "$f" ]/@tests/test-gpu.sh'
  'probe-token-bound-missing@scripts/lib/gpu_fleet.py@s/\[ "\${#ses}" -le 128 \] \&\& \[ "\${#typ}" -le 128 \] \&\& \[ "\${#rag}" -le 128 \] || { ok=0; break; };/true;/@tests/test-gpu.sh'
  'token-not-sanitised@scripts/reservation.sh@s/^san() { local s; s=\$(printf .*$/san() { printf "%s" "${1:--}"; }/@tests/test-gates.sh'
)
n=0; bad=0
for m in "${MUT[@]}"; do
  IFS='@' read -r name file expr suite <<<"$m"; n=$((n + 1))
  d="$TMP/$name"; rm -rf "$d"; mkdir -p "$d"; cp -r "$SRC/scripts" "$SRC/tests" "$SRC/gpu" "$SRC/config.json" "$d/" 2>/dev/null
  sed -i -e "$expr" "$d/$file"
  if cmp -s "$SRC/$file" "$d/$file"; then echo "NOT APPLIED $name: the expression changed nothing (the rule moved under it)"; bad=$((bad + 1)); continue; fi
  out=$(cd "$d" && timeout 600 bash "$suite" 2>&1); reds=$(printf '%s\n' "$out" | grep -c '^FAIL')
  if [ "$reds" -gt 0 ]; then printf 'RED  %-34s %s red: %s\n' "$name" "$reds" "$(printf '%s\n' "$out" | grep -m1 '^FAIL' | cut -c1-110)"
  else printf 'GREEN %-34s stayed green: the suite does not pin this rule\n' "$name"; bad=$((bad + 1)); fi
done
echo "perturb-gpu-reservations: $n mutations, $bad not red"
[ "$bad" -eq 0 ]
