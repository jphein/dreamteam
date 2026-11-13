#!/usr/bin/env bash
# scripts/headless-chrome against a STUB google-chrome on PATH (no real browser).
# Covers: the flags it adds, caller overrides, the fresh profile's location and removal,
# exit-status passthrough, TERM forwarding, browser selection, and no-browser = 127.
set -uo pipefail
R="$(cd "$(dirname "$0")/.." && pwd)"; W="$R/scripts/headless-chrome"
pass=0; fail=0
ok()  { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
T=$(mktemp -d "${XDG_RUNTIME_DIR:-$HOME/.cache}/test-headless-chrome.XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/bin" "$T/run" "$T/home"
# stub: records argv; mode via STUB_MODE: rc7 exits 7, sleep waits for TERM and records it
cat > "$T/bin/google-chrome" <<S
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$T/argv"
for a in "\$@"; do case "\$a" in --user-data-dir=*) d=\${a#--user-data-dir=}; [ -d "\$d" ] && echo exists > "$T/profile-seen"; echo "\$d" > "$T/profile";; esac; done
case "\${STUB_MODE:-}" in
  rc7) exit 7 ;;
  sleep) trap 'echo term > "$T/got-term"; exit 143' TERM; echo \$\$ > "$T/stub.pid"; echo up > "$T/up"; for _ in \$(seq 100); do sleep 0.1; done; exit 0 ;;
esac
exit 0
S
chmod +x "$T/bin/google-chrome"
run() { env -i HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" XDG_RUNTIME_DIR="$T/run" STUB_MODE="${STUB_MODE:-}" "$@"; }

run "$W" --dump-dom http://x/; rc=$?
grep -qx -- --headless=new "$T/argv" && grep -qx -- --disable-extensions "$T/argv" && grep -qx -- --no-first-run "$T/argv" \
  && grep -qx -- --dump-dom "$T/argv" && [ "$rc" = 0 ] \
  && ok "adds --headless=new --disable-extensions --no-first-run and passes the caller's args" || bad "flags rc=$rc $(tr '\n' ' ' < "$T/argv")"
p=$(cat "$T/profile"); case "$p" in "$T/run/headless-chrome."*) ok "fresh profile under XDG_RUNTIME_DIR ($p)" ;; *) bad "profile at $p" ;; esac
[ -s "$T/profile-seen" ] && [ ! -e "$p" ] && ok "the profile existed while Chrome ran and is removed afterwards" || bad "profile lifecycle"

rm -f "$T/profile-seen"
env -i HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" "$W" about:blank
case "$(cat "$T/profile")" in "$T/home/.cache/headless-chrome."*) ok "no XDG_RUNTIME_DIR: profile under ~/.cache" ;; *) bad "fallback profile $(cat "$T/profile")" ;; esac

run "$W" --headless=old --user-data-dir="$T/mine" about:blank
[ "$(grep -c -- '^--headless' "$T/argv")" = 1 ] && grep -qx -- --headless=old "$T/argv" \
  && [ "$(grep -c -- '^--user-data-dir' "$T/argv")" = 1 ] && grep -qx -- "--user-data-dir=$T/mine" "$T/argv" \
  && grep -qx -- --disable-extensions "$T/argv" \
  && ok "caller's --headless and --user-data-dir win; --disable-extensions still added" || bad "overrides $(tr '\n' ' ' < "$T/argv")"

STUB_MODE=rc7 run "$W" about:blank; rc=$?
[ "$rc" = 7 ] && ok "Chrome's exit status passes through (7)" || bad "rc passthrough got $rc"

rm -f "$T/up" "$T/got-term"
# output to a file, not the test's pipe: an unforwarded stub must not hold a reader open
env -i HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" XDG_RUNTIME_DIR="$T/run" STUB_MODE=sleep "$W" about:blank > "$T/w.out" 2>&1 & wp=$!
for _ in $(seq 50); do [ -e "$T/up" ] && break; sleep 0.1; done
kill -TERM "$wp"; wait "$wp"; rc=$?
for _ in $(seq 20); do [ -s "$T/got-term" ] && break; sleep 0.1; done
sp=$(cat "$T/stub.pid" 2>/dev/null); [ -n "$sp" ] && kill -0 "$sp" 2>/dev/null && { kill -KILL "$sp"; echo "  (stub $sp still running after the wrapper died: killed)"; }
[ -s "$T/got-term" ] && [ "$rc" = 143 ] && [ ! -e "$(cat "$T/profile")" ] \
  && ok "TERM to the wrapper reaches Chrome (143) and the profile is still removed" || bad "TERM forwarding rc=$rc got-term=$([ -s "$T/got-term" ] && echo yes)"

mkdir -p "$T/alt"; cp "$T/bin/google-chrome" "$T/alt/my-chrome"
env -i HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" HEADLESS_CHROME_BIN="$T/alt/my-chrome" HEADLESS_CHROME_DRY_RUN=1 "$W" x > "$T/dry"
[ "$(head -1 "$T/dry")" = "$T/alt/my-chrome" ] && ok "HEADLESS_CHROME_BIN is preferred; DRY_RUN prints argv" || bad "bin selection $(head -1 "$T/dry")"

mkdir -p "$T/empty"; env -i HOME="$T/home" PATH="$T/empty" /bin/bash "$W" x 2>/dev/null; rc=$?
[ "$rc" = 127 ] && ok "no browser on PATH: exit 127" || bad "no-browser rc=$rc"

echo "headless-chrome: $pass passed, $fail failed"; [ "$fail" = 0 ]
