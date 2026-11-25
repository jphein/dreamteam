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
