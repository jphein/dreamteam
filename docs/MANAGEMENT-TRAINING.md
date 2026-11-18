# Management training: eight weeks, in the flow of work

Companion to [MANAGEMENT.md](MANAGEMENT.md). Asked by the owner on 2026-11-17: *"training me to manage it all"*.
Flow row `1e1cb678`.

**How it works**
- **One lesson a week, one practice from MANAGEMENT.md each.** No reading is needed: the lesson is the exercise.
- **One 5-minute exercise per week**, as a single card on `/now`: one tap, or one short typed line.
- **One 2-minute practice per day, on a real decision** already on his list that day. Nothing is added to the day.
- **One coaching line per day** from the 08:11 pass: one thing he did yesterday that was this week's muscle, and at
  most one next-time move. Plain words, two sentences at most.
- **Progress is a list of kept moments, not a count.** When a week's exercise is done, the plan keeps one real
  example from that week in his own words ("Week 2: I said 'do and tell' on the printer card"). No streaks, no
  scores, no totals. A week with no exercise simply stays the current week; nothing piles up.
- **Any lesson can be skipped or swapped** with one tap. The order below is by leverage, not a requirement.

Two practices from MANAGEMENT.md are the lead's to hold, so they have no lesson here: closed-loop callouts (3)
and timeboxed review (6).

## The eight lessons

Each coaching line is a template. The pass fills `<…>` from the log of the day before; if it finds no real
moment, it prints the *prompt* form, never an invented one.

### Week 1 — Say what "done" looks like (practice 1, intent-first briefs)
- **Muscle:** giving the purpose and the finish line, and leaving the how to the lane.
- **Exercise (5 min, typed):** pick one thing you want this week. Type one line: *"Done is when I see ___."*
  The lead turns it into the order.
- **Daily (2 min):** on one ask or chat message you send today, add the words "done is …".
- **Coaching line:** `Yesterday you told <lane> "<his done-line>": that is a brief, and it is why <result> came
  back in one pass.` · *Prompt:* `Today, on one message, add "done is …".`

### Week 2 — Pick the delegation level (practice 5)
- **Muscle:** choosing between *do*, *do and tell*, and *ask first*, out loud.
- **Exercise (5 min, tap):** a card shows one open item. Tap **Do it** or **Do and tell me each step**.
- **Daily (2 min):** on one hand-back today, say which level you mean in three words or fewer.
- **Coaching line:** `Yesterday you said "<his words>" on <card>: that set the level, so <lane> did not come back
  to ask.` · *Prompt:* `Today, on one card, say "do it" or "do and tell".`

### Week 3 — Review by evidence (practice 7, bottom line up front)
- **Muscle:** reading the first line and the Evidence line, and asking "what is not verified?" in place of
  "are you sure?".
- **Exercise (5 min, tap):** a card shows one real report from this week. Tap **Evidence is enough** or
  **Show me the check**.
- **Daily (2 min):** on one report today, read only its first line and its Evidence line, then decide.
- **Coaching line:** `Yesterday you asked <lane> for <the check> before accepting <claim>: that is reviewing by
  evidence.` · *Prompt:* `Today, on one report, ask "what is not verified?".`

### Week 4 — Say it once (practice 2, fix the system)
- **Muscle:** noticing a repeat, and asking for a mechanism in place of an apology.
- **Exercise (5 min, typed):** the card lists this week's "said twice" lines from the lead's log. Type the one
  that bothers you most. The lead owes a mechanism for it the same day.
- **Daily (2 min):** when you catch yourself repeating something, send only: *"said twice."*
- **Coaching line:** `Yesterday you said "<his words>" a second time; the fix is now <mechanism>, so you should
  not need to say it again.` · *Prompt:* `If you repeat yourself today, type "said twice".`

### Week 5 — One voice per thread (practice 4)
- **Muscle:** naming who answers, and answering one lane, not three.
- **Exercise (5 min, tap):** a card shows one thread where two lanes replied. Tap the lane that should own it.
- **Daily (2 min):** when you open a thread today, start it with the lane's name if you know it.
- **Coaching line:** `Yesterday you addressed <lane> by name on <thread>: one lane answered, in <n> minutes.` ·
  *Prompt:* `Today, start one question with the lane's name.`

### Week 6 — Limit what is in flight (practice 9)
- **Muscle:** saying "not now" and "no", and protecting his own daily time budget.
- **Exercise (5 min, tap):** a card shows the three newest things you started. Tap **Keep all** or **Park one**
  (the lead parks the newest unless you name another).
- **Daily (2 min):** before a new request today, check the "in flight" line; send it, or type "after <thing>".
- **Coaching line:** `Yesterday you parked <item> with "<his words>": that kept <other item> moving to done.` ·
  *Prompt:* `Today, try one "not now" on something new.`

### Week 7 — Watch indicators, not people (practice 8)
- **Muscle:** deciding what should be watched by a check, so nobody has to remember to look.
- **Exercise (5 min, typed):** type one thing you looked at by hand this week to see if it was working.
  A lane turns it into a CHECK line.
- **Daily (2 min):** read the Watch line in the morning brief first; open nothing that reads ok.
- **Coaching line:** `Yesterday you asked "<his question>"; it is now CHECK <name>, so the Watch answers it.` ·
  *Prompt:* `Today, notice one thing you check by hand.`

### Week 8 — The weekly review (practice 10, blameless retro)
- **Muscle:** looking back for one change, naming the system and not the lane.
- **Exercise (5 min, tap + one line):** the Sunday card shows three numbers (stuck rows, said-twice lines, review
  overruns) and one thing that worked. Tap **Keep going** or **Change one thing**, and type the thing.
- **Daily (2 min):** none this week beyond the Sunday card; the coaching line carries the week.
- **Coaching line:** `Last week you chose to change <thing>; here is what moved: <evidence>.` ·
  *Prompt:* `Sunday: one thing that worked, one thing to change.`

After week 8 the Sunday card stays, and the daily line draws on whichever muscle showed up the day before.

## Mechanisms

| Piece | Mechanism | State |
|---|---|---|
| Weekly exercise card | `ask add --key training:week-N`, filed Monday by the lead's 08:11 pass. Tap exercises use `--why-jp his-decision` with two `--choices`; typed ones use one `--answer text`. Both shapes pass the gateway today. | none yet (2026-11-17); Flow row `0dc150be` |
| Daily coaching line | The 08:11 pass reads the current week from this file's lesson headings and yesterday's log, and prints one line in the morning brief. No real moment → the prompt form. | none yet (2026-11-17); Flow row `0dc150be` |
| Kept moments | One line per finished week, kept by the plan and shown under the lesson list. | none yet (2026-11-17); Flow row `0dc150be` |
| Skip or swap | The weekly card's hand-back: "skip" moves to the next lesson, "later" keeps the week. | uses the existing hand-back |

**Start:** week 1 is the week of Monday 2026-11-23, or the first Monday after the mechanisms above are live.

**Wording rules for every card and line:** one item; say where it stands and what comes next; no words about
what was not done; no totals; his own words quoted where possible.

## Not verified

- The exercises are designed from MANAGEMENT.md and the coaching brief; none has been tried with the owner yet.
  Week 1 is the test: if the card takes more than five minutes, shorten the rest before week 2.
- The 08:11 pass has no code for the coaching line or the Monday card yet.
