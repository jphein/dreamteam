#!/usr/bin/env python3
"""dreamteam — read a tmux pane the way a person sees it: a FAINT prompt line is not typed text.

    tmux capture-pane -p -e -t <pane> | pane_plain.py            the pane as plain text, input box cleaned
    tmux capture-pane -p -e -t <pane> | pane_plain.py --typed    what is really typed in the input box (or nothing)
    tmux capture-pane -p -e -t <pane> | pane_plain.py --ghost    the faint suggestion in the input box (or nothing)

Why (measured 2026-11-21 17:38 on a lane pane): Claude Code shows its predicted next prompt in the input box as a
PLACEHOLDER, rendered faint (SGR 2, `ESC[2m`). `capture-pane -p` drops the attribute, so the suggestion reads as
text someone typed and never sent. Four "lines signed by the lead, typed but unsent" on 11-20/21 were this: nobody
typed them, Ctrl-U cleared nothing, no send log could ever show them. `scripts/quota_resume.py` has known since
2026-10-05 (its `typed_text`); this is the same rule in one place for every other reader (poke.sh, pane-peek.sh,
the lead's sweep).

The rule. The input box is a line whose text, after any box-drawing border, starts with `❯`. On such a line every
character rendered faint is dropped. Faint text on any OTHER line is kept (dim hints and footers are real output).
Attributes are read per line (tmux re-emits them at each line start): SGR 2 turns faint on; SGR 0, an empty SGR
and SGR 22 turn it off. Everything else is only stripped. The capture MUST be taken with `-e`: without escape
codes nothing here can tell typed from suggested, and the text passes through unchanged.

Never hides typed text by mistake: bytes that are not valid UTF-8 are kept, and if anything in here raises, the
input is printed with its escape codes stripped and nothing removed (exit 0): a reader then sees MORE, not less.
"""
import re
import sys

CSI = re.compile(r"(\x1b\[[0-9;:?]*[ -/]*[@-~])")
SGR = re.compile(r"^\x1b\[([0-9;:]*)m$")
OTHER_ESC = re.compile(r"\x1b(?:\][^\x07\x1b]*(?:\x07|\x1b\\)|[@-Z\\-_])")
BORDER = "│┃|╎┆┊ \t"


def split_line(raw):
    """→ (normal text, faint text) of one captured line, escape codes removed."""
    raw = OTHER_ESC.sub("", raw)
    normal, faint, dim = [], [], False
    for tok in CSI.split(raw):
        if not tok:
            continue
        if tok.startswith("\x1b["):
            m = SGR.match(tok)
            if m:
                params = [p for p in re.split("[;:]", m.group(1))] if m.group(1) else ["0"]
                for p in params:
                    if p in ("", "0", "22"):
                        dim = False
                    elif p == "2":
                        dim = True
            continue                                   # any other control sequence: dropped
        (faint if dim else normal).append(tok)
    return "".join(normal), "".join(faint)


def is_prompt(plain):
    return plain.lstrip(BORDER).startswith("❯")


def process(text):
    """→ (lines as plain text with faint prompt text dropped, typed text of the last prompt, its faint text)."""
    out, typed, ghost = [], "", ""
    for raw in text.split("\n"):
        normal, faint = split_line(raw)
        whole = split_line_plain(raw)
        if is_prompt(whole):
            out.append(normal.rstrip())
            body = normal.lstrip(BORDER)
            typed = body[1:].strip(BORDER) if body.startswith("❯") else body.strip()
            ghost = faint.strip()
        else:
            out.append(whole)
    return out, typed, ghost


def split_line_plain(raw):
    return CSI.sub("", OTHER_ESC.sub("", raw))


def main(argv):
    mode = argv[1] if len(argv) > 1 else ""
    if mode not in ("", "--typed", "--ghost"):
        print("usage: pane_plain.py [--typed | --ghost] < capture-pane -p -e output", file=sys.stderr)
        return 22
    data = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
    try:
        lines, typed, ghost = process(data)
    except Exception:                                  # show more, never less
        sys.stdout.buffer.write(split_line_plain(data).encode("utf-8", "surrogateescape"))
        return 0
    if mode == "--typed":
        text = typed
    elif mode == "--ghost":
        text = ghost
    else:
        text = "\n".join(lines)
    sys.stdout.buffer.write(text.encode("utf-8", "surrogateescape"))
    if text and mode:
        sys.stdout.buffer.write(b"\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
