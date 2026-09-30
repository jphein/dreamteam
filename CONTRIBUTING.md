# Contributing to dreamteam

## Before you open a PR

- Run `bash tests/run.sh`. Every suite must pass.
- New behaviour gets a test in `tests/`. Each suite is standalone and self-isolating, so copy the shape of a neighbour.
- A bug fix comes with a regression test **you saw fail** on the unfixed code. Put that red output in the PR body.
- `timeout` in `hooks/hooks.json` is in **seconds**. The dream-name roster is derived from lexicon. Both are covered in `CLAUDE.md` "Key constraints".

## The PR report — Definition of done

End the PR body (and every lane report) with four parts:

1. **Changed:** what is different, in plain words.
2. **Checked:** the commands run against the real thing. "Tests pass" alone is not a check.
3. **Evidence:** something rerunnable, such as a sha, log line, count or test output.
4. **Not verified:** an honest list. "Nothing" is suspicious.

## Merge gate (self-merge, per JP's "never the bottleneck" rule)

Who merges depends on the setting:

- **Outside a dream-team wave:** the author merges their own PR once the gate below holds.
- **Inside a wave:** lanes push and stop. The lead gates and merges through `scripts/cascade.sh`, and a lane rebases only on `go #<pr> <sha>`. See SKILL.md § Merging a wave.

The gate has four conditions:

1. CI or `tests/run.sh` is green;
2. one perturbation went red;
3. the diff is secret-scanned;
4. hook, security or other high-stakes code has an independent review: an Oracle read-only pass **and** a second-vendor `~/.claude/scripts/xreview` read. If Foundry is down, the Oracle pass alone satisfies this condition, and the PR says "no cross-model check (reason)" under **Not verified**.

Record the review verdicts on the PR, along with who merged it and why.

## Operating rules

The fleet's operating lessons, each with the incident that produced it, live in [`skills/dreamteam/SKILL.md` § Fleet lessons](skills/dreamteam/SKILL.md). `tests/test-lessons.sh` fails if one of them goes missing.
