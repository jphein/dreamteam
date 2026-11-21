#!/usr/bin/env bash
# scripts/lib/prune_nights.py (dreamteam #250/#255) on REAL git repositories: MOVE-THEN-DELETE. A selected clone is
# moved to a quarantine dir and deleted from there by age. The forge is a stub `gh` that answers
# `repos/<o>/<n>` and `repos/<o>/<n>/compare/<sha>...<branch>` from real bare repositories under $T/forge, so
# "is this commit on the remote now" is decided by real ancestry, not by a canned string.
# Every refusal the two reviews asked for has a case here.
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
REALGIT=$(command -v git)
TONIGHT=2026-11-20
B="$T/wt"; Q="$T/q"; mkdir -p "$B" "$T/forge/t" "$T/out" "$T/ghbin" "$T/gitbin"
# ── the forge stub ──────────────────────────────────────────────────────────────────────────────────────────────
cat > "$T/ghbin/gh" <<EOS
#!/usr/bin/env bash
printf '%s | cwd=%s\n' "\$*" "\$PWD" >> "$T/gh.calls"
[ -e "$T/gh.down" ] && { echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1; }
case "\$2" in */compare/*) [ -e "$T/gh.cmpdown" ] && { echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1; } ;; esac
[ "\$1" = api ] || exit 2
url="\$2"; g="$REALGIT"
nf() { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
[ "\$2" = --paginate ] && url="\$3"
case "\$url" in
  repos/*/*/compare/*)
    rest="\${url#repos/}"; repo="\${rest%%/compare/*}"; cmp="\${rest#*/compare/}"
    sha="\${cmp%%...*}"; br="\${cmp#*...}"; br="\${br//%2F//}"
    bare="$T/forge/\$repo.git"; [ -d "\$bare" ] || nf
    tip=\$("\$g" --git-dir="\$bare" rev-parse -q --verify "refs/heads/\$br^{commit}" 2>/dev/null) || nf
    "\$g" --git-dir="\$bare" cat-file -e "\$sha^{commit}" 2>/dev/null || nf
    if [ "\$tip" = "\$sha" ]; then echo identical
    elif "\$g" --git-dir="\$bare" merge-base --is-ancestor "\$sha" "\$tip"; then echo ahead
    elif "\$g" --git-dir="\$bare" merge-base --is-ancestor "\$tip" "\$sha"; then echo behind
    else echo diverged; fi ;;
  repos/*/*/git/matching-refs/tags/)
    rest="\${url#repos/}"; repo="\${rest%%/git/*}"; bare="$T/forge/\$repo.git"; [ -d "\$bare" ] || nf
    [ -e "$T/gh.tagsdown" ] && { echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1; }
    "\$g" --git-dir="\$bare" for-each-ref --format='%(refname) %(objectname)' refs/tags ;;
  repos/*/*) [ -d "$T/forge/\${url#repos/}.git" ] || nf; echo main ;;
  *) exit 2 ;;
esac
EOS
chmod +x "$T/ghbin/gh"; : > "$T/gh.calls"
n_remote=0
mkclone() { # night name → a clean clone of a fresh forge repo with one commit on main; its URL is a github one
  n_remote=$((n_remote+1)); local r="$T/forge/t/r$n_remote.git" seed="$T/seed$n_remote"
  git init -q --bare -b main "$r"; git init -q -b main "$seed"
  echo one > "$seed/f.txt"; git -C "$seed" add f.txt; git -C "$seed" commit -q -m one
  git -C "$seed" push -q "$r" main; rm -rf "$seed"
  mkdir -p "$B/$1"; git clone -q "$r" "$B/$1/$2"
  git -C "$B/$1/$2" config remote.origin.url "https://github.com/t/r$n_remote.git"
  LAST_FORGE="$r"
}
topush() { git -C "$1" push -q "$LAST_FORGE" "${2:-main}"; git -C "$1" update-ref "refs/remotes/origin/${2:-main}" "$(git -C "$1" rev-parse "${2:-main}")"; }
prune() { PATH="${EXTRA_PATH:+$EXTRA_PATH:}$T/ghbin:$PATH" DREAMTEAM_PRUNE_QUIET_HOURS="${QUIET_H:-0}" python3 -I "$PN" "$@" --quarantine "$Q" "$B" "$TONIGHT" > "$T/out/res.json" 2> "$T/out/err"; }
pruned() { jq -e --arg c "$1" '.moved | index($c)' "$T/out/res.json" >/dev/null 2>&1; }
inq() { local n="${1%%/*}" c="${1#*/}"; c="${c#.pruning-}"; ls "$Q" 2>/dev/null | grep -qE "^${n}__${c}__q20261120(-[0-9]+)?\$"; }   # is it in the quarantine?
why() { jq -r --arg c "$1" '[.kept[] | select(.clone == $c) | .why] | first // ""' "$T/out/res.json"; }
kept_as() { # clone, text the reason must contain; the clone must still be on disk
  case "$(why "$1")" in *"$2"*) [ -e "$B/$1" ] && ok || bad "$1 is listed as kept but is gone" ;; *) bad "$1: expected kept for '$2', got why='$(why "$1")' pruned=$(pruned "$1" && echo yes || echo no)" ;; esac
}
goes() { pruned "$1" && [ ! -e "$B/$1" ] && inq "$1" && ok || bad "$1 should have been moved to the quarantine: why='$(why "$1")' in-quarantine=$(inq "$1" && echo yes || echo no)"; }

# ── which nights ────────────────────────────────────────────────────────────────────────────────────────────────
mkclone 2026-11-15 clean; mkclone 2026-11-16 clean2
mkclone 2026-11-19 prev; mkclone "$TONIGHT" now; mkclone 2026-11-25 future; mkclone 2026-00-99 baddate; mkclone notes misc
mkdir "$T/elsewhere"; mkclone 2026-11-02 viaLink; mv "$B/2026-11-02" "$T/elsewhere/2026-11-02"; ln -s "$T/elsewhere/2026-11-02" "$B/2026-11-02"
echo x > "$B/2026-11-03"                                   # a FILE named like a night
prune; rc=$?
[ "$rc" = 0 ] && jq -e . "$T/out/res.json" >/dev/null 2>&1 && ok || bad "rc $rc or no JSON: $(cat "$T/out/err")"
goes 2026-11-15/clean; [ ! -e "$B/2026-11-15" ] && ok || bad "an emptied night stayed"
qc=$(ls -d "$Q"/2026-11-15__clean__q20261120); [ "$(cat "$qc/f.txt")" = one ] && git -C "$qc" rev-parse -q --verify HEAD >/dev/null && ok || bad "the quarantined clone is not whole"
[ "$(jq -c '.quarantine | [.dir, .refused, .keep_days, .min_free_pct]' "$T/out/res.json")" = "[\"$Q\",false,14,10]" ] && ok || bad "quarantine block: $(jq -c .quarantine "$T/out/res.json")"
goes 2026-11-16/clean2
[ -d "$B/2026-11-19/prev/.git" ] && ok || bad "the previous night was touched"
[ -d "$B/$TONIGHT/now/.git" ] && ok || bad "tonight was touched"
[ -d "$B/2026-11-25/future/.git" ] && ok || bad "a future-dated night was touched"
[ -d "$B/2026-00-99/baddate/.git" ] && ok || bad "an impossible date was treated as a night"
[ -d "$B/notes/misc/.git" ] && ok || bad "a directory that is not a date was touched"
[ -L "$B/2026-11-02" ] && [ -d "$T/elsewhere/2026-11-02/viaLink/.git" ] && ok || bad "a symlinked night was followed or removed"
[ -f "$B/2026-11-03" ] && ok || bad "a file named like a night was removed"
[ "$(jq -c '.protected' "$T/out/res.json")" = '["2026-11-20","2026-11-19"]' ] && ok || bad "protected: $(jq -c .protected "$T/out/res.json")"
for n in 2026-11-25 2026-00-99 notes 2026-11-02 2026-11-03; do jq -e --arg n "$n" '.ignored | index($n)' "$T/out/res.json" >/dev/null || bad "$n not listed as ignored"; done; ok
grep -v ' | cwd=/$' "$T/gh.calls" | grep -q . && bad "the forge was asked from inside a directory other than /: $(grep -v ' | cwd=/$' "$T/gh.calls" | head -n 1)" || ok
# the previous night is the newest EARLIER night that exists, even after a gap
mkclone 2026-11-14 old; mkclone 2026-11-17 gapprev; mv "$B/2026-11-19" "$T/aside-19"
prune; [ -d "$B/2026-11-17/gapprev/.git" ] && pruned 2026-11-14/old && ok || bad "with a gap, the newest earlier night was not the protected one"
mv "$T/aside-19" "$B/2026-11-19"

# ── which clones: every one of these stays, with its reason ─────────────────────────────────────────────────────
N=2026-11-10
c() { echo "$B/$N/$1"; }
mkclone $N dirty;      echo two >> "$(c dirty)/f.txt"
mkclone $N untracked;  echo new > "$(c untracked)/new.txt"; git -C "$(c untracked)" config status.showUntrackedFiles no   # also an untrusted key
mkclone $N untracked2; echo new > "$(c untracked2)/new.txt"
mkclone $N assume;     git -C "$(c assume)" update-index --assume-unchanged f.txt; echo hidden >> "$(c assume)/f.txt"
mkclone $N skipwt;     git -C "$(c skipwt)" update-index --skip-worktree f.txt; echo hidden >> "$(c skipwt)/f.txt"
mkclone $N detached;   git -C "$(c detached)" checkout -q --detach; git -C "$(c detached)" commit -q --allow-empty -m lost
mkclone $N detclean;   git -C "$(c detclean)" checkout -q --detach
mkclone $N ahead;      git -C "$(c ahead)" commit -q --allow-empty -m local
mkclone $N sidebranch; git -C "$(c sidebranch)" checkout -q -b side; git -C "$(c sidebranch)" commit -q --allow-empty -m s; git -C "$(c sidebranch)" checkout -q main
mkclone $N tagonly;    git -C "$(c tagonly)" commit -q --allow-empty -m tagged; git -C "$(c tagonly)" tag keep; git -C "$(c tagonly)" reset -q --hard origin/main
                       git -C "$(c tagonly)" reflog expire --expire=now --all
mkclone $N reflogonly; git -C "$(c reflogonly)" commit -q --allow-empty -m amended-away; git -C "$(c reflogonly)" reset -q --hard origin/main
mkclone $N stale;      git -C "$(c stale)" checkout -q -b fix; git -C "$(c stale)" commit -q --allow-empty -m fix; topush "$(c stale)" fix
                       git -C "$LAST_FORGE" update-ref -d refs/heads/fix; git -C "$(c stale)" checkout -q main      # merged and deleted on the remote
mkclone $N forged;     git -C "$(c forged)" commit -q --allow-empty -m never-pushed; git -C "$(c forged)" update-ref refs/remotes/origin/main HEAD
mkclone $N rewritten;  git -C "$(c rewritten)" commit -q --allow-empty -m pushed; topush "$(c rewritten)" main
                       git -C "$LAST_FORGE" update-ref refs/heads/main "$(git -C "$(c rewritten)" rev-parse HEAD~1)"  # force-pushed away on the remote
mkclone $N stash;      echo s >> "$(c stash)/f.txt"; git -C "$(c stash)" stash -q
mkclone $N noremote;   git -C "$(c noremote)" remote remove origin
mkclone $N localurl;   git -C "$(c localurl)" config remote.origin.url "$LAST_FORGE"
mkclone $N credurl;    git -C "$(c credurl)" config remote.origin.url "https://user:pw@github.com/t/r1.git"
mkclone $N refspec;    git -C "$(c refspec)" config remote.origin.fetch '+refs/heads/*:refs/heads/*'
mkclone $N sshcmd;     git -C "$(c sshcmd)" config core.sshCommand "touch $T/ran-from-config"
mkclone $N filter;     git -C "$(c filter)" config filter.x.clean "touch $T/ran-from-config"
mkclone $N include;    git -C "$(c include)" config include.path "$T/other.config"
mkclone $N remote2;    git -C "$(c remote2)" remote add other "$LAST_FORGE"
mkclone $N promisor;   git -C "$(c promisor)" config remote.origin.promisor true
mkclone $N alternates; echo "$T/forge/t/r1.git/objects" > "$(c alternates)/.git/objects/info/alternates"
mkclone $N objlink;    mv "$(c objlink)/.git/objects" "$T/objects-moved"; ln -s "$T/objects-moved" "$(c objlink)/.git/objects"
mkclone $N gitfile;    mv "$(c gitfile)/.git" "$T/gitfile.git"; echo "gitdir: $T/gitfile.git" > "$(c gitfile)/.git"
mkdir -p "$(c plain)"; echo data > "$(c plain)/notes.txt"
mkdir -p "$(c broken)/.git"; echo data > "$(c broken)/keep.txt"
mkdir "$T/target"; echo precious > "$T/target/p.txt"; ln -s "$T/target" "$(c link)"
echo f > "$(c afile)"
# a `.pruning-…` NAME earns nothing: a dirty one stays, a clean pushed one is judged like any clone
mkclone $N tmpd; echo unsaved > "$(c tmpd)/work.txt"; mv "$(c tmpd)" "$B/$N/.pruning-dirty-abc123"
mkclone $N tmpc; mv "$(c tmpc)" "$B/$N/.pruning-clean-abc123"
# round 3 of the review: history must be read as it is, and the object store is looked at, not only the refs
mkclone $N graft;      git -C "$(c graft)" commit -q --allow-empty -m hidden; h=$(git -C "$(c graft)" rev-parse HEAD); git -C "$(c graft)" reset -q --hard origin/main
                       git -C "$(c graft)" reflog expire --expire=now --all; mkdir -p "$(c graft)/.git/info"; echo "$(git -C "$(c graft)" rev-parse origin/main) $h" > "$(c graft)/.git/info/grafts"
mkclone $N replace;    git -C "$(c replace)" commit -q --allow-empty -m r; git -C "$(c replace)" replace origin/main HEAD 2>/dev/null; git -C "$(c replace)" reset -q --hard origin/main
mkclone $N dangling;   git -C "$(c dangling)" commit -q --allow-empty -m dropped; git -C "$(c dangling)" reset -q --hard origin/main; git -C "$(c dangling)" reflog expire --expire=now --all
mkclone $N localtag;   git -C "$(c localtag)" tag only-here
mkclone $N anntag;     git -C "$(c anntag)" tag -a -m note ann-here
mkclone $N tagok;      git -C "$(c tagok)" tag v1; git -C "$(c tagok)" tag -a -m rel v2; git -C "$(c tagok)" push -q "$LAST_FORGE" v1 v2
mkclone $N mapped;     python3 -I -c 'import mmap,os,sys,time; f=open(sys.argv[1],"rb"); m=mmap.mmap(f.fileno(),0,prot=mmap.PROT_READ); os.closerange(3,4096); open(sys.argv[2],"w").write("up"); time.sleep(120)' "$(c mapped)/f.txt" "$T/mapped.up" & BG+=("$!"); map_pid=$!
for _ in $(seq 1 50); do [ -s "$T/mapped.up" ] && break; sleep 0.1; done
# positive controls: a clean clone, and one whose remote main has simply moved on since the night
mkclone $N good
mkclone $N behind; git clone -q "$LAST_FORGE" "$T/adv"; git -C "$T/adv" commit -q --allow-empty -m later; git -C "$T/adv" push -q origin main
snap_ahead=$(cd "$(c ahead)" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)
prune
kept_as $N/dirty "uncommitted or untracked"
kept_as $N/untracked "a config key this tool does not trust (status.showuntrackedfiles)"
kept_as $N/untracked2 "uncommitted or untracked"
kept_as $N/assume "hidden from status"
kept_as $N/skipwt "hidden from status"
kept_as $N/detached "detached HEAD"
kept_as $N/detclean "detached HEAD"
kept_as $N/ahead "1 commit(s) its remote-tracking branches do not hold"
kept_as $N/sidebranch "1 commit(s) its remote-tracking branches do not hold"
kept_as $N/tagonly "1 commit(s) its remote-tracking branches do not hold"
kept_as $N/reflogonly "1 commit(s) its remote-tracking branches do not hold"
kept_as $N/stale "origin/fix is not on the remote any more"
kept_as $N/forged "origin/main is not on the remote any more"
kept_as $N/rewritten "origin/main is not on the remote any more"
kept_as $N/stash "a stash"
kept_as $N/graft "history is not read as it is (.git/info/grafts exists)"
kept_as $N/replace "history is not read as it is (.git/refs/replace exists)"
kept_as $N/dangling "1 commit or tag object(s) in its store that the remote does not hold"
kept_as $N/localtag "a tag the remote does not have"
kept_as $N/anntag "a tag the remote does not have"
goes $N/tagok
kept_as $N/mapped "a process has a file of it mapped (pid $map_pid)"
[ -z "$(ls -l /proc/$map_pid/fd 2>/dev/null | grep -F "$(c mapped)")" ] && grep -qF "$(c mapped)/f.txt" "/proc/$map_pid/maps" && ok || bad "fixture: the mapping process still has a descriptor open, or no mapping"
kept_as $N/noremote "no remote"
kept_as $N/localurl "not one plain https://github.com"
kept_as $N/credurl "not one plain https://github.com"
kept_as $N/refspec "fetch refspec is not the default"
kept_as $N/sshcmd "a config key this tool does not trust (core.sshcommand)"
kept_as $N/filter "a config key this tool does not trust (filter.x.clean)"
kept_as $N/include "a config key this tool does not trust (include.path)"
kept_as $N/remote2 "a config key this tool does not trust (remote.other.url)"
kept_as $N/promisor "a config key this tool does not trust (remote.origin.promisor)"
kept_as $N/alternates "storage is not its own"
kept_as $N/objlink "not a plain directory"
kept_as $N/gitfile "not a directory"
kept_as $N/plain "not a git clone"
kept_as $N/broken "not a plain directory"
kept_as $N/link "a symlink"
[ -L "$(c link)" ] && [ "$(cat "$T/target/p.txt")" = precious ] && ok || bad "a symlinked clone entry was followed or removed"
kept_as $N/afile "not a directory"
kept_as "$N/.pruning-dirty-abc123" "uncommitted or untracked"
[ "$(cat "$B/$N/.pruning-dirty-abc123/work.txt" 2>/dev/null)" = unsaved ] && ok || bad "a directory was deleted because of its .pruning- name"
goes "$N/.pruning-clean-abc123"
goes $N/good
goes $N/behind
[ -d "$B/$N" ] && ok || bad "a night that still holds kept clones was removed"
[ ! -e "$T/ran-from-config" ] && ok || bad "something from a clone's config was executed"
[ "$(cd "$(c ahead)" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)" = "$snap_ahead" ] && ok || bad "judging a kept clone changed a file in it"
[ "$(git -C "$(c forged)" rev-parse refs/remotes/origin/main)" = "$(git -C "$(c forged)" rev-parse HEAD)" ] && ok || bad "a local ref was moved by the judgment"
[ "$(ls -a "$B/$N" | grep -c '^\.pruning-')" = 1 ] && ok || bad "unexpected .pruning- entries: $(ls -a "$B/$N" | grep '^\.pruning-' | tr '\n' ' ')"
# a second run over the same refusals deletes none of them (the first review's "next run deletes what this one kept")
prune; [ -d "$B/$N/.pruning-dirty-abc123" ] && [ -d "$(c dirty)/.git" ] && [ -d "$(c forged)/.git" ] && [ "$(jq '.moved | length' "$T/out/res.json")" = 0 ] && ok || bad "a second run moved something the first kept: $(jq -c .moved "$T/out/res.json")"
kill "$map_pid" 2>/dev/null; wait "$map_pid" 2>/dev/null

# every git call forbids transports and lazy fetching, and none of them is a command that fetches or writes refs
printf '#!/bin/sh\nprintf "%%s | lazy=%%s\\n" "$*" "${GIT_NO_LAZY_FETCH:-unset}" >> "%s/git.calls"\nexec %s "$@"\n' "$T" "$REALGIT" > "$T/gitbin/git"; chmod +x "$T/gitbin/git"
mkclone 2026-11-12 logged; : > "$T/git.calls"; EXTRA_PATH="$T/gitbin" prune; goes 2026-11-12/logged
n=$(wc -l < "$T/git.calls"); g=$(grep -c -- '-c protocol.allow=never .* | lazy=1$' "$T/git.calls" || true)
[ "$n" -ge 8 ] && [ "$n" = "$g" ] && ok || bad "git calls without the transport guard: $g of $n"
subs=$(sed -E 's/.* -C [^ ]+ ([a-z-]+).*/\1/' "$T/git.calls" | sort -u | tr '\n' ' ')
[ "$subs" = "cat-file config for-each-ref ls-files rev-list rev-parse status symbolic-ref " ] && ok || bad "git subcommands used: $subs"

# a broken clone INSIDE an enclosing repository must not be judged as that repository. The enclosing one is made to
# look prunable (clean, pushed, a github URL), so being judged as it would mean deletion. Two safeguards each prevent
# that (git's discovery ceiling; comparing git's toplevel with the directory): the mutant removes both.
mkclone encnight enc; E="$T/enc"; mv "$B/encnight/enc" "$E"; rmdir "$B/encnight"
mkdir -p "$E/wt/2026-11-01/kid/.git/objects" "$E/wt/2026-11-01/kid/.git/refs" "$E/wt/2026-11-18"; : > "$E/wt/2026-11-01/kid/.git/HEAD"; : > "$E/wt/2026-11-01/kid/.git/config"
echo keep > "$E/wt/2026-11-01/kid/only-here.txt"; echo "wt/" > "$E/.git/info/exclude"
[ -z "$(git -C "$E" status --porcelain)" ] && ok || bad "fixture: the enclosing repo is not clean"
PATH="$T/ghbin:$PATH" DREAMTEAM_PRUNE_QUIET_HOURS=0 python3 -I "$PN" --quarantine "$T/qenc" "$E/wt" "$TONIGHT" > "$T/out/enc.json" 2>/dev/null
[ "$(cat "$E/wt/2026-11-01/kid/only-here.txt" 2>/dev/null)" = keep ] && jq -e '.moved == [] and (.kept | length) == 1' "$T/out/enc.json" >/dev/null && ok || bad "a broken clone inside an enclosing repo was judged as it: $(cat "$T/out/enc.json")"

# ── the forge cannot be asked: keep ─────────────────────────────────────────────────────────────────────────────
N5=2026-11-11; mkclone $N5 f1
touch "$T/gh.down"; prune; rm -f "$T/gh.down"; kept_as $N5/f1 "the forge could not be asked"
# ...also when it names the default branch and then fails on the comparison itself (an unanswered question is not a yes)
touch "$T/gh.cmpdown"; prune; rm -f "$T/gh.cmpdown"; kept_as $N5/f1 "the forge could not be asked"
mkdir "$T/nogh"; for b in python3 git env sh bash; do ln -s "$(command -v $b)" "$T/nogh/$b"; done
PATH="$T/nogh" DREAMTEAM_PRUNE_QUIET_HOURS=0 python3 -I "$PN" --quarantine "$Q" "$B" "$TONIGHT" > "$T/out/res.json" 2>/dev/null; kept_as $N5/f1 "the forge could not be asked"
prune; goes $N5/f1                                           # control: the same clone goes once the forge answers

# ── someone is using it ─────────────────────────────────────────────────────────────────────────────────────────
N2=2026-11-09
mkclone $N2 busy; ( cd "$B/$N2/busy" && exec sleep 60 ) & BG+=("$!"); busy_pid=$!
mkclone $N2 openfd; ( exec 7< "$B/$N2/openfd/f.txt"; exec sleep 60 ) & BG+=("$!"); fd_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ "$(readlink "/proc/$busy_pid/cwd" 2>/dev/null)" = "$B/$N2/busy" ] && [ "$(readlink "/proc/$fd_pid/fd/7" 2>/dev/null)" = "$B/$N2/openfd/f.txt" ] && break; sleep 0.1
done
mkclone $N2 fresh; mkclone $N2 quietold
for d in quietold busy openfd; do touch -d '2 days ago' "$B/$N2/$d" "$B/$N2/$d/.git" "$B/$N2/$d/.git/HEAD" "$B/$N2/$d/.git/index" "$B/$N2/$d/.git/logs/HEAD" "$B/$N2/$d/.git/config" "$B/$N2/$d/.git/refs" "$B/$N2/$d/.git/refs/heads"; done
QUIET_H=6 prune
kept_as $N2/busy "a process is working in it (pid $busy_pid)"
kept_as $N2/openfd "a process has a file open in it (pid $fd_pid)"
kept_as $N2/fresh "quiet period 6 h"
goes $N2/quietold
kill "$busy_pid" "$fd_pid" 2>/dev/null; wait "$busy_pid" "$fd_pid" 2>/dev/null

# ── judgment failures: a git that fails or stalls on ONE call means keep ────────────────────────────────────────
stubgit() { printf '#!/bin/sh\ncase " $* " in *" %s "*) %s ;; esac\nexec %s "$@"\n' "$1" "$2" "$REALGIT" > "$T/gitbin/git"; chmod +x "$T/gitbin/git"; }
N3=2026-11-08
for sub in config status ls-files rev-list symbolic-ref for-each-ref; do
  mkclone $N3 "f-$sub"; stubgit "$sub" "exit 3"
  EXTRA_PATH="$T/gitbin" prune
  [ -d "$B/$N3/f-$sub/.git" ] && [ -n "$(why "$N3/f-$sub")" ] && ok || bad "git $sub failing did not keep the clone"
done
mkclone $N3 stall; stubgit status "exec sleep 30"
s0=$(date +%s); DREAMTEAM_PRUNE_GIT_TIMEOUT=1 EXTRA_PATH="$T/gitbin" prune; s1=$(date +%s)
kept_as $N3/stall "git status did not finish"; [ $((s1-s0)) -lt 40 ] && ok || bad "a stalled git took $((s1-s0)) s"
prune; pruned $N3/stall && pruned $N3/f-status && pruned $N3/f-config && ok || bad "control: the same clones were not removed with a working git"

# ── --dry-run changes nothing ───────────────────────────────────────────────────────────────────────────────────
N4=2026-11-07; mkclone $N4 dry
before=$(find "$B/$N4" "$Q" | sort | sha256sum)
prune --dry-run
[ "$(jq -r .dry_run "$T/out/res.json")" = true ] && pruned $N4/dry && [ "$(find "$B/$N4" "$Q" | sort | sha256sum)" = "$before" ] && ok || bad "--dry-run changed something or did not list the clone"

# ── between judgment and the move (a driver wraps the tool's own functions to act at the exact moment) ──────────
cat > "$T/drv.py" <<'EOP'
import errno, importlib.util, os, shutil, sys
spec = importlib.util.spec_from_file_location("pn", sys.argv[1]); pn = importlib.util.module_from_spec(spec); spec.loader.exec_module(pn)
mode, extra, qdir = sys.argv[4], sys.argv[5], sys.argv[6]
real_judge, real_users, real_rename, real_manifest, seen = pn.judge, pn.users_of, os.rename, pn.manifest, {"n": 0, "m": 0}
def judge(path, fd, now, dry):
    why = real_judge(path, fd, now, dry)
    if why is None and mode == "swap" and path.endswith("/swap"):
        real_rename(path, path + ".judged")            # the judged clone is moved away...
        os.mkdir(path); shutil.copy(extra, path + "/newcomer.txt")     # ...and something else takes its name
    if why is None and mode == "latewrite" and path.endswith("/latewrite"):
        shutil.copy(extra, path + "/arrived.txt")      # a write that lands after the first judgment
    return why
def users_of(real, skip):
    if mode == "outside" and "/.pruning-" in real and not seen["n"]:
        seen["n"] = 1
        real_rename(real, extra + ".moved-outside")    # after it was set aside and opened: moved out of the night...
        os.symlink(extra + ".moved-outside", real)     # ...with a symlink left at its name
    return real_users(real, skip)
def rename(src, dst, *, src_dir_fd=None, dst_dir_fd=None):
    if mode in ("xdev", "badcopy") and dst_dir_fd is not None and src_dir_fd is not None and dst_dir_fd != src_dir_fd:
        raise OSError(errno.EXDEV, "cross-device (injected)")          # the quarantine is on another filesystem
    return real_rename(src, dst, src_dir_fd=src_dir_fd, dst_dir_fd=dst_dir_fd)
def manifest(root):
    out = real_manifest(root)
    seen["m"] += 1
    return out[:-1] if mode == "badcopy" and seen["m"] == 2 else out   # the copy "lost" one entry
pn.judge, pn.users_of, pn.manifest, os.rename = judge, users_of, manifest, rename
sys.exit(pn.main(["prune_nights.py", "--quarantine", qdir, sys.argv[2], sys.argv[3]]))
EOP
drv() { PATH="$T/ghbin:$PATH" DREAMTEAM_PRUNE_QUIET_HOURS=0 python3 -I "$T/drv.py" "$PN" "$B" "$TONIGHT" "$1" "$T/newcomer.txt" "$Q" > "$T/out/res.json" 2> "$T/out/err"; }
echo "arrived later" > "$T/newcomer.txt"
N6=2026-11-06
mkclone $N6 swap; drv swap
[ "$(cat "$B/$N6/swap/newcomer.txt" 2>/dev/null)" = "arrived later" ] && ok || bad "the directory that took the clone's name was moved or deleted: $(ls -a "$B/$N6")"
[ -d "$B/$N6/swap.judged/.git" ] && ok || bad "the judged clone, moved away by someone else, was taken through its old name"
kept_as $N6/swap "replaced while being judged"
rm -rf "$B/$N6/swap" "$B/$N6/swap.judged"
mkclone $N6 latewrite; drv latewrite
kept_as $N6/latewrite "uncommitted or untracked files (found after it was set aside)"
[ "$(cat "$B/$N6/latewrite/arrived.txt" 2>/dev/null)" = "arrived later" ] && [ -d "$B/$N6/latewrite/.git" ] && ok || bad "a write that landed after the first judgment was lost, or the clone was not put back: $(ls -a "$B/$N6")"
rm -rf "$B/$N6/latewrite"
# moved out of the night with a symlink left at its name, after it was set aside: nothing is taken, wherever it is
mkclone $N6 outside; drv outside
case "$(why $N6/outside)" in *"moved or replaced after being set aside"*) ok ;; *) bad "outside: why='$(why $N6/outside)'" ;; esac
[ -d "$T/newcomer.txt.moved-outside/.git" ] && [ "$(cat "$T/newcomer.txt.moved-outside/f.txt")" = one ] && ok || bad "a directory moved outside its night was emptied or moved"
! ls "$Q" | grep -q "__outside__" && ok || bad "something reached the quarantine through a symlink"
rm -rf "$B/$N6"/.pruning-outside-* "$T/newcomer.txt.moved-outside"
# the quarantine on ANOTHER filesystem (injected EXDEV): copy, compare, publish, then empty the original
mkclone $N6 xdev; ln -s f.txt "$B/$N6/xdev/alink"; git -C "$B/$N6/xdev" add alink; git -C "$B/$N6/xdev" commit -q -m link; topush "$B/$N6/xdev" main
m0=$(cd "$B/$N6/xdev" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)
drv xdev
goes $N6/xdev
qx=$(ls -d "$Q"/${N6}__xdev__q20261120 2>/dev/null)
[ -n "$qx" ] && [ "$(cd "$qx" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)" = "$m0" ] && [ -L "$qx/alink" ] && ok || bad "the copy across filesystems is not the clone, byte for byte (or a symlink was followed)"
! ls -a "$Q" "$B/$N6" 2>/dev/null | grep -qE '\.partial$|^\.pruning-' && ok || bad "a .partial or .pruning- entry was left: $(ls -a "$Q" "$B/$N6" 2>/dev/null | grep -E 'partial|pruning' | tr '\n' ' ')"
# ...and a copy that does not match is removed, the clone stays in its night under its own name
mkclone $N6 badcopy; drv badcopy
kept_as $N6/badcopy "its copy in the quarantine did not match"
[ -d "$B/$N6/badcopy/.git" ] && ! ls -a "$Q" | grep -q "badcopy" && ok || bad "after a bad copy: night=$(ls -a "$B/$N6" | tr '\n' ' ') quarantine=$(ls -a "$Q" | grep badcopy | tr '\n' ' ')"

# ── the quarantine itself: expiry by the date in the name, the free-space floor, name collisions ────────────────
mkdir -p "$Q/2026-10-01__old__q20261101" "$Q/2026-10-20__edge__q20261106" "$Q/2026-10-21__young__q20261107" "$Q/not-ours" "$Q/2026-10-01__x__q2026"
echo keep > "$Q/2026-10-01__old__q20261101/f"; echo keep > "$Q/not-ours/f"; ln -s "$T/target" "$Q/2026-09-01__lnk__q20260901"
touch -d '100 days ago' "$Q/2026-10-21__young__q20261107" "$Q/not-ours"                         # mtime must not matter
prune
[ ! -e "$Q/2026-10-01__old__q20261101" ] && [ ! -e "$Q/2026-10-20__edge__q20261106" ] && ok || bad "entries 19 and 14 days in quarantine were not deleted"
[ -d "$Q/2026-10-21__young__q20261107" ] && ok || bad "an entry 13 days in quarantine was deleted (or judged by mtime)"
[ "$(cat "$Q/not-ours/f")" = keep ] && [ -d "$Q/2026-10-01__x__q2026" ] && [ -L "$Q/2026-09-01__lnk__q20260901" ] && [ "$(cat "$T/target/p.txt")" = precious ] && ok || bad "something that is not a quarantine entry of ours was deleted or followed"
[ "$(jq -c '.expired' "$T/out/res.json")" = '["2026-10-01__old__q20261101","2026-10-20__edge__q20261106"]' ] && ok || bad "expired list: $(jq -c .expired "$T/out/res.json")"
# under the floor: nothing is moved or judged, the result says so, and expiry still runs (it is what frees space)
N7=2026-11-04; mkclone $N7 floor; mkdir -p "$Q/2026-10-02__old2__q20261101"; : > "$T/gh.calls"
DREAMTEAM_PRUNE_FREE_PCT=9 prune
[ "$(jq -c '.quarantine | [.refused, .free_pct]' "$T/out/res.json")" = '[true,9]' ] && [ -d "$B/$N7/floor/.git" ] && [ "$(jq '.moved | length' "$T/out/res.json")" = 0 ] && ok || bad "under the floor: $(jq -c '[.quarantine, .moved]' "$T/out/res.json")"
[ ! -e "$Q/2026-10-02__old2__q20261101" ] && [ ! -s "$T/gh.calls" ] && ok || bad "under the floor: expiry did not run, or clones were judged"
# a free share that cannot be READ is a refusal too (unknown is never "enough room")
DREAMTEAM_PRUNE_FREE_PCT=unreadable prune
[ "$(jq -c '.quarantine | [.refused, .free_pct]' "$T/out/res.json")" = '[true,null]' ] && [ -d "$B/$N7/floor/.git" ] && ok || bad "an unreadable free share: $(jq -c '[.quarantine, .moved]' "$T/out/res.json")"
DREAMTEAM_PRUNE_FREE_PCT=10 prune; goes $N7/floor                                                # exactly at the floor is enough
# a name already in the quarantine is never overwritten: the newcomer gets a numbered name
mkclone $N7 twin; mkdir -p "$Q/${N7}__twin__q20261120"; echo first > "$Q/${N7}__twin__q20261120/mark"
prune; [ "$(cat "$Q/${N7}__twin__q20261120/mark")" = first ] && [ -d "$Q/${N7}__twin__q20261120-2/.git" ] && ok || bad "a quarantine name collision: $(ls "$Q" | grep twin | tr '\n' ' ')"

# ── arguments and the base itself ───────────────────────────────────────────────────────────────────────────────
python3 -I "$PN" >/dev/null 2>&1; [ "$?" = 22 ] && ok || bad "no arguments not 22"
python3 -I "$PN" "$B" 2026-13-40 >/dev/null 2>&1; [ "$?" = 22 ] && ok || bad "an impossible tonight not 22"
python3 -I "$PN" relative/dir "$TONIGHT" >/dev/null 2>&1; [ "$?" = 22 ] && ok || bad "a relative base not 22"
python3 -I "$PN" "$B" "$TONIGHT" >/dev/null 2>&1; [ "$?" = 22 ] && ok || bad "no --quarantine not 22"
python3 -I "$PN" --quarantine relative/q "$B" "$TONIGHT" >/dev/null 2>&1; [ "$?" = 22 ] && ok || bad "a relative quarantine not 22"
python3 -I "$PN" --quarantine "$Q" --keep-days 0 "$B" "$TONIGHT" >/dev/null 2>&1; [ "$?" = 22 ] && ok || bad "--keep-days 0 not 22"
python3 -I "$PN" --quarantine "$Q" --nope "$B" "$TONIGHT" >/dev/null 2>&1; [ "$?" = 22 ] && ok || bad "an unknown option not 22"
python3 -I "$PN" --quarantine "$Q" "$T/nowhere" "$TONIGHT" >/dev/null 2>&1; [ "$?" = 2 ] && ok || bad "a missing base not 2"
ln -s "$B" "$T/wtlink"; mkclone 2026-11-05 vialink
PATH="$T/ghbin:$PATH" python3 -I "$PN" --quarantine "$Q" "$T/wtlink" "$TONIGHT" >/dev/null 2>&1; [ "$?" = 2 ] && [ -d "$B/2026-11-05/vialink/.git" ] && ok || bad "a symlinked base was followed"
# the quarantine must be a plain directory OUTSIDE the base, with no symlink in its path
PATH="$T/ghbin:$PATH" python3 -I "$PN" --quarantine "$B/inside-q" "$B" "$TONIGHT" >/dev/null 2>&1; [ "$?" = 2 ] && [ -d "$B/2026-11-05/vialink/.git" ] && ok || bad "a quarantine inside the base was accepted"
ln -s "$Q" "$T/qlink"; PATH="$T/ghbin:$PATH" python3 -I "$PN" --quarantine "$T/qlink" "$B" "$TONIGHT" >/dev/null 2>&1; [ "$?" = 2 ] && [ -d "$B/2026-11-05/vialink/.git" ] && ok || bad "a symlinked quarantine was accepted"
PATH="$T/ghbin:$PATH" DREAMTEAM_PRUNE_QUIET_HOURS=0 python3 -I "$PN" --quarantine "$T/newq/deep" --keep-days 30 --min-free-pct 0 "$B" "$TONIGHT" > "$T/out/res.json" 2>/dev/null
[ "$?" = 0 ] && [ -d "$T/newq/deep/2026-11-05__vialink__q20261120/.git" ] && [ "$(jq -c '.quarantine | [.keep_days, .min_free_pct]' "$T/out/res.json")" = '[30,0]' ] && ok || bad "a new quarantine dir was not created and used: $(ls "$T/newq/deep" 2>&1 | tr '\n' ' ')"

echo "prune-nights: $pass passed, $fail failed"
[ "$fail" = 0 ]
