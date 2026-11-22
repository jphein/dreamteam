"""dreamteam wide-kill guard: does this command text kill a test runner BY NAME, host-wide?

wide-kill-guard.sh hands the raw command on stdin. Exit 0 = yes (the guard blocks), 1 = no. Any other exit is
an error and the guard allows: it is a speed bump against the natural one-liner, not a boundary.

Three forms (Flow row 62d79dae; each is a command an agent wrote on serialhub or a reviewer's natural variant).
A program counts under a path too (`/usr/bin/pkill`).
  (A) pkill / killall whose OWN arguments name a test runner. The call's arguments end at the first shell
      operator OUTSIDE quotes and outside its own `$( )` (`|`, `;`, `&`, newline, `)`, a backtick), so
      `pkill -f server.py || make test` names no runner while `pkill -f "map_server|make test"` does.
      A pkill call is let through when it narrows its SELECTION: -P/--parent, -g/--pgroup, -s/--session,
      -t/--terminal, -F/--pidfile, --cgroup, each with an operand, read from the call's UNQUOTED words only
      (the `-s` in `pkill -f "python -m pytest -s tests/x.py"` belongs to the pattern). killall has no such
      flag: its -s names a SIGNAL and its -g signals the matches' whole groups, so killall is never let through.
  (B) ps / pgrep / pidof with a runner's name in the same statement, whose result FEEDS a kill:
        - a kill later in that same statement (`pgrep -f pytest | xargs kill`);
        - a variable bound to the listing (`for p in $(…)`, `PID=$(…)`, `… | while read p`) and a later kill
          that names that variable (`for p in $(ps … | grep "make test" …); do kill $p; done`).
      A listing followed by a kill of something else (`ps | grep pytest; kill "$PID"`, the pid captured at
      launch) is not this form.
  (C) kill whose own operands hold a command substitution with such a listing (`kill $(pgrep -f pytest)`).
In (B) and (C) a `kill -0`, `kill -s 0` or `kill -l` is not a kill: it sends nothing (a liveness probe).
A statement ends at an unquoted `;` or newline. `[p]ytest`, the self-match trick, is read as `pytest`.

A heredoc body that only ever lands as data (a commit message, an issue body) is removed first by
nopoll_text.data_text, the no-poll guard's reader (#191); anything that reader does not model is judged whole.
Pure: no subprocess, no file reads beyond the import.
"""
import os
import re
import sys

RUNNERS = (r"pytest|py\.test|unittest|make +(?:test|check)|tests/run\.sh|cargo +test|go +test"
           r"|npm +(?:run +)?test|jest|vitest")
RUNNER = re.compile(RUNNERS)
PROG = r"(?:^|(?<=[^\w.~/-]))(?:[\w.~-]*/)*"       # where a program word starts, with an optional path before it
KILLER = re.compile(PROG + r"(pkill|killall)(?=\s)")
LISTING = PROG + r"(?:ps|pgrep|pidof)\s"
LISTED = re.compile(LISTING + r".*?(?:" + RUNNERS + r")", re.S)
SUBST_LISTED = re.compile(r"(?:\$\(|`).*?" + LISTING + r".*?(?:" + RUNNERS + r")", re.S)
PROBE = r"(?!\s+(?:-0|-s\s*0|-l)(?:\s|$))"         # kill -0 / -s 0 / -l sends nothing: a liveness probe, not a kill
KILL_WORD = re.compile(r"(?:^|(?<=[^\w-]))kill(?=\s|$)" + PROBE)
NARROW = re.compile(r"(?:^|\s)(?:-P|-g|-s|-t|-F|--parent|--pgroup|--session|--terminal|--pidfile|--cgroup)(?:\s+\S|=\S)")
SELF_MATCH = re.compile(r"\[(\w)\]")
BOUND_BEFORE = re.compile(r"(?:\bfor\s+(\w+)\s+in\s|(?:^|[\s;(])(\w+)=[\"']?(?:\$\(|`))")
BOUND_AFTER = re.compile(r"\|\s*while\s+(?:IFS=\S*\s+)?read\s+(?:-\w+\s+)*(\w+)")


def spans(s):
    """Yield (char, quoted) for every character: quoted is True inside '…', "…" or after a backslash."""
    q = None
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if q is None:
            if c == "\\" and i + 1 < n:
                yield c, True
                yield s[i + 1], True
                i += 2
                continue
            if c in "'\"":
                q = c
                yield c, True
            else:
                yield c, False
        else:
            if c == "\\" and q == '"' and i + 1 < n:
                yield c, True
                yield s[i + 1], True
                i += 2
                continue
            yield c, True
            if c == q:
                q = None
        i += 1


def statements(s):
    """The text cut at every unquoted `;` or newline."""
    out, cur = [], []
    for c, quoted in spans(s):
        if not quoted and c in ";\n":
            out.append("".join(cur))
            cur = []
        else:
            cur.append(c)
    out.append("".join(cur))
    return out


def own_args(s, start):
    """(full, bare) text of the simple command starting at `start`: up to the first unquoted shell operator
    that is not inside a `$( )` or backtick substitution the command itself opened. `bare` has every quoted or
    substituted character replaced by a space, so only the command's own words remain."""
    full, bare = [], []
    depth, tick, prev = 0, False, ""
    for c, quoted in spans(s[start:]):
        inside = depth > 0 or tick
        if not quoted:
            if c == "`":                                  # opens or closes a substitution among the arguments
                tick = not tick
                inside = True
            elif c == "(" and prev == "$":
                depth += 1
                inside = True
            elif c == ")" and depth > 0:
                depth -= 1
            elif not inside and c in "|;&\n)":
                break
        full.append(c)
        bare.append(" " if (quoted or inside) else c)
        prev = c
    return "".join(full), "".join(bare)


def wide(text):
    text = SELF_MATCH.sub(r"\1", text)
    for m in KILLER.finditer(text):                       # (A)
        full, bare = own_args(text, m.start())
        if RUNNER.search(full) and not (m.group(1) == "pkill" and NARROW.search(bare)):
            return True
    for m in KILL_WORD.finditer(text):                    # (C)
        if SUBST_LISTED.search(own_args(text, m.start())[0]):
            return True
    offset = 0
    for st in statements(text):                           # (B)
        m = LISTED.search(st)
        if m:
            if KILL_WORD.search(st, m.end()):
                return True
            names = {a or b for a, b in BOUND_BEFORE.findall(st[:m.start()])}
            names |= set(BOUND_AFTER.findall(st[m.end():]))
            names.discard("")
            rest = text[offset + len(st):]
            for k in KILL_WORD.finditer(rest):
                operands = re.split(r"[;\n]", rest[k.end():], maxsplit=1)[0]
                if any(re.search(r"\$\{?" + re.escape(n) + r"\b", operands) for n in names):
                    return True
        offset += len(st) + 1
    return False


def main():
    raw = sys.stdin.read()
    if not wide(raw):
        return 1
    if "<<" in raw:
        try:
            sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
            import nopoll_text
            if not wide(nopoll_text.data_text(raw)):
                return 1
        except Exception:                                 # the reader failed: judge the whole text (keep the block)
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
