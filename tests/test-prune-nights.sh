#!/usr/bin/env bash
# scripts/lib/prune_nights.py (dreamteam #250/#255) on REAL git repositories with local bare remotes. Every refusal
# the round-1 review asked for has a case here: untracked files hidden by config, detached HEAD, stale remote
# evidence, judgment failures, non-repositories, a clone someone is working in, symlinks, invalid and future dates,
# and the previous night kept whole.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PN="${PRUNE_NIGHTS:-$ROOT/scripts/lib/prune_nights.py}"
T=$(mktemp -d "${TMPDIR:-/tmp}/prune-nights.XXXXXX") || { echo "no temp dir"; exit 1; }
BG=()
trap 'for p in "${BG[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; chmod -R u+rwx "$T" 2>/dev/null; rm -rf -- "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
       GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
TONIGHT=2026-11-20
B="$T/wt"; mkdir -p "$B" "$T/remotes" "$T/out"
n_remote=0
mkclone() { # night name → a clean clone of a fresh bare remote with one pushed commit on main
  n_remote=$((n_remote+1)); local r="$T/remotes/r$n_remote.git" seed="$T/seed$n_remote"
  git init -q --bare -b main "$r"; git init -q -b main "$seed"
  echo one > "$seed/f.txt"; git -C "$seed" add f.txt; git -C "$seed" commit -q -m one
  git -C "$seed" remote add origin "$r"; git -C "$seed" push -q origin main; rm -rf "$seed"
  mkdir -p "$B/$1"; git clone -q "$r" "$B/$1/$2"; LAST_REMOTE="$r"
}
prune() { DREAMTEAM_PRUNE_QUIET_HOURS="${QUIET_H:-0}" python3 -I "$PN" "$@" "$B" "$TONIGHT" > "$T/out/res.json" 2> "$T/out/err"; }
pruned() { jq -e --arg c "$1" '.pruned | index($c)' "$T/out/res.json" >/dev/null 2>&1; }
why() { jq -r --arg c "$1" '[.kept[] | select(.clone == $c) | .why] | first // ""' "$T/out/res.json"; }
kept_as() { # clone, text the reason must contain; the clone must still be on disk
  case "$(why "$1")" in *"$2"*) [ -e "$B/$1" ] && ok || bad "$1 is listed as kept but is gone" ;; *) bad "$1: expected kept for '$2', got why='$(why "$1")' pruned=$(pruned "$1" && echo yes || echo no)" ;; esac
}

# ── which nights ────────────────────────────────────────────────────────────────────────────────────────────────
mkclone 2026-11-15 clean; mkclone 2026-11-16 clean2
mkclone 2026-11-19 prev; mkclone "$TONIGHT" now; mkclone 2026-11-25 future; mkclone 2026-00-99 baddate; mkclone notes misc
mkdir "$T/elsewhere"; mkclone 2026-11-02 viaLink; mv "$B/2026-11-02" "$T/elsewhere/2026-11-02"; ln -s "$T/elsewhere/2026-11-02" "$B/2026-11-02"
echo x > "$B/2026-11-03"                                   # a FILE named like a night
prune; rc=$?
[ "$rc" = 0 ] && jq -e . "$T/out/res.json" >/dev/null 2>&1 && ok || bad "rc $rc or no JSON: $(cat "$T/out/err")"
pruned 2026-11-15/clean && [ ! -e "$B/2026-11-15" ] && ok || bad "a clean pushed clone in an old night was not removed (or its emptied night stayed)"
pruned 2026-11-16/clean2 && ok || bad "second old night not pruned"
[ -d "$B/2026-11-19/prev/.git" ] && ok || bad "the previous night was touched"
[ -d "$B/$TONIGHT/now/.git" ] && ok || bad "tonight was touched"
[ -d "$B/2026-11-25/future/.git" ] && ok || bad "a future-dated night was touched"
[ -d "$B/2026-00-99/baddate/.git" ] && ok || bad "an impossible date was treated as a night"
[ -d "$B/notes/misc/.git" ] && ok || bad "a directory that is not a date was touched"
[ -L "$B/2026-11-02" ] && [ -d "$T/elsewhere/2026-11-02/viaLink/.git" ] && ok || bad "a symlinked night was followed or removed"
[ -f "$B/2026-11-03" ] && ok || bad "a file named like a night was removed"
[ "$(jq -c '.protected' "$T/out/res.json")" = '["2026-11-20","2026-11-19"]' ] && ok || bad "protected: $(jq -c .protected "$T/out/res.json")"
for n in 2026-11-25 2026-00-99 notes 2026-11-02 2026-11-03; do jq -e --arg n "$n" '.ignored | index($n)' "$T/out/res.json" >/dev/null || bad "$n not listed as ignored"; done; ok
# the previous night is the newest EARLIER night that exists, even after a gap: with 11-19 gone, 11-17 is protected
mkclone 2026-11-14 old; mkclone 2026-11-17 gapprev; mv "$B/2026-11-19" "$T/aside-19"
prune; [ -d "$B/2026-11-17/gapprev/.git" ] && pruned 2026-11-14/old && ok || bad "with a gap, the newest earlier night was not the protected one"
mv "$T/aside-19" "$B/2026-11-19"

# ── which clones: every one of these stays, with its reason ─────────────────────────────────────────────────────
N=2026-11-10
mkclone $N dirty;      echo two >> "$B/$N/dirty/f.txt"
mkclone $N untracked;  echo new > "$B/$N/untracked/new.txt"; git -C "$B/$N/untracked" config status.showUntrackedFiles no
mkclone $N detached;   git -C "$B/$N/detached" checkout -q --detach; git -C "$B/$N/detached" commit -q --allow-empty -m lost
mkclone $N detclean;   git -C "$B/$N/detclean" checkout -q --detach
mkclone $N ahead;      git -C "$B/$N/ahead" commit -q --allow-empty -m local
mkclone $N sidebranch; git -C "$B/$N/sidebranch" checkout -q -b side; git -C "$B/$N/sidebranch" commit -q --allow-empty -m s; git -C "$B/$N/sidebranch" checkout -q main
mkclone $N stale;      git -C "$B/$N/stale" checkout -q -b fix; git -C "$B/$N/stale" commit -q --allow-empty -m fix
                       git -C "$B/$N/stale" push -q origin fix; git -C "$LAST_REMOTE" update-ref -d refs/heads/fix   # merged+deleted on the remote
mkclone $N offline;    git -C "$B/$N/offline" remote set-url origin "$T/remotes/gone.git"
mkclone $N stash;      echo s >> "$B/$N/stash/f.txt"; git -C "$B/$N/stash" stash -q
mkclone $N noremote;   git -C "$B/$N/noremote" remote remove origin
mkclone $N gitfile;    mv "$B/$N/gitfile/.git" "$T/gitfile.git"; echo "gitdir: $T/gitfile.git" > "$B/$N/gitfile/.git"
mkdir -p "$B/$N/plain"; echo data > "$B/$N/plain/notes.txt"
mkdir -p "$B/$N/broken/.git"; echo data > "$B/$N/broken/keep.txt"
mkdir "$T/target"; echo precious > "$T/target/p.txt"; ln -s "$T/target" "$B/$N/link"
echo f > "$B/$N/afile"
mkclone $N good
prune
kept_as $N/dirty "uncommitted or untracked"
kept_as $N/untracked "uncommitted or untracked"
kept_as $N/detached "detached HEAD"
kept_as $N/detclean "detached HEAD"
kept_as $N/ahead "1 commit(s) the remote does not hold"
kept_as $N/sidebranch "1 commit(s) the remote does not hold"
kept_as $N/stale "1 commit(s) the remote does not hold"
kept_as $N/offline "could not be refreshed"
kept_as $N/stash "a stash"
kept_as $N/noremote "no remote"
kept_as $N/gitfile "not a directory"
kept_as $N/plain "not a git clone"
kept_as $N/broken "git could not answer"
kept_as $N/link "a symlink"
[ -L "$B/$N/link" ] && [ "$(cat "$T/target/p.txt")" = precious ] && ok || bad "a symlinked clone entry was followed or removed"
kept_as $N/afile "not a directory"
pruned $N/good && [ ! -e "$B/$N/good" ] && ok || bad "the one clean clone among them was not removed (positive control)"
[ -d "$B/$N" ] && ok || bad "a night that still holds kept clones was removed"
[ "$(cat "$B/$N/plain/notes.txt")" = data ] && [ "$(cat "$B/$N/broken/keep.txt")" = data ] && ok || bad "a kept non-repository lost a file"
ls -a "$B/$N" | grep -q '^\.pruning-' && bad "a .pruning- directory was left behind" || ok

# a broken clone INSIDE an enclosing repository must not be judged as that repository (which is clean and pushed)
E="$T/enc"; git init -q --bare -b main "$T/remotes/enc.git"; git init -q -b main "$E"; git -C "$E" commit -q --allow-empty -m e
git -C "$E" remote add origin "$T/remotes/enc.git"; git -C "$E" push -q -u origin main
mkdir -p "$E/wt/2026-11-01/kid/.git" "$E/wt/2026-11-18"; echo "wt/" > "$E/.git/info/exclude"
DREAMTEAM_PRUNE_QUIET_HOURS=0 python3 -I "$PN" "$E/wt" "$TONIGHT" > "$T/out/enc.json" 2>/dev/null
[ -d "$E/wt/2026-11-01/kid/.git" ] && [ "$(jq -r '.kept[0].why' "$T/out/enc.json")" = "git could not answer for this directory" ] && ok || bad "a broken clone was judged as its enclosing repository: $(cat "$T/out/enc.json")"

# ── someone is using it ─────────────────────────────────────────────────────────────────────────────────────────
N2=2026-11-09
mkclone $N2 busy; ( cd "$B/$N2/busy" && exec sleep 60 ) & BG+=("$!"); busy_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(readlink "/proc/$busy_pid/cwd" 2>/dev/null)" = "$B/$N2/busy" ] && break; sleep 0.1; done
mkclone $N2 fresh; mkclone $N2 quietold
touch -d '2 days ago' "$B/$N2/quietold" "$B/$N2/quietold/.git" "$B/$N2/quietold/.git/HEAD" "$B/$N2/quietold/.git/index" "$B/$N2/quietold/.git/logs/HEAD" "$B/$N2/busy" "$B/$N2/busy/.git" "$B/$N2/busy/.git/HEAD" "$B/$N2/busy/.git/index" "$B/$N2/busy/.git/logs/HEAD"
QUIET_H=6 prune
kept_as $N2/busy "a process is working in it (pid $busy_pid)"
kept_as $N2/fresh "quiet period 6 h"
pruned $N2/quietold && ok || bad "a clone untouched for 2 days was not removed with the default quiet period: $(why $N2/quietold)"
kill "$busy_pid" 2>/dev/null; wait "$busy_pid" 2>/dev/null

# ── judgment failures: a git that fails or stalls on ONE call means keep ────────────────────────────────────────
realgit=$(command -v git); mkdir "$T/gitbin"
stubgit() { printf '#!/bin/sh\ncase " $* " in *" %s "*) %s ;; esac\nexec %s "$@"\n' "$1" "$2" "$realgit" > "$T/gitbin/git"; chmod +x "$T/gitbin/git"; }
N3=2026-11-08
for sub in status fetch rev-list symbolic-ref remote; do
  mkclone $N3 "f-$sub"; stubgit "$sub" "exit 3"
  PATH="$T/gitbin:$PATH" prune
  [ -d "$B/$N3/f-$sub/.git" ] && [ -n "$(why "$N3/f-$sub")" ] && ok || bad "git $sub failing did not keep the clone"
done
mkclone $N3 stall; stubgit status "exec sleep 30"
s0=$(date +%s); DREAMTEAM_PRUNE_GIT_TIMEOUT=1 PATH="$T/gitbin:$PATH" prune; s1=$(date +%s)
kept_as $N3/stall "git status did not finish"; [ $((s1-s0)) -lt 20 ] && ok || bad "a stalled git took $((s1-s0)) s"
# control: with the real git the same clones go
prune; pruned $N3/stall && pruned $N3/f-status && ok || bad "control: the same clones were not removed with a working git"

# ── --dry-run changes nothing and fetches nothing ───────────────────────────────────────────────────────────────
N4=2026-11-07; mkclone $N4 dry
before=$(find "$B/$N4" | sort | sha256sum)
prune --dry-run
[ "$(jq -r .dry_run "$T/out/res.json")" = true ] && pruned $N4/dry && [ "$(find "$B/$N4" | sort | sha256sum)" = "$before" ] && ok || bad "--dry-run changed something or did not list the clone"
# ── a directory swapped for another between judgment and deletion is not the one that goes ──────────────────────
mkclone $N4 swap; echo "arrived later" > "$T/newcomer.txt"
cat > "$T/drv.py" <<'EOP'
import importlib.util, os, shutil, sys
spec = importlib.util.spec_from_file_location("pn", sys.argv[1]); pn = importlib.util.module_from_spec(spec); spec.loader.exec_module(pn)
real = pn.judge
def judge(path, fd, now, dry):
    why = real(path, fd, now, dry)
    if why is None and path.endswith("/swap"):
        os.rename(path, path + ".judged")              # the judged clone is moved away...
        os.mkdir(path); shutil.copy(sys.argv[4], path + "/newcomer.txt")   # ...and something else takes its name
    return why
pn.judge = judge
sys.exit(pn.main(["prune_nights.py", sys.argv[2], sys.argv[3]]))
EOP
DREAMTEAM_PRUNE_QUIET_HOURS=0 python3 -I "$T/drv.py" "$PN" "$B" "$TONIGHT" "$T/newcomer.txt" > "$T/out/res.json" 2>/dev/null
[ "$(cat "$B/$N4/swap/newcomer.txt" 2>/dev/null)" = "arrived later" ] && ok || bad "the directory that took the clone's name was deleted"
[ -d "$B/$N4/swap.judged/.git" ] && ok || bad "the judged clone, moved away by someone else, was deleted through its old name"
kept_as $N4/swap "replaced while being judged"
# ── an interrupted earlier prune is finished ────────────────────────────────────────────────────────────────────
mkdir -p "$B/$N4/.pruning-old-abc123/.git"; echo x > "$B/$N4/.pruning-old-abc123/f"
prune; [ ! -e "$B/$N4/.pruning-old-abc123" ] && pruned "$N4/.pruning-old-abc123" && ok || bad "a leftover .pruning- directory was not finished"

# ── arguments and the base itself ───────────────────────────────────────────────────────────────────────────────
python3 -I "$PN" >/dev/null 2>&1; [ "$?" = 22 ] && ok || bad "no arguments not 22"
python3 -I "$PN" "$B" 2026-13-40 >/dev/null 2>&1; [ "$?" = 22 ] && ok || bad "an impossible tonight not 22"
python3 -I "$PN" relative/dir "$TONIGHT" >/dev/null 2>&1; [ "$?" = 22 ] && ok || bad "a relative base not 22"
python3 -I "$PN" "$T/nowhere" "$TONIGHT" >/dev/null 2>&1; [ "$?" = 2 ] && ok || bad "a missing base not 2"
ln -s "$B" "$T/wtlink"; mkclone 2026-11-06 vialink
python3 -I "$PN" "$T/wtlink" "$TONIGHT" >/dev/null 2>&1; [ "$?" = 2 ] && [ -d "$B/2026-11-06/vialink/.git" ] && ok || bad "a symlinked base was followed"

echo "prune-nights: $pass passed, $fail failed"
[ "$fail" = 0 ]
