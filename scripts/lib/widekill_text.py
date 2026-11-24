"""dreamteam wide-kill guard: does this command text kill a test runner BY NAME, host-wide?

wide-kill-guard.sh hands the raw command on stdin. Exit 0 = yes (the guard blocks), 1 = no. Any other exit is
an error, and the guard blocks then too: a command it cannot judge is not run.

HOW THE TEXT IS READ. Comments are dropped. Quotes are tracked. The text is cut into PIPELINES at an unquoted
`;`, newline, `&&`, `||` or `&`: inside one pipeline data flows from left to right, between two it does not. A program is recognised only in COMMAND POSITION
(first word, or after `|`, `(`, `{`, a backtick, an assignment, or a wrapper such as sudo, command, exec, env,
nohup, time, timeout, nice, ionice, xargs, do, then, else, whose own options and values are skipped:
`sudo -n pkill`, `env -i pkill`, `timeout -k 1 5 pkill`), with or without a path (`/usr/bin/pkill`).
`ls -l /usr/bin/pkill` names a file, not a command.

THREE FORMS (Flow row 62d79dae; each is a command an agent wrote on serialhub or a reviewer's natural variant):
  (A) pkill / killall whose OWN arguments name a test runner. The arguments end at the first shell operator
      outside quotes and outside the call's own `$( )`: `pkill -f server.py || make test` names no runner,
      `pkill -f "map_server|make test"` does. A pkill call is let through when it narrows its SELECTION:
      -P/--parent, -g/--pgroup, -s/--session, -t/--terminal, -F/--pidfile, --cgroup, each with an operand
      (quoted, attached or separate), read from the call's own words: the `-s` in
      `pkill -f "python -m pytest -s tests/x.py"` belongs to the quoted pattern. killall has no such flag (its
      -s names a SIGNAL, its -g signals whole groups), so killall is never let through.
  (B) ps / pgrep / pidof with a runner's name after it in the same pipeline, whose result FEEDS a kill:
        - a kill later in that same pipeline (`pgrep -f pytest | xargs kill`);
        - a variable bound to the listing (`for p in $(…)`, `P=$(…)`, `… | while read p`) that a later kill
          names (`for p in $(ps … | grep "make test" …); do kill $p; done`).
      A listing to look, then a kill of something else (`ps | grep pytest; kill "$PID"`, also with `&&`) is
      not this form.
  (C) kill whose own operands hold a command substitution whose BODY is such a listing
      (`kill $(pgrep -f pytest)`).
In (B) and (C) a `kill -0`, `kill -s 0` or `kill -l` is not a kill: it sends nothing (a liveness probe).
`[p]ytest`, the self-match trick, is read as `pytest`.

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
PATH = r"(?:^|(?<=[^\w.~/-]))(?:[\w.~-]*/)*"       # where a program word starts, with an optional path before it
KILLER = re.compile(PATH + r"(pkill|killall)(?=\s)")
LISTER = re.compile(PATH + r"(?:ps|pgrep|pidof)(?=\s)")
PROBE = r"(?!\s+(?:-0|-s\s*0|-l)(?:\s|$))"         # kill -0 / -s 0 / -l sends nothing: a liveness probe, not a kill
KILL_WORD = re.compile(r"(?:^|(?<=[^\w-]))kill(?=\s|$)" + PROBE)
# a narrowing flag WITH its operand. In the text this is matched on, every quoted or substituted character is
# the letter Q, so `-P "$$"` reads `-P QQQQ` and a `-s` inside a quoted pattern is not there at all.
NARROW = re.compile(r"(?:^|\s)(?:(?:-P|-g|-s|-t|-F)\s*[^\s-]"
                    r"|(?:--parent|--pgroup|--session|--terminal|--pidfile|--cgroup)(?:\s+|=)[^\s-])")
SELF_MATCH = re.compile(r"\[(\w)\]")
BOUND_BEFORE = re.compile(r"(?:\bfor\s+(\w+)\s+in\s|(?:^|[\s;(])(\w+)=[\"']?(?:\$\(|`))")
BOUND_AFTER = re.compile(r"\|\s*while\s+(?:IFS=\S*\s+)?read\s+(?:-\w+\s+)*(\w+)")
# wrapper → (its options that take a SEPARATE value, how many positional words come before its command).
# An option not listed is a flag (`sudo -n`, `env -i`, `xargs -r`); an attached value (`-c3`, `-n10`, `-I{}`,
# `--user=jp`) is one word and needs no entry. Shell keywords are wrappers with nothing of their own.
WRAPPERS = {
    "sudo": ({"-u", "-g", "-h", "-p", "-C", "-D", "-R", "-T", "-U", "-r", "-t", "--user", "--group", "--host", "--chdir"}, 0),
    "doas": ({"-u", "-C"}, 0),
    "env": ({"-u", "-C", "-S", "--unset", "--chdir", "--split-string"}, 0),
    "nice": ({"-n", "--adjustment"}, 0),
    "ionice": ({"-c", "-n", "-p", "--class", "--classdata"}, 0),
    "timeout": ({"-k", "-s", "--kill-after", "--signal"}, 1),                  # then DURATION
    "chrt": (set(), 1),                                                           # then PRIORITY
    "taskset": (set(), 1),                                                        # then MASK (or -c LIST: one word still)
    "flock": ({"-w", "--timeout", "-E", "--conflict-exit-code"}, 1),              # then the lock file
    "stdbuf": ({"-i", "-o", "-e"}, 0),
    "xargs": ({"-I", "-n", "-P", "-d", "-a", "-E", "-L", "-s", "--max-args", "--max-procs", "--delimiter", "--arg-file"}, 0),
    "exec": ({"-a"}, 0),
    "time": ({"-f", "-o", "--format", "--output"}, 0),
    "strace": ({"-o", "-e", "-p", "-s"}, 0),
    "watch": ({"-n", "--interval"}, 0),
}
for _w in ("command", "nohup", "builtin", "setsid", "do", "then", "else", "elif", "if", "while", "until", "!"):
    WRAPPERS[_w] = (set(), 0)
ASSIGN = re.compile(r"\w+=\S*")


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


def strip_comments(s):
    """The text without shell comments: an unquoted `#` at the start of a word, to the end of its line."""
    out, skipping, prev = [], False, ""
    for c, quoted in spans(s):
        if skipping:
            if c != "\n":
                continue
            skipping = False
        if not quoted and c == "#" and (prev == "" or prev in " \t\n;|&("):
            skipping = True
            continue
        out.append(c)
        prev = c
    return "".join(out)


def cut(s, pipelines=False):
    """[(start, part)]: the text cut at every unquoted `;` or newline (statements); with pipelines=True also
    at every unquoted `&&`, `||` and `&`, so each part is one pipeline."""
    out, cur, start, i, prev, last = [], [], 0, 0, ("", True), ""
    chars = list(spans(s))
    n = len(chars)
    while i < n:
        c, quoted = chars[i]
        width = 0
        if not quoted:
            if c == "\n" and last == "|":                  # a newline right after `|` continues the pipeline
                cur.append(" ")
                i += 1
                continue
            if c in ";\n":
                width = 1
            elif pipelines and c in "&|" and i + 1 < n and chars[i + 1] == (c, False):
                width = 2
            elif pipelines and c == "&" and prev != (">", False) and not (i + 1 < n and chars[i + 1][0] == ">"):
                width = 1                                  # a lone & (not >& or &>)
        if width:
            out.append((start, "".join(cur)))
            cur, start = [], i + width
            i += width
        else:
            cur.append(c)
            i += 1
        prev = (c, quoted)
        if quoted or not c.isspace():
            last = "" if quoted or width else c            # the last unquoted non-blank character of this part
    out.append((start, "".join(cur)))
    return out


def command_position(s, i):
    """Is the word starting at s[i] a command, not an argument?

    Yes when it is the first word of its simple command, or when everything before it in that simple command is
    assignments and WRAPPERS with their own options and values (`sudo -n`, `sudo -u jp`, `env -i A=1`,
    `nice -n 10`, `ionice -c3`, `timeout -k 1 5`, `xargs -r`). The WRAPPERS table says which options of a wrapper
    take a separate value and how many positional words it has before its command; any other option is a flag.
    The first plain word that is none of these IS the command (`sudo -n ls -l /usr/bin/pkill` runs ls), and
    anything after it is an argument. Same idea as gpu_detect's runner options."""
    j = i
    while j > 0 and s[j - 1] not in ";|&({\n`":
        j -= 1
    words = s[j:i].split()
    takes, positional, want_value = None, 0, False       # the wrapper in force: its value options, positionals left
    for w in words:
        if want_value:
            want_value = False                             # the value of the option before it
        elif takes is not None and w.startswith("-"):
            want_value = w in takes
        elif takes is not None and positional > 0:
            positional -= 1                                # timeout's DURATION, flock's file
        elif w in WRAPPERS:
            takes, positional = WRAPPERS[w]
        elif ASSIGN.fullmatch(w):
            pass                                           # FOO=1 cmd, env A=1 cmd
        else:
            return False                                   # a plain word: THAT is the command; ours is its argument
    return not want_value and positional == 0


def own_args(s, start):
    """(full, masked) text of the simple command starting at `start`: up to the first unquoted shell operator
    that is not inside a `$( )` or backtick substitution the command itself opened. In `masked` every quoted
    or substituted character is the letter Q, so only the command's own words and flags remain readable."""
    full, masked = [], []
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
        masked.append("Q" if (quoted or inside) else c)
        prev = c
    return "".join(full), "".join(masked)


def subst_bodies(s):
    """The body of every `$( … )` and backtick substitution in s (outermost ones; quotes do not hide them)."""
    out, i, n = [], 0, len(s)
    while i < n:
        if s.startswith("$(", i):
            depth, j = 1, i + 2
            while j < n and depth:
                depth += (s[j] == "(") - (s[j] == ")")
                j += 1
            out.append(s[i + 2:j - 1] if depth == 0 else s[i + 2:])
            i = j
        elif s[i] == "`":
            j = s.find("`", i + 1)
            out.append(s[i + 1:j] if j >= 0 else s[i + 1:])
            i = n if j < 0 else j + 1
        else:
            i += 1
    return out


def listed(part):
    """Yield (listing start, end of the runner's name) for each ps/pgrep/pidof in command position in `part`
    that has a runner's name after it."""
    for m in LISTER.finditer(part):
        if command_position(part, m.start()):
            r = RUNNER.search(part, m.end())
            if r:
                yield m.start(), r.end()


def wide(text):
    text = strip_comments(SELF_MATCH.sub(r"\1", text))
    for m in KILLER.finditer(text):                       # (A)
        if not command_position(text, m.start()):
            continue
        full, masked = own_args(text, m.start())
        if RUNNER.search(full) and not (m.group(1) == "pkill" and NARROW.search(masked)):
            return True
    for m in KILL_WORD.finditer(text):                    # (C)
        for body in subst_bodies(own_args(text, m.start())[0]):
            for part_start, part in cut(body, pipelines=True):
                if any(True for _ in listed(part)):
                    return True
    for p_start, part in cut(text, pipelines=True):       # (B)
        for l_start, r_end in listed(part):
            if KILL_WORD.search(part, r_end):              # the same pipeline carries the listing to a kill
                return True
            names = {a or b for a, b in BOUND_BEFORE.findall(part[:l_start])}
            names |= set(BOUND_AFTER.findall(part[r_end:]))
            names.discard("")
            rest = text[p_start + len(part):]
            for k in KILL_WORD.finditer(rest):             # a later kill that names a variable bound to it
                operands = own_args(rest, k.start())[0]     # that kill's own operands, nothing after && || |
                if any(re.search(r"\$\{?" + re.escape(n) + r"\b", operands) for n in names):
                    return True
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
