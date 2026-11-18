# Managing an agent fleet with people-management research

**Question:** how should a lead and an owner manage about twelve persistent agent lanes plus short-lived
teammates, using what the evidence on managing people says? This page covers where that evidence transfers and
where it does not. Written 2026-11-17 from that day's fleet log. Lines marked *(inference)* are this document's
reading, not a source's finding.

**Leverage first.** Grove's measure of a manager is the output of the organisation they run. Leverage is highest for
work that shapes many later outputs, and for catching a defect at the cheapest stage [1]. Hackman and Wageman put
team performance at roughly 60 % design before the work starts, 30 % the launch and 10 % coaching during the
work [6]. Multi-agent results point the same way. In Anthropic's research system, vague task descriptions from the
lead caused duplicated and drifting subagent work [12]. The MAST study traces most multi-agent breakdowns to
specification, inter-agent misalignment and verification, not to model skill [13]. The practices below are ranked
on that basis.

## 1. Ten practices that transfer

| # | Practice · source | What it looks like here | Mechanism | Today's incident it addresses |
|---|---|---|---|---|
| 1 | **Intent-first briefs.** Mission command: state the purpose and end state, then let the subordinate choose how [9]. Hackman's 60 % [6]. | Every order and brief opens with *intent* (why), *done* (what JP will see), *facts* (the fleet-facts block) and *limits*. | Brief template; `flow order` lint asks for intent/done lines; lexicon fleet-facts block appended to briefs. | A lane guessed a town for snow prep instead of looking it up, and the owner asked why it lacked context. |
| 2 | **Fix the system when told twice.** Deming: most trouble belongs to the system, which only management can change (his 94 %) [3]. | A correction the owner gives a second time is a system defect. It gets a rule plus its mechanism the same day, not a second apology. | The lead logs `said-twice:` lines; each becomes a FRICTION or TOOLING-FRICTION row; the 08:11 pass counts them. | "Why do you need me?" and "of course you can close cards" came a minute apart on the same two cards (17:27, 17:28). |
| 3 | **Closed-loop callouts.** Crew resource management: call out each state change, read the order back, close the loop [10]. | A lane that stops with an open row says where the row stands (`checkpoint`, `block`, `done`) before it goes quiet. An order is read back as the first checkpoint, in the lane's words. | Stop hook: an open Flow row with no word since the last order blocks the stop with "say where <id> stands". Replaces the reply-ACK convention (§4). | An idle agent went quiet twice without saying what happened to an approved task; the lead had to ask. |
| 4 | **One voice per thread.** Aviation splits "pilot flying" from "pilot monitoring" so one person acts and one watches [10]. Team Topologies: clear ownership boundaries [7]. | Each owner thread has one answering lane. The lead routes and stays quiet on it; others feed facts to the owner of the thread. | `plan-chat reply` refuses a reply on a thread another lane owns, unless `--handoff <lane>`. | Two agents answered the owner on one thread within a minute (16:03); two DMed him the same steps (16:15–16:16). |
| 5 | **Delegate by task-relevant maturity.** Grove: the right amount of structure and checking depends on the subordinate's maturity *for this task* [1]. Fournier on delegation levels [5]. | Each row carries a level: **do** (act, report at done), **do-and-tell** (act, checkpoint each step), **ask-first**. A new host or new domain starts at do-and-tell. | `flow order --level`; the `flow stuck` threshold follows the level; the existing `--why-jp` gate keeps ask-first narrow. | "Why do you need me?": a lane brought the owner a card it could close itself. |
| 6 | **Timebox inspection; build quality in.** Deming point 3: stop relying on inspection [3]. Scrum: every event is timeboxed [8]. | A review that keeps finding issues signals that the diff or the spec is too big. At the cap, split the change or write the red test that would have caught it; do not run another round. | `xreview --pr <owner/repo#N>` counts rounds per repo+PR (state `~/.local/state/xreview/rounds/`) and refuses round 13 (exit 8) unless `--over-cap "<reason>" --row <flow id>` first posts the reason to that Flow row; `xreview --rounds` is the "rounds N" of the PR comment (claude-config #152, 2026-11-17; tests `tests/test-xreview-rounds.sh`). | Review loops ran 42 and 16 rounds against a cap of 12. |
| 7 | **Bottom line up front.** US Army correspondence standard: the conclusion and the ask come first [11]. Grove: a report is a discipline for its writer [1]. | The first line of every report is the one the owner needs: result, then his one action or "none". The Definition of Done (Changed · Checked · Evidence · Not verified) follows. | Report template; the lead rejects a report whose first line is not the answer. *(inference: a length lint can follow if the template alone does not hold.)* | Reports arrive as long prose; the lead relays; the owner reads only the last message. |
| 8 | **Indicators that can see.** Grove: watch output indicators, pair each with a counter-indicator, catch problems at the lowest-value stage [1]. | Every integration the owner relies on has a CHECK line with a positive control, so silence means health, not blindness. | CHECK lines on the Watch; a new device or backend ships with its CHECK. | A device sat offline 23 h, and another for 5 days, before anyone noticed (16:43). |
| 9 | **Limit work in progress.** Kanban: cap WIP so work finishes; by Little's law, more WIP means longer cycle time [8, 14]. | One task in progress per lane, plus one waiting. A turn over 60 min checkpoints. Orders cannot reach a lane mid-turn, so long turns hide it from the lead. | `flow` warns when a lane opens a second in-progress row; the turn-watch line in the lead's sweep. | A lane spent 2 h 18 min in one turn while the lead's orders waited in its queue (12:46). |
| 10 | **Weekly blameless retro.** Scrum retrospective [8]; Edmondson: teams that report errors learn faster, and "failing well" means small, early and studied [4]. Google's Aristotle ranks psychological safety first [2]. | Once a week: what worked, what repeated, one change with a mechanism. Bad news is cheap to give: `flow block` and "Not verified" are the expected moves, not admissions. | Sunday retro section in the plan pass, built from `flow stuck`, said-twice counts, review-round overruns and TOOLING-FRICTION age. | Prevents the repeat class: the same double-answer or over-cap pattern returning next week. |

Good patterns from the same day that these build on: rows checkpointed with evidence, the Definition of Done,
one-tap asks with `--why-jp`, the "finish now" rule, and a lane retracting a claim with its source within minutes
(16:1x) when the owner doubted it.

## 2. Five things that do not transfer, and what replaces them

| Human lever | Why it does not transfer | What replaces it for agents |
|---|---|---|
| **Motivation and recognition** (Oxygen: a good manager shows concern for team members' success and well-being [2]) | An agent has no drive to raise. Its effort tracks its instructions and context. | **Context and the brief.** A clear intent, done-line and facts block do the work praise does for people (practice 1). |
| **Careers and growth** (Fournier's 1:1 career talks [5]) | A lane does not carry growth between sessions. What it learned leaves when the session ends. | **The org learns instead.** Lessons go into skills, CLAUDE.md, hooks and memory files; a lesson without a mechanism has not been learned. |
| **Fatigue and burnout** | No fatigue, but a context window that fills up and degrades, and a turn that cannot be interrupted. | **Token and turn budgets.** Compact at natural breakpoints, cap turn length, resume rather than respawn. |
| **Trust built over years** (Grove's maturity grows with time [1]) | Each session starts cold, and models state guesses with confidence. They also lean toward agreeing with the person they answer [15]. | **Evidence per claim.** Trust attaches to a rerunnable check, not to the agent's track record; maturity is per task *and* per session (practice 5). |
| **Salary and incentives** | Nothing to pay. Cost lands on the owner as quota and money. | **Quota as the budget.** Seats, model tier and parallelism are the spend; Brooks's n(n−1)/2 channels [16] and the ~15× token cost of multi-agent work [12] mean more lanes are not free. |

Psychological safety transfers only in part *(inference)*. Agents feel no fear, but they lean toward answering and
agreeing [15]. That produces the same symptom, unreported doubt, so the remedy is the same: make "I don't know",
`block` and "Not verified" the cheapest moves in the template.

## 3. Operating rhythm (one page)

**The lead's day**
- **Checkpoints, not acks.** An order is a Flow row; the lane's first checkpoint reads the order back. Silence past
  the level's threshold shows in `flow stuck`; the lead asks once, then routes the work elsewhere.
- **Stuck detection** each sweep: `flow stuck`, idle lanes holding open rows, turns over 60 min, review rounds over
  the cap.
- **One voice per thread.** Every owner thread has an owner lane. The lead answers the owner only on its own threads
  and when routing; it does not echo a lane's answer.
- **Who answers the owner:** the thread's owner lane, through plan-chat or a one-tap card, never a second DM.
- **Relay by summary, not by forwarding:** one BLUF line to the owner, the detail stays on the row.
- **Weekly 1:1 per lane** (Grove: the subordinate's meeting [1]). The lead reads the lane's HANDOFF and its rows
  and asks: what is blocked, what keeps repeating, and what would make your briefs better?

**The owner's day**
- **One list, one tap each** (`/now`). Anything else that reaches him is a defect for practice 2.
- **Coaching in the flow of work:** once a day the plan pass names one thing he did that was management (what,
  and why it worked) and at most one next-time move, in plain words. The muscles to work on: delegation level
  (practice 5), stating "done" in the ask (1), reviewing by evidence (7, 8), saying a correction once and expecting
  a mechanism (2).
- **Says it once.** If he must repeat himself, the lead owes him a mechanism, not a reply.

**The weekly retro** (Sunday, in the plan pass): three numbers (stuck rows, said-twice lines, review overruns),
one thing that worked, one change with its mechanism and owner as a Flow row. Blameless: name the system, not
the lane.

## 4. Rule changes this proposes

- **SKILL.md "Cadence & ACK" (D3):** replace "every assignment ends `reply ACK`" with "the first `flow checkpoint`
  reads the order back". An ACK proves delivery; a read-back proves understanding [10].
- **FOR-AGENTS rule 27:** add `--level do|tell|ask` to `flow order`. A row ordered for a lane off familiar should
  carry that lane's name, not the lead's. Today such a row refused the lane's own checkpoint (rc 22).
- **The fleet's 12-round review cap** (set by the lead 2026-11-17 08:09): give it its mechanism (practice 6).
  Done 2026-11-17 (claude-config #152): `xreview --pr` counts, round 13 needs `--over-cap` posted to the row.

## 5. Three changes to ship this week (Flow rows, children of 1b134723)

1. **Stop-hook callout** (practice 3). A lane cannot end a turn holding an open row it has not spoken on since the
   last order. Owner: the dreamteam lane (via Sen). Row `76b3ff47`.
2. **Thread owner in plan-chat** (practice 4): one answering lane per thread, `--handoff` to pass it. Owner: plan-62.
   Row `b0654b98`.
3. **xreview round counter** (practice 6): refuse round 13 without `--over-cap`, which posts to the row.
   Owner: palace-nemotron-80 (claude-config). Row `603e11ba`.

All three are expected by Sat 2026-11-21 18:00.

## Sources

1. Andrew S. Grove, *High Output Management*, Random House, 1983 (leverage, task-relevant maturity, indicators, one-on-ones).
2. Google re:Work, "Project Oxygen" (2008–) and "Guide: Understand team effectiveness" (Project Aristotle, 2015).
3. W. Edwards Deming, *Out of the Crisis*, MIT CAES, 1986 (14 points; the 94 % system estimate).
4. Amy C. Edmondson, "Psychological Safety and Learning Behavior in Work Teams," *Administrative Science Quarterly* 44(2), 1999; *Right Kind of Wrong*, Atria, 2023.
5. Camille Fournier, *The Manager's Path*, O'Reilly, 2017.
6. J. Richard Hackman, *Leading Teams*, Harvard Business School Press, 2002; Hackman & Wageman, "A Theory of Team Coaching," *Academy of Management Review* 30(2), 2005 (60-30-10).
7. Matthew Skelton & Manuel Pais, *Team Topologies*, IT Revolution, 2019.
8. Ken Schwaber & Jeff Sutherland, *The Scrum Guide*, 2020; David J. Anderson, *Kanban*, Blue Hole Press, 2010.
9. US Army, ADP 6-0 *Mission Command*, 2019; Stephen Bungay, *The Art of Action*, Nicholas Brealey, 2011.
10. FAA Advisory Circular 120-51E, *Crew Resource Management Training*, 2004.
11. US Army Regulation 25-50, *Preparing and Managing Correspondence* (bottom line up front).
12. Anthropic, "How we built our multi-agent research system," engineering blog, June 2025.
13. Cemri et al., "Why Do Multi-Agent LLM Systems Fail?" (MAST), arXiv:2503.13657, 2025.
14. John D. C. Little, "A Proof for the Queuing Formula L = λW," *Operations Research* 9(3), 1961.
15. Sharma et al., "Towards Understanding Sycophancy in Language Models," arXiv:2310.13548, 2023.
16. Frederick P. Brooks Jr., *The Mythical Man-Month*, Addison-Wesley, 1975.

Lencioni is left out: his five dysfunctions add nothing here that Edmondson and Hackman do not already cover
with stronger evidence.
