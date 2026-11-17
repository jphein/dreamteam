"""dreamteam no-poll guard: the command text with DATA heredoc bodies removed (#191).

no-poll-guard.sh matches command TEXT. A heredoc body is part of that text, but most heredocs are data: a commit
message, an issue body, a python edit script that quotes a file's old poll loop. On 2026-11-14 06:5x two such
commands were blocked as CI polling while nothing polled. Same lesson as the GPU guard's v1.3: a poll is where a
shell RUNS the text, not where the text is mentioned.

This prints the command with a heredoc body cut out only when every path its text can take is known to stop as
data. A body is KEPT (so the guard still judges it) when:
  - its owner is not a known data sink (bash, sh, ssh, eval, xargs, env, sudo, an unknown program ...);
  - a python owner runs it as its program and it names a process API (subprocess, os.system, exec( ...);
  - its delimiter is unquoted and the body holds `$(` or a backtick (bash runs those when it expands the body);
  - it is attached to a compound (`done <<EOF`), or its sink writes into a group, subshell, loop or if
    (output this reader does not follow), or a pipe carries it into one;
  - its sink's output reaches a non-sink: a pipe, `$(...)` or `<(...)` handed to one, an unknown fd;
  - it lands in a file or variable (`> f`, `tee f`, `x=$(cat <<EOF)`, `read x <<EOF`) and a later command
    that is not a data sink names that file or variable (`bash f`, `./f`, `eval "$x"`).
Anything this reader does not model (case, arithmetic, `>(...)`, backticks or `${...}` with commands in code,
function definitions, namerefs, unbalanced quotes) returns the command unchanged: the guard then judges the
whole text, as it did before #191. Fail closed means "judge more text", never "judge less".

Threat model: the guard is a speed bump against an agent NATURALLY writing a CI poll; its own text match is
already evadable on purpose (`gh  pr checks`). This reader must not make a natural poll slip, and is not meant
to stop deliberate evasion. Pure: no subprocess, no file reads. Usage: stdin = raw command; stdout = text.
"""
import fnmatch
import re
import sys

# programs that treat stdin and arguments as data and never run them (gh/python have conditions below)
SINKS = {"cat", "tee", "gh", "git", "jq", "wc", "head", "tail", "base64", "grep", "diff", "cmp",
         "read", "mapfile", "readarray", "echo", "printf", "cut", "tr", "md5sum", "sha256sum",
         "true", ":", "export", "local", "declare", "typeset", "readonly"}
PY = re.compile(r"python[0-9.]*$")
# a python program that can start a process (the natural ways an agent would poll from python)
SPAWN = re.compile(r"subprocess|\bos\s*\.\s*(system|popen|exec\w*|spawn\w*|posix_spawn\w*|fork\w*)\b|\bpty\b"
                   r"|pexpect|plumbum|__import__|importlib|\bexec\s*\(|\beval\s*\(|from\s+os\s+import"
                   r"|import\s+os\s+as|getattr\s*\(\s*os\b|\bctypes\b|multiprocessing|create_subprocess|runpy"
                   r"|__builtins__|\bbuiltins\s*\.|\bos\s*\.\s*__dict__|vars\s*\(\s*os\b")
OPENERS = {"{": "}", "if": "fi", "while": "done", "until": "done", "for": "done", "select": "done"}
CLOSERS = {"}", "fi", "done"}
SKIP = {"!", "time", "then", "else", "elif", "do", "in"}
BAIL_WORDS = {"case", "esac", "function", "coproc", ";;"}
DECL = {"export", "local", "declare", "typeset", "readonly"}
ASSIGN = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)(\[[^\]]*\])?\+?=")
DATA_EXT = {"md", "txt", "json", "jsonl", "csv", "tsv", "log", "yaml", "yml", "toml", "html", "xml", "diff",
            "patch", "rst", "msg"}
REDIR = re.compile(r"(&>>|&>|<<<|<<-|<<|>>|>&|<&|>\||<>|>|<)")
META = " \t\n;&|()<>"


class Bail(Exception):
    pass


def unq(w: str) -> str:
    return re.sub(r"\\(.)", r"\1", w.replace("'", "").replace('"', ""))


class Node:
    """A simple command (or the closer of a compound, which only owns redirections)."""
    def __init__(self, idx, frame, in_group, closer=False):
        self.idx, self.frame, self.in_group, self.closer = idx, frame, in_group, closer
        self.first, self.words, self.mentions, self.targets = None, [], [], []
        self.pipe_to, self.unknown_out, self.header = None, False, False
        self.assigns = []                              # NAME= words before the command, or a declaration's


class Frame:
    """Code read at one level: the top, or the inside of $( ) / <( )."""
    def __init__(self, kind, container=None, dest=None):
        self.kind, self.container, self.dest = kind, container, dest    # dest: arg | exec | ("var", name)
        self.opens = []                                                  # open groups / compounds here
        self.node = None
        self.pipe_from = None


def scan(s: str):
    n = len(s)
    nodes, heredocs, frames = [], [], [Frame("top")]
    pending = []                                   # heredocs waiting for the next newline token
    i = 0
    word, wstart = [], None
    redir_next = None                              # what the next word is: out | in | dup | heredoc delimiter op

    def in_group():
        return any(f.opens for f in frames)

    def cur():
        f = frames[-1]
        if f.node is None:
            f.node = Node(len(nodes), f, in_group())
            nodes.append(f.node)
            if f.pipe_from is not None:
                f.pipe_from.pipe_to = f.node
                f.pipe_from = None
        return f.node

    def end_cmd(pipe=False):
        f = frames[-1]
        f.pipe_from = f.node if pipe else None
        if pipe and f.node is None:
            raise Bail("pipe with no command")
        f.node = None

    def sub_dest():
        """Where the output of a $( ) opened now goes."""
        nd = cur()
        m = ASSIGN.match("".join(word))
        if m and redir_next is None and (nd.first is None or nd.first in DECL):
            return ("var", m.group(1))
        if nd.first is None and redir_next is None:
            return "exec"                          # $(...) in command position (or a for header): run or unknown
        return "arg"

    def push(kind, dest):
        nonlocal word, redir_next
        frames.append(Frame(kind, cur(), dest))
        wstack.append((word, redir_next))
        word, redir_next = [], None
        modes.append("code")

    def pop():
        nonlocal word, redir_next
        frames.pop()
        modes.pop()
        word, redir_next = wstack.pop()
        word.append("$()")

    def finish_word():
        nonlocal word, redir_next
        if not word:
            return
        raw = "".join(word)
        word = []
        f = frames[-1]
        nd = cur()
        nd.mentions.append(raw)
        if redir_next is not None:
            kind, redir_next = redir_next, None
            if kind == "out":
                nd.targets.append(raw)
            elif kind == "dup":
                if unq(raw) not in ("1", "2", "-"):
                    if unq(raw).isdigit():
                        nd.unknown_out = True
                    else:
                        nd.targets.append(raw)
            elif kind in ("<<", "<<-"):
                quoted = any(c in raw for c in "'\"\\")
                if "$" in raw or "`" in raw:
                    raise Bail("unmodelled delimiter quoting")
                delim = unq(raw)
                if not delim:
                    raise Bail("empty delimiter")
                heredocs.append({"owner": nd, "dash": kind == "<<-", "quoted": quoted, "delim": delim,
                                 "start": None, "end": None})
                pending.append(heredocs[-1])
            return
        if nd.closer:
            raise Bail("word after a compound's closer")
        bare = unq(raw)
        if nd.first is None and not nd.header:
            if raw in BAIL_WORDS or bare in BAIL_WORDS:
                raise Bail("unmodelled keyword " + bare)
            if raw in OPENERS:
                f.opens.append(OPENERS[raw])
                nd.in_group = True                 # its command (a condition, or the group's first) is inside
                for prev in nodes:                 # piped into a compound: its stdin feeds what is inside
                    if prev.pipe_to is nd:
                        prev.pipe_to = "GROUP"
                if raw in ("for", "select"):
                    nd.header = True
                return
            if raw in CLOSERS:
                if not f.opens or f.opens[-1] != raw:
                    raise Bail("unbalanced closer")
                f.opens.pop()
                f.node = Node(len(nodes), f, True, closer=True)
                nodes.append(f.node)
                return
            if raw in SKIP:
                return
            m = ASSIGN.match(raw)
            if m:
                nd.assigns.append(m.group(1))
                return                             # NAME=value before the command
            nd.first = bare
            return
        if nd.header and raw == "do":
            return
        if nd.first in DECL and raw.startswith("-") and "n" in raw:
            raise Bail("nameref")
        if nd.first in DECL:
            m = ASSIGN.match(raw)
            if m:
                nd.assigns.append(m.group(1))
        nd.words.append(raw)

    def read_balanced(j, open_c, close_c):
        """s[j] is just past an opener in a ${ } or array literal: return the index past the closer."""
        depth = 1
        while j < n:
            c = s[j]
            if c == "\\":
                j += 2
                continue
            if c == "'":
                k = s.find("'", j + 1)
                if k < 0:
                    raise Bail("unbalanced quote")
                j = k + 1
                continue
            if c == open_c:
                depth += 1
            elif c == close_c:
                depth -= 1
                if depth == 0:
                    return j + 1
            j += 1
        raise Bail("unbalanced")

    def read_bodies(j):
        """j is just past a newline token: consume every pending heredoc body, return the index after them."""
        for h in pending:
            h["start"] = j
            end_of_body = None
            while j < n:
                e = s.find("\n", j)
                line_end = n if e < 0 else e
                logical, k = s[j:line_end], line_end
                if not h["quoted"]:
                    # an unquoted body joins backslash-newlines before the delimiter is matched
                    while (len(logical) - len(logical.rstrip("\\"))) % 2 == 1 and k < n:
                        e2 = s.find("\n", k + 1)
                        e2 = n if e2 < 0 else e2
                        logical = logical[:-1] + s[k + 1:e2]
                        k = e2
                cmp = logical.lstrip("\t") if h["dash"] else logical
                if cmp == h["delim"]:
                    end_of_body = j
                    j = n if k >= n else k + 1
                    break
                j = n if k >= n else k + 1
            if end_of_body is None:
                raise Bail("heredoc without its delimiter line")
            h["end"] = end_of_body
        pending.clear()
        return j

    # mode stack: "code" (frames[-1]) or "dq" (inside "..."); a $( inside "..." pushes code again
    modes = ["code"]
    wstack = []
    while i < n:
        c = s[i]
        if modes[-1] == "dq":
            if c == "\\":
                word.append(s[i:i + 2])
                i += 2
                continue
            if c == '"':
                word.append(c)
                modes.pop()
                i += 1
                continue
            if c == "`":
                raise Bail("backtick in code")
            if s.startswith("$((", i):
                raise Bail("arithmetic")
            if s.startswith("$(", i):
                push("sub", sub_dest())
                i += 2
                continue
            if s.startswith("${", i):
                k = read_balanced(i + 2, "{", "}")
                inner = s[i:k]
                if "$(" in inner or "`" in inner or "<<" in inner or inner.startswith("${!"):
                    raise Bail("command inside ${ }")
                word.append(inner)
                i = k
                continue
            word.append(c)
            i += 1
            continue
        # code
        if c in " \t":
            finish_word()
            i += 1
            continue
        if c == "\\":
            if s.startswith("\\\n", i):
                i += 2
                continue
            word.append(s[i:i + 2])
            i += 2
            continue
        if c == "#" and not word:
            k = s.find("\n", i)
            i = n if k < 0 else k
            continue
        if c == "\n":
            finish_word()
            if redir_next is not None:
                raise Bail("redirection without a target")
            f = frames[-1]
            keep_pipe = f.pipe_from
            end_cmd()
            f.pipe_from = keep_pipe
            i = read_bodies(i + 1)
            continue
        if c == "'":
            k = s.find("'", i + 1)
            if k < 0:
                raise Bail("unbalanced quote")
            word.append(s[i:k + 1])
            i = k + 1
            continue
        if c == '"':
            word.append(c)
            modes.append("dq")
            i += 1
            continue
        if s.startswith("$'", i):
            k = i + 2
            while k < n and s[k] != "'":
                k += 2 if s[k] == "\\" else 1
            if k >= n:
                raise Bail("unbalanced quote")
            word.append(s[i:k + 1])
            i = k + 1
            continue
        if c == "`":
            raise Bail("backtick in code")
        if s.startswith("((", i) or s.startswith("$((", i):
            raise Bail("arithmetic")
        if s.startswith("$(", i):
            push("sub", sub_dest())
            i += 2
            continue
        if s.startswith("${", i):
            k = read_balanced(i + 2, "{", "}")
            inner = s[i:k]
            if "$(" in inner or "`" in inner or "<<" in inner or inner.startswith("${!"):
                raise Bail("command inside ${ }")
            word.append(inner)
            i = k
            continue
        if s.startswith(">(", i):
            raise Bail("output process substitution")
        if s.startswith("<(", i):
            push("psub", "file")
            i += 2
            continue
        if c == "(":
            text = "".join(word)
            if word and ASSIGN.fullmatch(text):
                k = read_balanced(i + 1, "(", ")")
                inner = s[i:k]
                if "$(" in inner or "`" in inner or "<<" in inner:
                    raise Bail("command inside an array literal")
                word.append(inner)
                i = k
                continue
            finish_word()
            f = frames[-1]
            nd = f.node
            if nd is not None and (nd.first is not None or nd.closer):
                raise Bail("function definition or stray (")
            nd = cur()
            for prev in nodes:
                if prev.pipe_to is nd:
                    prev.pipe_to = "GROUP"
            f.opens.append(")")
            f.node = None
            i += 1
            continue
        if c == ")":
            finish_word()
            f = frames[-1]
            if f.opens and f.opens[-1] == ")":
                f.opens.pop()
                f.node = Node(len(nodes), f, True, closer=True)
                nodes.append(f.node)
                i += 1
                continue
            if f.kind in ("sub", "psub") and not f.opens:
                if redir_next is not None:
                    raise Bail("redirection without a target")
                pop()
                i += 1
                continue
            raise Bail("unbalanced )")
        if c in ";&|":
            finish_word()
            if redir_next is not None:
                raise Bail("redirection without a target")
            two = s[i:i + 2]
            if two == ";;" or two == ";&":
                raise Bail("case")
            if two in ("&&", "||"):
                end_cmd()
                i += 2
                continue
            if two == "|&":
                end_cmd(pipe=True)
                i += 2
                continue
            if c == "|":
                end_cmd(pipe=True)
                i += 1
                continue
            if two == "&>":
                pass                                   # a redirection, handled below
            else:
                end_cmd()
                i += 1
                continue
        m = REDIR.match(s, i)
        if m:
            text = "".join(word)
            if text and not text.isdigit():
                finish_word()
            else:
                word = []                              # an fd number belongs to the operator
            if redir_next is not None:
                raise Bail("two redirections in a row")
            op = m.group(1)
            cur()
            i = m.end()
            if op == "<<<":
                redir_next = "in"
            elif op in ("<<", "<<-"):
                redir_next = op
            elif op in (">&", "<&"):
                redir_next = "dup"
            elif op == "<":
                redir_next = "in"
            else:
                redir_next = "out"
            continue
        word.append(c)
        i += 1
    finish_word()
    if len(modes) != 1 or len(frames) != 1 or frames[0].opens or redir_next is not None:
        raise Bail("unterminated construct")
    if pending:
        raise Bail("heredoc header on the last line")
    return nodes, heredocs


def mentions(word: str, name, body: str = "") -> bool:
    kind, val = name
    if kind == "body":
        # a later word whose file name the body spells (a python program or a patch writes that file), or a
        # word whose path the reader cannot resolve: a variable, a substitution, a glob, ~ (xreview r2)
        if "$" in word or "`" in word or any(ch in word for ch in "*?[~"):
            return True
        base = unq(word).rsplit("/", 1)[-1]
        return len(base) >= 3 and re.search(r"[A-Za-z]", base) is not None and base in body
    if kind == "var":
        return ("$" + val) in word or ("${" + val) in word
    w = unq(word)
    if val.startswith("$"):
        return val in word or val.replace("$", "${", 1) in word
    if val in w:
        return True
    base = w.rsplit("/", 1)[-1]
    return any(ch in base for ch in "*?[") and fnmatch.fnmatch(val, base)


def is_sink(nd, program=None) -> bool:
    if nd == "GROUP" or nd.closer:
        return False
    first = nd.first
    if first is None:
        return True                                   # assignments / redirections only: nothing runs
    if PY.fullmatch(first):
        # python reads its PROGRAM from stdin only with no script, -c or -m
        args = [unq(w) for w in nd.words]
        if any(a not in ("-",) and not re.fullmatch(r"-[IuBEsSOqbdv]+", a) for a in args):
            return False
        return program is not None and not SPAWN.search(program)
    if first == "gh" and any(unq(w) in ("alias", "extension", "ext", "config") for w in nd.words):
        return False                                  # gh alias --shell, gh config set pager/editor: run later
    if first == "git" and any(unq(w) in ("config", "-c", "--config-env") or unq(w).startswith(("-c", "--config"))
                              for w in nd.words):
        return False                                  # git alias.x = "!cmd", core.pager, ...: run later (xreview r2)
    return first in SINKS


def runs(nd, nodes, body, seen, program=None) -> bool:
    """Does data reaching nd (stdin, an argument or a named file) get run by something?"""
    if nd == "GROUP":
        return True
    if id(nd) in seen:
        return False
    seen.add(id(nd))
    if not is_sink(nd, program):
        return True
    if nd.unknown_out:
        return True
    names = []
    files = [unq(t) for t in nd.targets]
    if nd.first == "tee":
        files += [unq(w) for w in nd.words if not unq(w).startswith("-")]
    for b in files:
        if b == "/dev/null":
            continue
        if b.startswith("/dev/"):
            if b in ("/dev/stdout", "/dev/stderr", "/dev/fd/1", "/dev/fd/2", "/dev/tty"):
                continue
            return True
        base = b.rsplit("/", 1)[-1] or b
        # a file outlives this command: a later call can run it, so only a data file is data (security review r1)
        if "." not in base or base.rsplit(".", 1)[-1].lower() not in DATA_EXT:
            return True
        names.append(("file", base))
    # file and variable writes that no redirection shows (xreview r1)
    if nd.first == "git" or (nd.first and PY.fullmatch(nd.first)):
        names.append(("body", None))                   # git apply / a python program: files named in the body
    if nd.first is None or nd.first in DECL:
        names += [("var", a) for a in nd.assigns]      # x="$tainted"; export y="$tainted"
    if nd.first == "printf":
        ws = [unq(w) for w in nd.words]
        for k, w in enumerate(ws):
            if w == "-v" and k + 1 < len(ws):
                names.append(("var", ws[k + 1]))
            elif w.startswith("-v") and len(w) > 2:
                names.append(("var", w[2:]))          # printf -vNAME (bash's getopt takes the attached form)
    if nd.first in ("read", "mapfile", "readarray"):
        for w in nd.words:
            b = unq(w)
            if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", b):
                names.append(("var", b))
        if nd.first != "read" and not any(re.fullmatch(r"[A-Za-z_]\w*", unq(w)) for w in nd.words):
            names.append(("var", "MAPFILE"))
        if nd.first == "read" and not any(re.fullmatch(r"[A-Za-z_]\w*", unq(w)) for w in nd.words):
            names.append(("var", "REPLY"))
    # stdout
    if nd.pipe_to is not None:
        if runs(nd.pipe_to, nodes, body, seen, program=body):
            return True
    elif nd.in_group:
        return True                                    # into a group's stdout, which we do not follow
    elif nd.frame.kind == "sub":
        d = nd.frame.dest
        if d == "exec":
            return True
        if isinstance(d, tuple):
            names.append(d)
            if nd.frame.container.first is not None and runs(nd.frame.container, nodes, body, seen):
                return True
        elif runs(nd.frame.container, nodes, body, seen):
            return True
    elif nd.frame.kind == "psub":
        if runs(nd.frame.container, nodes, body, seen, program=body):
            return True
    # a later command that names a file or variable the data landed in
    for name in names:
        for later in nodes:
            if later.idx <= nd.idx or later is nd:
                continue
            if any(mentions(w, name, body) for w in later.mentions + ([later.first] if later.first else [])):
                if runs(later, nodes, body, seen, program=None):
                    return True
    return False


def data_text(s: str) -> str:
    try:
        nodes, heredocs = scan(s)
    except (Bail, RecursionError, IndexError):
        return s
    cuts = []
    for h in heredocs:
        body = s[h["start"]:h["end"]]
        if not body:
            continue
        if not h["quoted"] and ("$(" in body or "`" in body):
            continue
        if runs(h["owner"], nodes, body, set(), program=body):
            continue
        cuts.append((h["start"], h["end"]))
    out, last = [], 0
    for a, b in sorted(cuts):
        out.append(s[last:a])
        last = b
    out.append(s[last:])
    return "".join(out)


if __name__ == "__main__":
    sys.stdout.write(data_text(sys.stdin.read()))
