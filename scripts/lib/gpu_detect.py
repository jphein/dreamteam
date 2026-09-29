"""dreamteam GPU fleet: which cards a Bash command launches GPU work on (the guard's `detect`, v1.3).
Spec: docs/superpowers/specs/2026-09-29-gpu-fleet-design.md §5.1.

A launch is recognised where a shell would RUN it, never where it is merely mentioned:
  - the program word of a simple command, after NAME=value assignments and wrappers (nohup, setsid, env,
    timeout, nice, sudo, flock, systemd-run, systemd-inhibit, safe_run.sh without --protected, ...);
  - inside `bash -c STRING`, an ssh remote command (on that host), `$(...)`, `<(...)`, and a heredoc fed to
    a shell (`ssh gpu1 bash -s <<EOF`);
  - inside a script the same command writes and then runs (`cat > bench.sh <<EOF … bash bench.sh`), or a
    script on this machine that it runs, followed MAX_DEPTH levels (vesper's chain-nh.sh -> gpu1_run.sh ->
    `ssh gpu1 … CUDA_VISIBLE_DEVICES=1 … train.py`, 09-29).
A launcher named as an ARGUMENT (cat, sed, grep, cp, scp), a heredoc written to a file, a commit message or a
quoted string is data, not a launch. Replayed on the 3560 lane commands of 2026-09-29, the v1.2 token scan
flagged 125 would-blocks and 109 of them were reads and edits (dreamteam #106; `dreamteam gpu replay`).

Precision comes first: a false block bricks a lane, while a missed launch still shows on
`dreamteam gpu board` as IN USE, NO CLAIM. So python counts only with GPU evidence: a CUDA_VISIBLE_DEVICES or
ZE_AFFINITY_MASK index, `--device cuda[:N]`, a GPU launcher, torchrun/deepspeed/`accelerate launch`, or a
script named in fleet.json guard.gpu_programs. `CUDA_VISIBLE_DEVICES=` (empty) or `-1`, or `--device cpu`,
marks a job CPU-only. nebula's raster builds on gpu0 are CPU jobs and are not launches.

Pure apart from reading small local scripts: no network, no subprocess. The hook fails open on any error.
"""
import os
import re

MAX_DEPTH = 4                 # local scripts followed: chain.sh -> gpu1_run.sh -> … (the Oracle's 4-deep chain, 09-29)
MAX_SCRIPT_BYTES = 64 * 1024
LAUNCHERS = {"gpu1_launch.sh", "run_exp.sh", "remote_run.sh", "guest_run.sh", "safe_run.sh"}
SHELLS = {"bash", "sh", "dash", "zsh", "ksh"}
PY = re.compile(r"^python[0-9.]*$")
GPU_ENV = ("CUDA_VISIBLE_DEVICES", "ZE_AFFINITY_MASK")
# programs a GPU variable in front of does not make a launch (reads, no-ops)
READS = {"echo", "printf", "true", "false", ":", "test", "[", "nvidia-smi", "export", "cat", "ls", "grep", "head",
         "tail", "env", "printenv", "which", "type", "sleep", "date", "wc", "jq",
         # the Oracle's 09-29 false positives (`CUDA_VISIBLE_DEVICES=1 git status`), and their kin
         "git", "less", "more", "rg", "stat", "ps", "systemctl", "journalctl", "du", "df", "free", "uptime", "id",
         "whoami", "hostname", "file", "readlink", "realpath", "basename", "dirname", "diff", "cmp", "sha256sum",
         "md5sum", "sort", "uniq", "cut", "tr", "sed", "awk", "pgrep", "lsof",
         # file, archive and data utilities, and shell builtins: never a GPU job, and never a "run" a CPU verdict must
         # cover, so a CPU pipeline under --protected (`python build_stacks.py && mv a b && mkdir -p out`) stays CPU
         "cd", "pushd", "popd", "set", "unset", "shift", "exit", "return", "wait", "trap", "umask", "ulimit",
         "alias", "read", "let", "hash", "shopt", "getopts", "break", "continue", "kill", "[[", "]]", "nproc", "seq",
         "mv", "cp", "mkdir", "rm", "rmdir", "ln", "touch", "chmod", "chown", "chgrp", "install", "truncate", "split",
         "tar", "gzip", "gunzip", "zcat", "zstd", "unzstd", "xz", "unxz", "bzip2", "bunzip2", "zip", "unzip", "pigz",
         "sync", "tee", "find", "curl", "wget", "sqlite3", "yq", "pip", "uv",
         "gdalinfo", "gdal_translate", "gdalwarp", "gdalbuildvrt", "gdaladdo", "ogr2ogr", "ogrinfo", "rio", "pdal"}
# python project runners: `uv run CMD` runs CMD (uv's other verbs, `uv pip`/`uv sync`, are no GPU job)
PY_RUNNERS = {"uv": {"--with", "--with-requirements", "--with-editable", "--python", "-p", "--project", "--directory",
                     "--env-file", "--extra", "--group", "--package", "--index", "--index-url", "--default-index"},
              "poetry": set(), "pdm": set(), "hatch": set(), "pipx": {"--spec", "--python"},
              "conda": {"-n", "--name", "-p", "--prefix", "--cwd"}, "mamba": {"-n", "--name", "-p", "--prefix"},
              "micromamba": {"-n", "--name", "-p", "--prefix"}}


def _runner_rest(words: list):
    """The command a `uv run` / `conda run -n env` / `poetry run` runs, or None when it is not a run."""
    vals = PY_RUNNERS.get(os.path.basename(words[0]))
    if vals is None or words[1:2] != ["run"]:
        return None
    rest = words[2:]
    while rest and rest[0].startswith("-") and rest[0] != "-":
        if rest[0] == "--":
            return rest[1:]
        rest = rest[2:] if (rest[0] in vals and "=" not in rest[0]) else rest[1:]
    return rest


# tmux subcommands that run a shell command, and the flags that take a value in each
TMUX_RUNNERS = {"new-session": "cefFnstxy", "new": "cefFnstxy", "new-window": "ceFnt", "neww": "ceFnt",
                "split-window": "ceFlpt", "splitw": "ceFlpt", "respawn-pane": "cet", "respawnp": "cet",
                "respawn-window": "cet", "respawnw": "cet", "run-shell": "dt", "run": "dt",
                "display-popup": "bcdehsStTwxy", "popup": "bcdehsStTwxy"}
TMUX_KEYS = {"Enter", "C-m", "C-j", "KPEnter", "Escape", "C-c", "C-d", "C-u", "C-l", "Tab", "BSpace", "Space", "Up",
             "Down", "Left", "Right"}
TORCH_MODULES = re.compile(r"^(torch\.distributed\.(run|launch)|accelerate\.commands\.launch|deepspeed(\.launcher\.runner)?)$")
DEFAULT_GPU_PROGRAMS = [r"^stage2_train.*\.py$", r"^dino_features.*\.py$", r"^train\.py$", r"^(finetune|fine_tune).*\.py$"]
SSH_OPTS_WITH_ARG = set("-B -b -c -D -E -e -F -I -i -J -L -l -m -O -o -p -Q -R -S -W -w".split())
NAME_ASSIGN = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.S)
SUB = "\x00"                  # placeholder for a command substitution inside a word
ARRAY_HEAD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\])?\+?=")   # arr=( … ), arr+=( … ), declare -a Q=( … )

# wrapper -> (flags, options taking a value, positionals to skip after the options)
WRAPPERS = {
    "nohup": (set(), set(), 0),
    "setsid": ({"-f", "-w", "-c", "--fork", "--wait", "--ctty"}, set(), 0),
    "exec": ({"-c", "-l"}, {"-a"}, 0),
    "time": ({"-p", "-v", "-a", "-q", "--verbose", "--portability", "--append", "--quiet"}, {"-f", "-o", "--format", "--output"}, 0),
    "nice": (set(), {"-n", "--adjustment"}, 0),
    "ionice": ({"-t", "--ignore"}, {"-c", "-n", "--class", "--classdata"}, 0),
    "stdbuf": (set(), {"-i", "-o", "-e", "--input", "--output", "--error"}, 0),
    "chrt": ({"-a", "-b", "-d", "-f", "-i", "-o", "-r", "-R", "-v", "--all-tasks", "--batch", "--fifo", "--idle",
              "--other", "--rr", "--reset-on-fork", "--verbose"}, {"-T", "-P", "-D"}, 1),
    "timeout": ({"--foreground", "--preserve-status", "-v", "--verbose"}, {"-s", "-k", "--signal", "--kill-after"}, 1),
    "sudo": ({"-A", "-b", "-E", "-e", "-H", "-i", "-K", "-k", "-n", "-P", "-S", "-s", "--preserve-env",
              "--non-interactive", "--login", "--shell", "--background", "--set-home"},
             {"-C", "-D", "-g", "-h", "-p", "-R", "-r", "-T", "-t", "-U", "-u", "--user", "--group", "--chdir",
              "--prompt", "--close-from", "--host", "--role", "--type", "--command-timeout", "--other-user"}, 0),
    "systemd-inhibit": ({"--no-pager", "--no-legend"}, {"--what", "--who", "--why", "--mode"}, 0),
    "systemd-run": ({"--scope", "--user", "--system", "--wait", "--pipe", "--pty", "-t", "-P", "-q", "--quiet",
                     "--collect", "-G", "--same-dir", "-d", "--no-block", "--no-ask-password", "-r",
                     "--remain-after-exit", "-S", "--shell", "--send-sighup"},
                    {"-p", "--property", "-u", "--unit", "--uid", "--gid", "-M", "--machine", "--slice",
                     "--description", "-E", "--setenv", "--working-directory", "-H", "--host", "--nice",
                     "--service-type", "--on-active", "--on-boot", "--on-startup", "--on-unit-active",
                     "--on-unit-inactive", "--on-calendar", "--timer-property", "--path-property",
                     "--socket-property"}, 0),
    "queue_after.sh": (set(), set(), 2),     # GEMS: queue_after.sh WAIT_FILE WAIT_PATTERN CMD… (it execs CMD)
    "watch": ({"-t", "-b", "-e", "-g", "-c", "-x", "-d", "-p", "-r", "-w", "--no-title", "--beep", "--errexit",
               "--chgexit", "--color", "--exec", "--differences", "--precise", "--no-rerun", "--no-wrap"},
              {"-n", "--interval", "-q", "--equexit"}, 0),
}
DOCKER_VALUE_OPTS = set("""-a -c -e -h -l -m -p -u -v -w --add-host --annotation --attach --blkio-weight --cgroup-parent
--cgroupns --cidfile --cpu-period --cpu-quota --cpu-shares --cpus --cpuset-cpus --cpuset-mems --device
--device-cgroup-rule --dns --dns-option --dns-search --domainname --entrypoint --env --env-file --expose --gpus
--group-add --health-cmd --health-interval --health-retries --health-start-period --health-timeout --hostname --ip
--ip6 --ipc --isolation --kernel-memory --label --label-file --link --log-driver --log-opt --mac-address --memory
--memory-reservation --memory-swap --memory-swappiness --mount --name --network --network-alias --pid --pids-limit
--platform --publish --pull --restart --runtime --security-opt --shm-size --stop-signal --stop-timeout
--storage-opt --sysctl --tmpfs --ulimit --user --userns --uts --volume --volume-driver --volumes-from
--workdir""".split())
RESERVED_HEADERS = {"for", "case", "select", "function"}      # the rest of this simple command is a header
RESERVED_STRIP = {"!", "{", "}", "do", "then", "else", "elif", "if", "while", "until", "done", "fi", "esac", "coproc"}


# ── lexing ────────────────────────────────────────────────────────────────────────────────────────

def _balanced(s: str, i: int, open_c: str, close_c: str):
    """s[i] is just past an opener; return (inner text, index past the closer). Quotes are honoured."""
    depth, j, n = 1, i, len(s)
    while j < n:
        c = s[j]
        if c == "\\":
            j += 2
            continue
        if c == "'":
            k = s.find("'", j + 1)
            j = n if k < 0 else k + 1
            continue
        if c == '"':
            j += 1
            while j < n and s[j] != '"':
                j += 2 if s[j] == "\\" else 1
            j += 1
            continue
        if c == open_c:
            depth += 1
        elif c == close_c:
            depth -= 1
            if depth == 0:
                return s[i:j], j + 1
        j += 1
    return s[i:], n


def _word(s: str, i: int, subs: list):
    """One shell word from s[i]. Returns (text, next index). Quotes and escapes are removed; `$(…)`, backticks
    and `<(…)` are recorded in subs (they run) and leave a placeholder in the text."""
    out, n = [], len(s)
    while i < n:
        c = s[i]
        if c in " \t\n;&|()<>":
            if c == "(" and ARRAY_HEAD.fullmatch("".join(out)):
                inner, i = _balanced(s, i + 1, "(", ")")    # an array literal is one word: data, not a command
                out.append("(" + inner + ")")
                continue
            if c in "<>" and i + 1 < n and s[i + 1] == "(" and not out:
                inner, i = _balanced(s, i + 2, "(", ")")
                subs.append(inner)
                out.append(SUB)
                continue
            break
        if c == "\\":
            if i + 1 < n and s[i + 1] == "\n":
                i += 2
                continue
            out.append(s[i + 1:i + 2])
            i += 2
            continue
        if c == "'":
            k = s.find("'", i + 1)
            k = n if k < 0 else k
            out.append(s[i + 1:k])
            i = k + 1
            continue
        if c == "$" and s.startswith("$'", i):
            k = i + 2
            buf = []
            while k < n and s[k] != "'":
                if s[k] == "\\" and k + 1 < n:
                    buf.append({"n": "\n", "t": "\t", "'": "'", "\\": "\\"}.get(s[k + 1], s[k + 1]))
                    k += 2
                    continue
                buf.append(s[k])
                k += 1
            out.append("".join(buf))
            i = k + 1
            continue
        if c == '"':
            i += 1
            while i < n and s[i] != '"':
                if s[i] == "\\" and i + 1 < n and s[i + 1] in '"\\$`\n':
                    if s[i + 1] != "\n":
                        out.append(s[i + 1])
                    i += 2
                    continue
                if s.startswith("$((", i):
                    inner, i = _balanced(s, i + 3, "(", ")")
                    out.append("$((" + inner + ")")
                    continue
                if s.startswith("$(", i):
                    inner, i = _balanced(s, i + 2, "(", ")")
                    subs.append(inner)
                    out.append(SUB)
                    continue
                if s[i] == "`":
                    k = s.find("`", i + 1)
                    k = n if k < 0 else k
                    subs.append(s[i + 1:k])
                    out.append(SUB)
                    i = k + 1
                    continue
                out.append(s[i])
                i += 1
            i += 1
            continue
        if s.startswith("$((", i):
            inner, i = _balanced(s, i + 3, "(", ")")
            out.append("$((" + inner + ")")
            continue
        if s.startswith("$(", i):
            inner, i = _balanced(s, i + 2, "(", ")")
            subs.append(inner)
            out.append(SUB)
            continue
        if s.startswith("${", i):
            inner, i = _balanced(s, i + 2, "{", "}")
            out.append("${" + inner + "}")
            continue
        if c == "`":
            k = s.find("`", i + 1)
            k = n if k < 0 else k
            subs.append(s[i + 1:k])
            out.append(SUB)
            i = k + 1
            continue
        out.append(c)
        i += 1
    return "".join(out), i


_REDIR = re.compile(r"(\d*|&)(<<<|<<-|<<|<>|>>|>&|<&|>\||>|<)")


def _lex(s: str):
    """Split a command string into simple commands. Each is a dict: words, redirs [(op, target)], heredocs
    [body], bg (ended by `&`). Also returns the command substitutions found (they run too). Lenient."""
    subs, cmds = [], []
    cur = {"words": [], "redirs": [], "heredocs": [], "bg": False}
    pending = []                         # (delimiter, strip_tabs, cmd) waiting for the end of the line
    i, n = 0, len(s)

    def flush(bg=False):
        nonlocal cur
        if cur["words"] or cur["redirs"] or cur["heredocs"]:
            cur["bg"] = bg
            cmds.append(cur)
        cur = {"words": [], "redirs": [], "heredocs": [], "bg": False}

    while i < n:
        c = s[i]
        if c in " \t":
            i += 1
            continue
        if c == "\\" and i + 1 < n and s[i + 1] == "\n":
            i += 2
            continue
        if c == "#" and not cur["words"]:
            k = s.find("\n", i)
            i = n if k < 0 else k
            continue
        if c == "\n":
            flush()
            i += 1
            for delim, strip, owner in pending:            # heredoc bodies start on the next line
                lines, k = [], i
                while k < n:
                    e = s.find("\n", k)
                    line = s[k:] if e < 0 else s[k:e]
                    k = n if e < 0 else e + 1
                    if (line.lstrip("\t") if strip else line) == delim:
                        break
                    lines.append(line)
                owner["heredocs"].append("\n".join(lines))
                i = k
            pending = []
            continue
        if s.startswith("&&", i) or s.startswith("||", i) or s.startswith(";;", i) or s.startswith("|&", i):
            flush()
            i += 2
            continue
        m = _REDIR.match(s, i)
        if m:
            op = m.group(2)
            i = m.end()
            if op in ("<", ">") and i < n and s[i] == "(" and not m.group(1):   # process substitution
                inner, i = _balanced(s, i + 1, "(", ")")
                subs.append(inner)
                cur["words"].append(SUB)
                continue
            while i < n and s[i] in " \t":
                i += 1
            target, i = _word(s, i, subs)
            if op in ("<<", "<<-"):
                pending.append((target, op == "<<-", cur))
            elif op == "<<<":
                cur["heredocs"].append(target)             # a here-string feeds stdin like a heredoc
            else:
                cur["redirs"].append((op, target))
            continue
        if c in ";&|()":
            flush(bg=(c == "&"))
            i += 1
            continue
        w, i = _word(s, i, subs)
        cur["words"].append(w)
    flush()
    return cmds, subs


# ── scanning ──────────────────────────────────────────────────────────────────────────────────────

class _Scan:
    def __init__(self, fleet: dict, local: str):
        self.fleet, self.local = fleet, local
        g = fleet.get("guard") or {}
        self.gpu_programs = _patterns(g.get("gpu_programs") or DEFAULT_GPU_PROGRAMS)
        self.gpu_scripts = _patterns(g.get("gpu_scripts") or [])
        self.cpu_programs = [rx for rx, _ in _patterns(g.get("cpu_programs") or [])]
        self.finds = []          # (host, [idx] | None, prefix, why, all_cards)
        self.via_run = False
        self.copied = {}         # host -> {basename: text}: local scripts this command scp'd there
        self.cpu_verdicts = 0    # commands judged CPU-only (a CPU program, a CPU marker, --device cpu)
        self.runs = 0            # leaf programs run (python, an unread script, a binary): what a verdict must cover

    def find(self, host, env: dict, why: str, idx=None, prefix="", all_cards=False, kind=None):
        """kind None: the environment names the device (CUDA_VISIBLE_DEVICES or ZE_AFFINITY_MASK). kind "cuda" or
        "xpu": a program of that kind, indexed only by its own variable (a CUDA index does not move an XPU job)."""
        if idx is None:
            gidx, gprefix = gpu_index(env, kind)
            if gidx == "cpu":
                self.cpu_verdicts += 1
                return
            idx = gidx
            prefix = gprefix if kind is None else ("xpu" if kind == "xpu" else "")
        self.finds.append((host, idx, prefix, why, all_cards))


def _patterns(items: list) -> list:
    """[(regex, kind)] from strings (CUDA) or {"match": regex, "kind": "cuda" | "xpu"}."""
    out = []
    for it in items:
        rx, kind = (it, "cuda") if isinstance(it, str) else (it.get("match", "^$"), it.get("kind", "cuda"))
        out.append((re.compile(rx, re.I), kind))
    return out


def gpu_index(env: dict, kind=None):
    """(indices | None | "cpu", prefix) from CUDA_VISIBLE_DEVICES / ZE_AFFINITY_MASK in env. None = set to
    something that is not a literal index (a variable): some card of the host. "cpu" = the CPU-only marker.
    With a kind, only that kind's variable counts."""
    keys = GPU_ENV if kind is None else (("ZE_AFFINITY_MASK",) if kind == "xpu" else ("CUDA_VISIBLE_DEVICES",))
    cpu = None
    for k in keys:                           # a variable naming a device beats another's CPU marker (the Oracle, 09-29)
        if k in env:
            v = env[k].strip().strip("'\"")
            prefix = "xpu" if k == "ZE_AFFINITY_MASK" else ""
            if v in ("", "-1"):
                cpu = cpu or ("cpu", prefix)
                continue
            if re.fullmatch(r"[0-9]+(,[0-9]+)*", v):
                return [int(x) for x in v.split(",")], prefix
            return None, prefix
    return cpu or (None, "")


def _has_gpu_env(env: dict) -> bool:
    return any(k in env for k in GPU_ENV)


def _host_alias(tok: str, fleet: dict):
    h = tok.split("@", 1)[-1].lower()
    for suffix in (".lan", ".jphe.in", ".realm.watch"):
        if h.endswith(suffix):
            h = h[: -len(suffix)]
    return h if h in fleet["hosts"] else None


def _skip_opts(args: list, flags: set, vals: set, positional: int, env: dict, name: str):
    """Drop a wrapper's options (and its positionals); systemd-run -E/--setenv NAME=V goes into env."""
    while args and args[0].startswith("-") and args[0] != "-":
        a = args[0]
        if a == "--":
            args = args[1:]
            break
        if a.startswith("--") and "=" in a:
            if a.startswith("--setenv="):
                m = NAME_ASSIGN.match(a[len("--setenv="):])
                if m:
                    env[m.group(1)] = m.group(2)
            args = args[1:]
            continue
        if a in vals:
            if a in ("-E", "--setenv") and name == "systemd-run" and len(args) > 1:
                m = NAME_ASSIGN.match(args[1])
                if m:
                    env[m.group(1)] = m.group(2)
            args = args[2:]
            continue
        args = args[1:]                  # a flag (or an attached value such as -n19, -oL, -p22)
    return args[positional:]


def _expand_var(w: str, shvars: dict) -> str:
    """A word that is exactly $var or ${var} becomes the value this command gave var (c='…'; bash -c "$c")."""
    m = re.fullmatch(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?", w)
    return shvars[m.group(1)] if m and m.group(1) in shvars else w


def _unescape(t: str) -> str:
    return t.replace("\\n", "\n").replace("\\t", "\t").replace("\\'", "'").replace('\\"', '"').replace("\\\\", "\\")


def _local_real(path_word: str, cwd: str):
    """The real path of a local file a command names (a symlinked or renamed launcher), or None."""
    if SUB in path_word or "$" in path_word:
        return None
    p = os.path.normpath(os.path.join(cwd, os.path.expanduser(path_word)))
    try:
        return os.path.realpath(p) if os.path.isfile(p) else None
    except OSError:
        return None


def _expand_head(w: str, shvars: dict) -> str:
    m = re.fullmatch(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?", w) or re.match(r"^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?(/.*)$", w)
    if m and m.group(1) in shvars:
        return shvars[m.group(1)] + (m.group(2) if m.lastindex and m.lastindex >= 2 else "")
    return w


def _scan(cmd: str, st: _Scan, host, env: dict, cwd: str, depth: int, written: dict, stdin=None):
    try:
        cmds, subs = _lex(cmd)
    except (IndexError, ValueError, RecursionError):
        return
    shvars, env = {}, dict(env)
    for sc in cmds:
        _simple(sc, st, host, env, shvars, cwd, depth, written)
        w = sc["words"]
        if len(w) == 2 and w[0] == "cd" and host == st.local:
            cwd = os.path.normpath(os.path.join(cwd, os.path.expanduser(w[1])))
    for sub in subs:
        _scan(sub, st, host, env, cwd, depth, written)


def _run_script(path_word: str, st: _Scan, host, env: dict, cwd: str, depth: int, written: dict) -> bool:
    """A script the command runs: one it wrote itself, or a local file. Returns True when it was followed."""
    base = os.path.basename(path_word)
    if depth >= MAX_DEPTH:                  # also bounds a script that runs itself (cat > a.sh <<EOF … bash a.sh)
        return False
    if base in written:
        _scan(written[base], st, host, env, cwd, depth + 1, written)
        return True
    if host != st.local or SUB in path_word or "$" in path_word:
        return False
    p = os.path.normpath(os.path.join(cwd, os.path.expanduser(path_word)))
    try:
        if os.path.isfile(p) and os.path.getsize(p) <= MAX_SCRIPT_BYTES:
            with open(p, errors="replace") as f:
                text = f.read()
            if "\x00" in text:
                return False
            _scan(text, st, host, env, os.path.dirname(p), depth + 1, written)
            return True
    except OSError:
        pass
    return False


def _simple(sc: dict, st: _Scan, host, env: dict, shvars: dict, cwd: str, depth: int, written: dict):
    words = list(sc["words"])
    while words and words[0] in RESERVED_STRIP:
        words = words[1:]
    if not words or words[0] in RESERVED_HEADERS:
        return
    # a heredoc written to a file: remembered, in case this command runs it later (cat > bench.sh <<EOF … bash bench.sh)
    if sc["heredocs"]:
        for op, target in sc["redirs"]:
            if op in (">", ">>", ">|"):
                b = os.path.basename(target)
                written[b] = (written.get(b, "") + "\n" if op == ">>" else "") + "\n".join(sc["heredocs"])
        if os.path.basename(words[0]) == "tee":
            for t in words[1:]:
                if not t.startswith("-"):
                    written[os.path.basename(t)] = "\n".join(sc["heredocs"])
    assigns = {}
    while words and NAME_ASSIGN.match(words[0]):
        m = NAME_ASSIGN.match(words[0])
        assigns[m.group(1)] = m.group(2)
        words = words[1:]
    if not words:                      # NAME=value alone: a shell variable (not exported)
        shvars.update(assigns)
        return
    cenv = dict(env)
    cenv.update(assigns)
    words[0] = _expand_head(words[0], shvars)
    # wrappers
    for _ in range(12):
        prog = os.path.basename(words[0])
        if prog == "env":
            args = words[1:]
            while args and args[0].startswith("-") and args[0] != "-":
                a = args[0]
                if a == "--":
                    args = args[1:]
                    break
                if a in ("-u", "--unset", "-C", "--chdir"):
                    args = args[2:]
                    continue
                if a in ("-S", "--split-string") and len(args) > 1:
                    args = args[1].split() + args[2:]
                    continue
                args = args[1:]
            while args and NAME_ASSIGN.match(args[0]):
                m = NAME_ASSIGN.match(args[0])
                cenv[m.group(1)] = m.group(2)
                args = args[1:]
            words = args
        elif prog in WRAPPERS:
            flags, vals, pos = WRAPPERS[prog]
            words = _skip_opts(words[1:], flags, vals, pos, cenv, prog)
        elif prog == "flock":
            args = _skip_opts(words[1:], {"-s", "-x", "-u", "-n", "-o", "-F", "--shared", "--exclusive", "--unlock",
                                          "--nonblock", "--close", "--verbose", "--no-fork"},
                              {"-w", "--timeout", "-E", "--conflict-exit-code"}, 1, cenv, prog)
            if args[:1] in (["-c"], ["--command"]) and len(args) > 1:
                _scan(args[1], st, host, cenv, cwd, depth, written)
                return
            words = args
        elif _runner_rest(words) is not None:   # uv run / poetry run / conda run -n env …: a wrapper
            words = _runner_rest(words)
        elif prog == "command":            # `command X` runs X; `command -v X` only looks it up
            args = words[1:]
            if args and args[0].startswith("-") and any(ch in "vV" for ch in args[0][1:]):
                return
            while args and args[0].startswith("-") and args[0] != "-":
                args = args[1:]
            words = args
        elif prog == "taskset":
            args = words[1:]
            if args[:1] in (["-p"], ["--pid"]):
                return
            args = _skip_opts(args, {"-a", "--all-tasks"}, {"-c", "--cpu-list"}, 0, cenv, prog)
            if words[1:2] not in (["-c"], ["--cpu-list"]) and args:
                args = args[1:]            # the mask
            words = args
        elif prog == "safe_run.sh" and "--protected" not in words[1:4]:
            # familiar's capped scope: `safe_run.sh CAP CMD…`; the capped command decides
            args = [a for a in words[1:] if a != "--"]
            words = args[1:] if args else []
        else:
            break
        if not words:
            return
        while words and NAME_ASSIGN.match(words[0]) and prog in ("nohup", "setsid", "sudo", "time", "exec"):
            m = NAME_ASSIGN.match(words[0])
            cenv[m.group(1)] = m.group(2)
            words = words[1:]
        if not words:
            return
        words[0] = _expand_head(words[0], shvars)
    if not words:
        return
    prog = os.path.basename(words[0])
    args = words[1:]
    # printf/echo writing a script, remembered like a heredoc (the Oracle: printf '…' > run.sh && bash run.sh)
    if prog in ("printf", "echo") and any(op in (">", ">>", ">|") for op, _ in sc["redirs"]):
        if prog == "echo":
            text = " ".join(a for a in args if a not in ("-e", "-n", "-E"))
            text = _unescape(text) if "-e" in args else text
        else:
            rest = list(args[1:])
            text = re.sub(r"%[sb]", lambda m: rest.pop(0) if rest else "", _unescape(args[0] if args else ""))
        for op, target in sc["redirs"]:
            if op in (">", ">>", ">|"):
                b = os.path.basename(target)
                written[b] = (written.get(b, "") + "\n" if op == ">>" else "") + text
    # a launcher under another name: a symlink, or a copy made executable (judged by what it points to)
    if prog not in LAUNCHERS and host == st.local and "/" in words[0]:
        rp = _local_real(words[0], cwd)
        if rp and os.path.basename(rp) in LAUNCHERS:
            prog = os.path.basename(rp)

    if prog == "tmux":
        _tmux(args, st, host, cenv, shvars, cwd, depth, written)
        return
    if prog == "screen":
        _screen(args, st, host, cenv, shvars, cwd, depth, written)
        return
    if prog == "su":
        for k, a in enumerate(args):
            code = a.split("=", 1)[1] if a.startswith("--command=") else (args[k + 1] if a in ("-c", "--command") and k + 1 < len(args) else None)
            if code is not None:
                _scan(_expand_var(code, shvars), st, host, cenv, cwd, depth, written)
                break
        return
    if prog == "xargs":
        rest = _skip_opts(args, {"-0", "-o", "-p", "-r", "-t", "-x", "--null", "--interactive", "--no-run-if-empty",
                                 "--verbose", "--exit", "--open-tty"},
                          {"-a", "-d", "-E", "-I", "-L", "-n", "-P", "-s", "--arg-file", "--delimiter", "--eof",
                           "--replace", "--max-lines", "--max-args", "--max-procs", "--max-chars",
                           "--process-slot-var"}, 0, cenv, prog)
        if rest:
            _simple({"words": rest, "redirs": [], "heredocs": [], "bg": sc["bg"]}, st, host, cenv, shvars, cwd,
                    depth, written)
        return
    if prog == "eval":
        _scan(" ".join(_expand_var(a, shvars) for a in args), st, host, cenv, cwd, depth, written)
        return

    if prog == "export":
        for a in args:
            m = NAME_ASSIGN.match(a)
            if m:
                env[m.group(1)] = m.group(2)
                shvars[m.group(1)] = m.group(2)   # export c='…'; bash -c "$c" (the Oracle, 09-29)
            elif a in shvars:
                env[a] = shvars[a]
        return
    if prog in ("declare", "typeset", "local", "readonly"):
        exported = any(a.startswith("-") and "x" in a[1:] for a in args)
        for a in args:
            m = NAME_ASSIGN.match(a)
            if m:
                shvars[m.group(1)] = m.group(2)
                if exported:
                    env[m.group(1)] = m.group(2)
        return
    if prog in ("dreamteam", "gpu.sh") and args[:1] in (["gpu"], ["run"]):
        if (prog == "dreamteam" and args[1:2] == ["run"]) or (prog == "gpu.sh" and args[:1] == ["run"]):
            st.via_run = True          # checked inside `gpu run` itself
        return
    if prog in ("ssh", "autossh"):
        _ssh(args, sc, st, host, cenv, cwd, depth, written)
        return
    if prog in ("scp", "rsync", "sftp"):
        _copied(args, st, cwd, written)    # a script copied to a host, then run there, is followed (drift, 09-29)
        return
    if prog in SHELLS:
        _shell(args, sc, st, host, cenv, cwd, depth, written, shvars)
        return
    if prog in ("source", "."):
        if args:
            _run_script(args[0], st, host, cenv, cwd, depth, written)
        return
    if prog in LAUNCHERS:
        if prog == "safe_run.sh" and not any(a in ("-h", "--help", "--version") for a in args[:3]):
            rest = [a for a in args if a not in ("--protected", "--")]
            n0, c0, r0 = len(st.finds), st.cpu_verdicts, st.runs
            if len(rest) > 1:              # the capped command first: it may name the card and its kind
                _simple({"words": rest[1:], "redirs": [], "heredocs": [], "bg": False}, st, host, cenv, shvars,
                        cwd, depth, written)
            if len(st.finds) > n0:
                return                     # it named its card
            ran = st.runs - r0
            if ran and st.cpu_verdicts - c0 >= ran:
                return                     # EVERY program it runs was judged CPU: no training run (the Oracle's FIX);
                                           # one unjudged program keeps the fallback (no CPU decoy hides a GPU job)
        _launcher(prog, args, st, host, cenv)
        return
    if PY.match(prog):
        _python(args, sc, st, host, cenv)
        return
    if prog in ("torchrun", "deepspeed") or (prog == "accelerate" and args[:1] == ["launch"]):
        st.find(host, cenv, prog if prog != "accelerate" else "accelerate launch")
        return
    if prog == "ollama" and args[:1] == ["run"]:
        st.find(host, cenv, "ollama run")
        return
    if prog in ("docker", "podman"):
        _docker(args, st, host, cenv)
        return
    is_script = "/" in words[0] or prog.endswith(".sh")
    if is_script and _run_script(words[0], st, host, cenv, cwd, depth, written):
        return                             # followed: its own commands decide, under this env
    if is_script and _named_gpu_script(prog, args, st, host, cenv):
        return
    if prog in READS:
        return
    st.runs += 1                           # a leaf program: a binary, or a script that could not be read
    explicit = any(k in cenv and env.get(k) != cenv[k] for k in GPU_ENV)
    if explicit or (is_script and _has_gpu_env(cenv)):
        st.find(host, cenv, _env_why(cenv))


def _named_gpu_script(base: str, args: list, st: _Scan, host, env: dict) -> bool:
    """fleet.json guard.gpu_scripts: a GEMS wrapper that launches a GPU child (chain45.sh, queue_*_seeds.sh), used
    when its text cannot be read, e.g. run on gpu0 over ssh (morpheus-gems, 09-29)."""
    for rx, kind in st.gpu_scripts:
        if rx.search(base):
            _launch_find(st, host, env, f"{base} (a GPU script)", args, kind)
            return True
    if _device_in(args)[0] in ("cuda", "xpu"):   # an unread script told which device to use
        _launch_find(st, host, env, f"{base} --device {_device_in(args)[0]}", args)
        return True
    return False


def _env_why(env: dict) -> str:
    """The variable that names the device (an index beats another variable's CPU marker), for the why line."""
    named = [k for k in GPU_ENV if k in env and env[k].strip().strip("'\"") not in ("", "-1")]
    for k in named or [k for k in GPU_ENV if k in env]:
        return f"{k}={env[k]}"
    return "a GPU variable"


def _copied(args: list, st: _Scan, cwd: str, written: dict):
    """`scp a.sh b.sh gpu0:/dir/`: remember the local files' text for gpu0, so `ssh gpu0 bash /dir/a.sh` is read.
    A file this same command writes by heredoc wins over the disk: the hook runs BEFORE the command, when the
    file is missing or stale (reverie's g1c1_idea18.sh, 09-29: written, scp'd and run in one call)."""
    files = [a for a in args if not a.startswith("-")]
    if len(files) < 2 or ":" not in files[-1]:
        return
    rhost = _host_alias(files[-1].split(":", 1)[0], st.fleet)
    if rhost is None:
        return
    for src in files[:-1]:
        if ":" in src or "*" in src or "$" in src or SUB in src:
            continue
        if os.path.basename(src) in written:
            st.copied.setdefault(rhost, {})[os.path.basename(src)] = written[os.path.basename(src)]
            continue
        p = os.path.normpath(os.path.join(cwd, os.path.expanduser(src)))
        try:
            if os.path.isfile(p) and os.path.getsize(p) <= MAX_SCRIPT_BYTES:
                with open(p, errors="replace") as f:
                    st.copied.setdefault(rhost, {})[os.path.basename(p)] = f.read()
        except OSError:
            pass


def _ssh(args: list, sc: dict, st: _Scan, host, env: dict, cwd: str, depth: int, written: dict):
    j = 0
    while j < len(args) and args[j].startswith("-"):
        a = args[j]
        j += 2 if (a in SSH_OPTS_WITH_ARG) else 1
    if j >= len(args):
        return
    target = args[j]
    rhost = _host_alias(target, st.fleet)
    rest = args[j + 1:]
    if rest[:1] == ["--"]:
        rest = rest[1:]
    renv = {}                              # a local variable does not cross ssh (no SendEnv here)
    remote = " ".join(rest)
    sub = _Scan(st.fleet, st.local)
    sub.gpu_programs = st.gpu_programs
    known = dict(st.copied.get(rhost, {})) if rhost else {}
    if remote.strip():
        _scan(remote, sub, rhost, renv, "/", depth, known)
        first = rest[0] if rest else ""
        if os.path.basename(first) in SHELLS and "-c" not in rest[1:3]:
            for body in sc["heredocs"]:
                _scan(body, sub, rhost, renv, "/", depth, known)
    else:
        for body in sc["heredocs"]:        # `ssh host <<EOF`: the remote login shell reads the body
            _scan(body, sub, rhost, renv, "/", depth, known)
    if rhost is None:
        for f in sub.finds:
            st.finds.append((None, f[1], f[2], f[3], f[4]))
    else:
        st.finds.extend(sub.finds)
    st.via_run = st.via_run or sub.via_run


def _shell(args: list, sc: dict, st: _Scan, host, env: dict, cwd: str, depth: int, written: dict, shvars=None):
    """bash/sh: -c STRING, a script, or commands on stdin (-s or a heredoc). -n only checks syntax."""
    cmode, j = False, 0
    while j < len(args) and (args[j].startswith("-") or args[j].startswith("+")) and args[j] not in ("-", "--"):
        a = args[j]
        if a in ("--rcfile", "--init-file"):
            j += 2
            continue
        if a.startswith("--"):
            j += 1
            continue
        if "n" in a[1:] and a.startswith("-"):
            return                          # bash -n: a syntax check runs nothing
        if "c" in a[1:]:
            cmode = True
        j += 2 if "o" in a[1:] else 1
    if j < len(args) and args[j] == "--":
        j += 1
    if cmode:
        if j < len(args):
            _scan(_expand_var(args[j], shvars or {}), st, host, env, cwd, depth, written)
        return
    if j < len(args) and args[j] != "-":
        base = os.path.basename(args[j])
        if host == st.local and base not in LAUNCHERS:
            rp = _local_real(args[j], cwd)
            base = os.path.basename(rp) if rp and os.path.basename(rp) in LAUNCHERS else base
        if base in LAUNCHERS or base in WRAPPERS:   # `bash X args` is `X args`: its fixed semantics, not its source
            _simple({"words": [base] + args[j + 1:], "redirs": [], "heredocs": sc["heredocs"], "bg": sc["bg"]}, st,
                    host, env, {}, cwd, depth, written)
        elif not _run_script(args[j], st, host, env, cwd, depth, written) and not _named_gpu_script(base, args[j + 1:], st, host, env):
            st.runs += 1                   # an unread script: opaque
            if _has_gpu_env(env):
                st.find(host, env, _env_why(env))
        return
    for body in sc["heredocs"]:
        _scan(body, st, host, env, cwd, depth, written)


def _tmux(args: list, st: _Scan, host, env: dict, shvars: dict, cwd: str, depth: int, written: dict):
    """tmux runs shell commands: new-session/new-window/split-window/respawn/run-shell/popup take one as their last
    words, and send-keys types one (the fleet's own runner; the Oracle, 09-29). Other subcommands are reads."""
    j = 0
    while j < len(args) and args[j].startswith("-"):                 # tmux's own options: -L -S -f -c -T take a value
        a = args[j]
        if a == "-c" and j + 1 < len(args):                            # `tmux -c CMD` runs CMD in the default shell
            _scan(_expand_var(args[j + 1], shvars), st, host, env, cwd, depth, written)
            return
        j += 2 if a in ("-L", "-S", "-f", "-T") else 1
    if j >= len(args):
        return
    sub, rest = args[j], args[j + 1:]
    tenv = dict(env)
    if sub in TMUX_RUNNERS:
        vals, k = TMUX_RUNNERS[sub], 0
        while k < len(rest) and rest[k].startswith("-") and rest[k] != "-":
            a = rest[k]
            if a == "--":
                k += 1
                break
            for i, ch in enumerate(a[1:]):
                if ch in vals:
                    val = a[i + 2:] if i + 2 < len(a) else (rest[k + 1] if k + 1 < len(rest) else "")
                    if ch == "e":
                        m = NAME_ASSIGN.match(val)
                        if m:
                            tenv[m.group(1)] = m.group(2)
                    k += 0 if i + 2 < len(a) else 1
                    break
            k += 1
        cmd = " ".join(_expand_var(a, shvars) for a in rest[k:])
        if cmd.strip():
            _scan(cmd, st, host, tenv, cwd, depth, written)
    elif sub in ("if-shell", "if"):           # if-shell [-bF] [-t target] SHELL-COMMAND tmux-command …
        k = 0
        while k < len(rest) and rest[k].startswith("-") and rest[k] != "-":
            k += 2 if rest[k] == "-t" else 1
        if k < len(rest):
            _scan(_expand_var(rest[k], shvars), st, host, tenv, cwd, depth, written)
    elif sub in ("pipe-pane", "pipep"):       # pipe-pane [-IOo] [-t target] [SHELL-COMMAND]
        k = 0
        while k < len(rest) and rest[k].startswith("-") and rest[k] != "-":
            k += 2 if rest[k] == "-t" else 1
        cmd = " ".join(_expand_var(a, shvars) for a in rest[k:])
        if cmd.strip():
            _scan(cmd, st, host, tenv, cwd, depth, written)
    elif sub in ("send-keys", "send"):
        k, literal = 0, False
        while k < len(rest) and rest[k].startswith("-") and rest[k] != "-":
            a = rest[k]
            literal = literal or "l" in a[1:]
            k += 2 if (a[-1:] in ("t", "N") and len(a) == 2) else 1
        typed = []
        for a in rest[k:]:
            if not literal and a in TMUX_KEYS:
                if a in ("Enter", "C-m", "C-j", "KPEnter"):
                    typed.append("\n")
                continue
            typed.append(_expand_var(a, shvars))
        text = "".join(typed)
        if text.strip():
            _scan(text, st, host, tenv, cwd, depth, written)


def _screen(args: list, st: _Scan, host, env: dict, shvars: dict, cwd: str, depth: int, written: dict):
    """`screen -dmS name CMD…` runs CMD; `screen -X …` sends a screen command to a session (not a shell's)."""
    k = 0
    while k < len(args) and args[k].startswith("-"):
        a = args[k]
        if a in ("-Logfile", "-logfile"):
            k += 2
            continue
        if "X" in a[1:] and not a.startswith("--"):
            rest = args[k + 1:]                                        # a screen command: only `stuff` types text
            if rest[:1] == ["stuff"] and len(rest) > 1:
                _scan(_unescape(_expand_var(rest[1], shvars)), st, host, env, cwd, depth, written)
            return
        took = False
        for i, ch in enumerate(a[1:]):
            if ch in "cehpStT":
                took = i + 2 >= len(a)                                 # the value is the next word
                break
        k += 2 if took else 1
    if k < len(args):
        _simple({"words": args[k:], "redirs": [], "heredocs": [], "bg": True}, st, host, env, shvars, cwd, depth,
                written)


def _device_in(args: list):
    """("cuda" | "xpu" | "cpu" | None, [idx] | None) from a --device argument anywhere on a launcher's or an unread
    script's command line: drift's b60_bench.sh passes `--device xpu` through safe_run to run_exp_xpu.sh (09-29)."""
    for k, r in enumerate(args):
        v = r.split("=", 1)[1] if r.startswith("--device=") else (args[k + 1] if r == "--device" and k + 1 < len(args) else None)
        if v is None:
            continue
        v = v.strip("'\"").lower()
        m = re.match(r"(cuda|xpu)(?::(\d+))?$", v)
        if m:
            return m.group(1), ([int(m.group(2))] if m.group(2) else None)
        if v.startswith("cpu"):
            return "cpu", None
    return None, None


def _launch_find(st: "_Scan", host, env: dict, why: str, args: list, kind=None):
    """A launch whose card comes from --device on its command line, else from the kind's variable."""
    dkind, didx = _device_in(args)
    if dkind == "cpu":
        return
    kind = dkind or kind
    st.find(host, env, why, idx=didx, prefix="xpu" if kind == "xpu" else "", kind=kind)


def _program_of(words: list) -> str | None:
    """The program a wrapped command really runs, past NAME=value, `env` (its options and assignments) and the
    wrappers: `env OMP_NUM_THREADS=1 nohup python x.py` -> "python". None when nothing is run (`env` alone)."""
    words = list(words)
    for _ in range(12):
        while words and NAME_ASSIGN.match(words[0]):
            words = words[1:]
        if not words:
            return None
        b = os.path.basename(words[0])
        if b == "env":
            words = words[1:]
            while words and words[0].startswith("-") and words[0] != "-":
                words = words[2:] if words[0] in ("-u", "--unset", "-C", "--chdir") else words[1:]
            continue
        if _runner_rest(words) is not None:
            words = _runner_rest(words)
            continue
        if b == "command":
            if words[1:2] and words[1].startswith("-") and any(ch in "vV" for ch in words[1][1:]):
                return None                  # command -v X: a lookup
            words = [w for w in words[1:2] if not w.startswith("-")] + words[2:] if words[1:2] and words[1].startswith("-") else words[1:]
            continue
        if b in WRAPPERS:
            flags, vals, pos = WRAPPERS[b]
            words = _skip_opts(words[1:], flags, vals, pos, {}, b)
            continue
        return b
    return None


def _wrapped_noop(cmd: list) -> bool:
    """A launcher wrapping nothing, or a read: `safe_run.sh --protected 64M true` (drift's admission smoke test).
    Looks through env and the wrappers: `env X=1 bash run.sh` runs bash, not a read."""
    prog = _program_of(cmd)
    return prog is None or prog in READS


def _launcher(prog: str, args: list, st: _Scan, host, env: dict):
    if any(a in ("-h", "--help", "--version") for a in args[:3]):
        return True                         # its usage text, not a run (reverie's `guest_run.sh --help`)
    if prog == "gpu1_launch.sh":
        lhost = _host_alias(env["HOST"], st.fleet) if "HOST" in env else "gpu1"   # gpu1_launch does its own ssh
        idx = [int(args[0])] if args and args[0].isdigit() else None
        if idx is None:
            gi = gpu_index(env)[0]
            idx = gi if isinstance(gi, list) else None
        st.finds.append((lhost, idx, "", "gpu1_launch.sh", False))
    elif prog == "guest_run.sh":
        for k, a in enumerate(args):
            v = a.split("=", 1)[1] if a.startswith("--gpu-mem=") else (args[k + 1] if a == "--gpu-mem" and k + 1 < len(args) else None)
            if v is not None:
                try:
                    if float(v) == 0:
                        return True         # --gpu-mem 0: a CPU-only guest job
                except ValueError:
                    pass
            if a == "--":
                break
        if "--" in args and _wrapped_noop(args[args.index("--") + 1:]):
            return True
        _launch_find(st, host, env, "guest_run.sh (a GPU cap)", args)
    elif prog == "safe_run.sh":
        rest = [a for a in args if a not in ("--protected", "--")]
        if _wrapped_noop(rest[1:]):         # rest[0] is the cap
            return True
        _launch_find(st, host, env, "safe_run.sh --protected (a training run)", args)
    else:
        _launch_find(st, host, env, prog, args)
    return True


def _python(args: list, sc: dict, st: _Scan, host, env: dict):
    st.runs += 1
    j, script, module, inline = 0, None, None, False
    while j < len(args):
        a = args[j]
        if a in ("-c",):
            inline = True
            j += 2
            break
        if a == "-m" and j + 1 < len(args):
            module = args[j + 1]
            j += 2
            break
        if a in ("-W", "-X"):
            j += 2
            continue
        if a == "-":
            inline = True
            j += 1
            break
        if a.startswith("-"):
            j += 1
            continue
        script = a
        j += 1
        break
    rest = args[j:]
    cpu_named = bool(script and any(rx.search(os.path.basename(script)) for rx in st.cpu_programs))
    if not (script or module or inline):
        inline = bool(sc["heredocs"])
    if any(r in ("-h", "--help", "--version") for r in rest):
        return
    dev = None
    for k, r in enumerate(rest):
        v = r.split("=", 1)[1] if r.startswith("--device=") else (rest[k + 1] if r == "--device" and k + 1 < len(rest) else None)
        if v is not None:
            dev = v.strip("'\"").lower()
    if dev is not None and dev.startswith("cpu"):
        st.cpu_verdicts += 1
        return
    if dev is not None and (dev.startswith("cuda") or dev.startswith("xpu")):  # asked for a device: beats any name
        kind = "xpu" if dev.startswith("xpu") else "cuda"
        m = re.match(r"(cuda|xpu):(\d+)$", dev)
        if m:
            st.finds.append((host, [int(m.group(2))], "xpu" if kind == "xpu" else "", f"--device {dev}", False))
        else:
            st.find(host, env, f"--device {dev}", kind=kind)   # only that kind's variable may index it
        return
    if cpu_named:                            # fleet.json guard.cpu_programs: an index in the environment is no evidence
        st.cpu_verdicts += 1
        return
    idx, prefix = gpu_index(env)
    if idx == "cpu":
        st.cpu_verdicts += 1
        return
    if _has_gpu_env(env):
        st.find(host, env, _env_why(env) + (f" python {os.path.basename(script)}" if script else " python"))
        return
    if module and TORCH_MODULES.match(module):
        st.find(host, env, f"python -m {module}")
        return
    for rx, kind in st.gpu_programs:
        if script and rx.search(os.path.basename(script)):
            st.find(host, env, f"python {os.path.basename(script)} (a GPU program)", kind=kind)
            return


def _docker(args: list, st: _Scan, host, env: dict):
    if args[:1] == ["container"]:
        args = args[1:]
    if args[:1] not in (["run"], ["create"]):
        return
    opts, j = args[1:], 0
    gpus, gpu = None, False
    while j < len(opts) and opts[j].startswith("-"):
        a = opts[j]
        name, eq, val = a.partition("=")
        if not eq and a in DOCKER_VALUE_OPTS:
            val = opts[j + 1] if j + 1 < len(opts) else ""
            j += 2
        else:
            j += 1
        if name == "--gpus":
            gpus, gpu = val.strip("'\""), True
        elif name == "--runtime" and val == "nvidia":
            gpu = True
        elif name == "--device" and val.startswith("/dev/nvidia"):
            gpu = True
    if not gpu:
        return
    spec = gpus or "all"
    md = re.search(r"device=([0-9][0-9,]*)", spec)
    if md:
        st.finds.append((host, [int(x) for x in md.group(1).split(",") if x], "", "docker run with a GPU", False))
    elif spec == "all" or gpus is None:
        st.finds.append((host, None, "", "docker run with a GPU", True))
    else:
        st.finds.append((host, None, "", "docker run with a GPU", False))


def detect(cmd: str, fleet: dict, local: str, cwd: str | None = None) -> dict:
    """Which cards a Bash command launches GPU work on.
    Returns {"launch", "via_run", "cards", "host_any", "why"}: host_any lists hosts where the command runs GPU
    work on an unnamed card (a lane must hold at least one card there)."""
    st = _Scan(fleet, local)
    try:
        _scan(cmd or "", st, local, {}, cwd or os.getcwd(), 0, {})
    except Exception as e:                  # fail open, visibly: a parser bug must never brick a lane
        return {"launch": False, "via_run": False, "cards": [], "host_any": [],
                "why": f"parse error, fail open ({type(e).__name__})"}
    out = {"launch": False, "via_run": st.via_run, "cards": [], "host_any": [], "why": ""}
    whys = []
    for host, idx, prefix, why, all_cards in st.finds:
        if host is None or host not in fleet["hosts"]:
            whys.append(f"{why} (host unresolved: fail open)")
            continue
        kind = "xpu" if prefix == "xpu" else "cuda"
        host_cards = [cid for cid, c in fleet["cards"].items() if c["host"] == host]
        typed = [c for c in host_cards if ("xpu" if fleet["cards"][c].get("caps", {}).get("xpu") else "cuda") == kind]
        if not typed:                       # no card of that kind here: the job cannot use this host's GPUs
            whys.append(f"{why} (no {kind} card on {host}: not a launch)")
            continue
        usable = [c for c in typed if fleet["cards"][c].get("compute_ok", True)]
        if all_cards:
            cards = usable or typed
        elif idx is not None:
            want = [f"{host}:{prefix}{i}" for i in idx]
            cards = [c for c in want if c in fleet["cards"]]
            if not cards:                   # an index the host does not have: the process sees no GPU at all
                whys.append(f"{why} (no {', '.join(want)}: not a launch)")
                continue
        elif len(usable) == 1:
            cards = usable
        elif len(typed) == 1:
            cards = typed
        else:
            cards = []
            if host not in out["host_any"]:
                out["host_any"].append(host)
        for c in cards:
            if c not in out["cards"]:
                out["cards"].append(c)
        whys.append(why)
    out["launch"] = bool(out["cards"] or out["host_any"])
    out["why"] = "; ".join(dict.fromkeys(whys))
    if st.via_run and not out["launch"]:
        out["why"] = "dreamteam gpu run (checked inside run)"
    return out
