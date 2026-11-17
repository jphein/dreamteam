# dreamteam — the one CHECK line a timer job writes (FOR-AGENTS rule 24; docs/CHECKS.md).
#
#   . "$ROOT/scripts/lib/check-line.sh"
#   check_line <name> <ok|warn|fail> "<fact>" "<next/owner>"     → echoes the line; publishes it; rc 1 if not published
#   check_name <base>                                              → <base> on familiar, <base>-<host> elsewhere
#
# The line is exactly three segments, `CHECK <name> <status> · <fact> · <next>`, because the Watch (plan
# checks.py, LINE) reads the fact as everything up to the FIRST " · ": a " · " inside the fact would push the rest
# into "next". So the fact's " · " become ", ", any other "·" becomes "," (no "·" is left in a fact, so none can form a
# separator with the delimiters around it: "a ·", "· a", "a · · b"), and every newline becomes a space. A status that is not ok, warn or
# fail is published as fail (an unknown verdict is never ok). The name must match the Watch's NAME
# ([a-z0-9][a-z0-9-]{0,63}) or nothing is published anywhere.
#
# Publication: a unique, exclusively created temp file in the checks dir, then `mv -T` over <name>.line, so a symlink
# at the destination is replaced and never followed, a directory there is refused, overlapping writers never share a
# temp file, and a reader never sees half a line. Dir: $DREAMTEAM_CHECKS_DIR, else ~/.local/state/checks (each host
# writes its own; the Watch reads familiar's folder, other hosts arrive by push: plan FRICTION 11-16 08:5x).

check_name() {   # check_name <base>
  local h="${DREAMTEAM_CHECK_HOST:-$(hostname 2>/dev/null)}"
  h=${h,,}; h=${h//[^a-z0-9-]/}; h=${h:-unknown-host}
  if [ "$h" = familiar ]; then printf '%s' "$1"; else printf '%s-%s' "$1" "$h"; fi
}

check_line() {   # check_line <name> <status> <fact> <next>
  local name="$1" st="$2" fact="$3" nxt="$4" dir tmp line
  case "$st" in ok|warn|fail) ;; *) fact="unknown status '${st//[^a-z]/}': ${fact}"; st=fail ;; esac
  fact=${fact//[$'\n\r']/ }
  fact=${fact// · /, }; fact=${fact//·/,}   # then NO "·" is left in a fact, so no separator can form at any edge
  nxt=${nxt//[$'\n\r']/ }
  line="CHECK ${name} ${st} · ${fact} · ${nxt}"
  if ! [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]]; then
    echo "check-line: refusing name '${name//[^[:print:]]/?}' (not [a-z0-9][a-z0-9-]{0,63}); not published" >&2
    echo "$line"; return 1
  fi
  echo "$line"
  dir="${DREAMTEAM_CHECKS_DIR:-$HOME/.local/state/checks}"
  mkdir -p "$dir" 2>/dev/null && [ -d "$dir" ] || { echo "check-line: no checks dir $dir" >&2; return 1; }
  tmp=$(mktemp "$dir/.$name.line.XXXXXX" 2>/dev/null) || { echo "check-line: cannot create a temp file in $dir" >&2; return 1; }
  if printf '%s\n' "$line" > "$tmp" && mv -T -f "$tmp" "$dir/$name.line" 2>/dev/null; then return 0; fi
  rm -f "$tmp"; echo "check-line: could not publish $dir/$name.line" >&2; return 1
}
