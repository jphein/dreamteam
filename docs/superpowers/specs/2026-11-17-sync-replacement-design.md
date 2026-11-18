# What replaces Syncthing for `~/.claude` and `~/Projects` (design, for the owner's pick)

- **Date:** 2026-11-17 (drafted 19:46–20:1x PST by nebula-management, a research lane on serialhub)
- **Status:** proposal. Nothing here is applied. The owner picks an option in §5.
- **Asked by:** the owner, 18:59, relayed by the lead: *"i thought we were going to upgrade from syncthing"*.
  No earlier decision is on record. Flow row `c4690369`.
- **Scope:** the two synced folders on six hosts (familiar, katana, wakizashi, serialhub, gpu0, gpu1). Other
  Syncthing folders on katana (dotfiles, keys, CLI configs) are out of scope.

**Legend.** **[measured]** = read with an instrument on 2026-11-17 19:4x–19:5x. **[log]** = a line in the lead's
log for the date given. **[inferred]** = this document's reading, not checked.

## 0. The short version

Syncthing is doing three jobs that need three different guarantees. Most of today's trouble comes from giving all
three the same one: "every host converges on the newest file".

| Kind of data | What it needs | What Syncthing gives it |
|---|---|---|
| **Code** (233 repos) | History and merge: git | A shared working tree with a different `.git` on each host |
| **Per-host session state** (transcripts, settings) | One writer, shipped one way | Two-way merge, so a second writer makes a conflict copy |
| **Shared live state** (scratch, hand-offs, memory, large data) | One copy that everyone reads | N copies racing, plus a version store per host |

**Recommendation: option E, split by kind** (§4). Code moves to git-only clones. Session state ships one way to
familiar. Shared state is served from one host. Syncthing remains only as that one-way transport, or goes
entirely. It is done in four reversible phases, starting on the three newest lane hosts.

## 1. Current layout [measured]

- **Folders:** `claude-config` → `~/.claude` and `projects` → `~/Projects`, both send-receive on every host.
- **Sizes:** the projects folder syncs **158 GB** (serialhub's `.stignore` note). On disk with `.git` and
  dependency dirs, `~/Projects` is 244 GB on katana and 190 GB on familiar. `~/.claude` is 8–9 GB, of which transcripts (`projects/`) are 21.8 GB on katana before ignores.
- **Where the 158 GB is:** it is mostly data, not code. One project holds **80 GB**; the next eleven hold
  4–15 GB each. The twelve largest add up to about 160 GB.
- **Repos:** 322 project dirs on katana, 233 with a `.git` (familiar: 321 and 262, counting one level deeper). `.git` never syncs, so each host has its own refs over
  a shared tree.
- **Free disk:** familiar's root is at 94 % (15 GB free); its `~/Projects` copy is on an HDD with 239 GB free, and
  its archive HDD has 2.1 TB free. Katana has 149 GB free. Serialhub has 157 GB free and receives a 6.3 GB
  whitelist. **ubox0 has 36 GB free on a 119 GB SSD and runs no NFS or SMB server.**
- **Versioning differs per host:** `projects` is "simple, keep 2" on familiar and serialhub but **"staggered,
  30 days" on katana**, the setting that grew another folder to 71 GB in one night in October. `.stversions`
  today: 6.4 GB (projects) and 14.9 GB (`~/.claude`) on katana.
- **Per-host files:** `settings.local.json`, `.stignore` (which never syncs, so each copy drifts), venvs.

## 2. Failures this must end

| # | Failure | Evidence | Class |
|---|---|---|---|
| F1 | **Git refs lag the synced tree.** `git status` is wrong until someone "aligns" refs by hand; eight git verbs are blocked by a hook; commits go through the GitHub API. | [log 11-17] three hand aligns 08:55–09:06 (one refused: local main shared no history with the remote); six aligns of `~/.claude` between 17:5x and 19:3x, one per merged PR. | Code in a file syncer |
| F2 | **Conflict copies.** | [log 11-16] 80 `sync-conflict` copies and backups removed from `~/.claude`; one held a rotated API key. [log 11-16] six `.env` conflict leftovers. [measured] tonight: **124** conflict files in familiar's two trees; 21 in the top three levels of katana's `~/Projects`. | Two writers |
| F3 | **Stale content replaces new.** | [log 11-16 09:25] a hand-off file committed at 08:39 held stale content at 09:15, with no version copy on familiar. The lead's brief also names a replaced transcript; I did not find that line myself. | Two writers |
| F4 | **Version stores grow without bound, and keep secrets.** | [log 11-17 15:3x] 10 GB `.stversions` cleared on serialhub's first day. Housekeep skill: 8.6 GB → 71 GB overnight. [log 11-15] a scrubbed secret survived in version copies on three hosts. | N copies |
| F5 | **The folder no longer fits lane hosts.** | [measured] 158 GB against 157 GB free on serialhub; each new host gets a hand-kept whitelist `.stignore`. | Size |
| F6 | **Same-basename rescue trap.** | Housekeep skill: a rescue into a repo overwrote eight files and 1,756 lines, because a basename existed at two paths. | N copies |
| F7 | **A leak replicates in seconds** to every host and every version store. | [log 11-15] the scrub ran on three hosts under a lock. | N copies |

## 3. Options

Money cost is **$0** for every option: all use hardware on hand. "Effort" is agent time; "owner" is the owner's own
steps.

| | Option | Fixes | Leaves or adds | Effort · owner | Disk per lane host |
|---|---|---|---|---|---|
| **A** | **Keep Syncthing, harden it.** Same versioning everywhere, a synced whitelist, a conflict CHECK. | F4 in part, F5 in part | F1, F2, F3, F6, F7 stay: they come from the model, not the settings. | 1 day · none | as today |
| **B** | **Git-only repos.** GitHub stays the remote (optionally a bare mirror on familiar for speed and outages). Each host clones only the repos its lanes use, outside any synced folder. Lanes work in worktrees. | F1, F5, F6 for code; F2/F3 for tracked files | Scratch and untracked files have no home; work that is not pushed stays on one host. Needs a push-on-stop hook and a CHECK for unpushed commits. Does nothing for the 80 GB of data. | 3–4 days · none | 0.1–2 GB |
| **C** | **A central share** for scratch, state and large data (NFS, or sshfs where NFS is awkward). | F2, F3, F4, F6, F7 for shared state; F5 for data | One host down takes every lane's scratch with it. NFS over WiFi is slow for many small files. **SQLite and other lock-heavy stores must not live on it.** ubox0 fits only ~30 GB, so the data would be served from familiar's archive disk (2.1 TB), and familiar is allowed to sleep. | 2 days · none | ~0 |
| **D** | **Mutagen or Unison pairs** in a star around familiar. | F2 in part: both stop on a conflict instead of writing a copy. F4: no version store. | Still a file syncer under git, so F1 stays. Five pair sessions to watch; Unison needs the same version on both ends and runs in batches; Mutagen is a daemon per pair. A stopped pair is silent unless checked. | 2–3 days · none | as today |
| **E** | **Split by kind** (recommended): B for code, one-way shipping for session state, C for shared state and large data. | F1–F7 | Three mechanisms to learn in place of one; the share is a single point of dependence for scratch (softened below). | 5–6 days in four phases · one tap per phase | 0.1–2 GB + mounts |
| **F** | **Syncthing for `~/.claude` only**, B for projects. | F1 and F5 for projects | `~/.claude` is itself a git repo, so F1 stays there (tonight's six aligns were all `~/.claude`), with F2–F4 and F7. | 3–4 days · none | 8–9 GB |

**Read of the candidates.** B is necessary and not sufficient: it cures the code but strands scratch. C alone
cannot hold code, since git over a network share is slow and its locks are fragile [inferred from the SQLite and
lock caveat]. D replaces the tool and keeps the model. F keeps Syncthing exactly where it produced tonight's
aligns.

## 4. Recommended design (option E)

1. **Code: git only.** `~/Projects/<repo>` becomes a normal clone with its own `.git`, on the hosts that need it.
   Lanes work in worktrees and push branches. The synced-tree git guard, the align script and API-only commits
   retire once a host has no synced repo.
   - *Mechanisms:* a Stop hook that pushes the lane's branch (or names what is unpushed); CHECK
     `unpushed-commits` per host; `realm`-style `repo sync <name>` to clone or fast-forward.
2. **`~/.claude` config: git, deployed.** Tracked files (hooks, skills, CLAUDE.md, settings.json) arrive by a
   fast-forward pull after each merge on claude-config's main, by timer and on demand. `settings.local.json`
   stays per-host and untracked, as now. This replaces the hand align.
3. **Session state: one writer, shipped one way.** Transcripts and per-host state stay on the host that writes
   them and are copied one way to familiar for mining (`rsync` on a timer, or a Syncthing send-only →
   receive-only pair with versioning off). A file with one writer cannot conflict.
4. **Shared live state: one copy, served.** Scratch, hand-offs and auto-memory live on one host and are mounted
   on the others at a fixed path, with `x-systemd.automount` and a soft timeout so a host that is away gives an
   error, not a hang. **Sizing decides the server:** if shared state is under ~20 GB it fits ubox0's SSD
   (always on); the large data (the 80 GB project and its peers) goes to familiar's archive disk, read-mostly.
   - *Softening the single point:* Flow rows and PRs already carry reports, so a lane with no mount can still
     report; a nightly snapshot of the share goes to a second host.
   - *Never on the share:* SQLite stores (plan state, palace), sockets, venvs.
5. **Per-host overlays stay local:** `settings.local.json`, venvs, caches. One documented list replaces the
   drifting `.stignore` files.

## 5. Migration, phase by phase (each ends with a check and has its own rollback)

| Phase | Steps | Check | Rollback |
|---|---|---|---|
| **0. Inventory** (no change) | Script per repo: untracked and ignored files of value, unpushed commits, size, conflict copies. Measure the real size of scratch and memory. Back up every host's Syncthing config. | A table per repo; shared-state size known, which settles ubox0 or familiar. | Nothing to undo. |
| **1. Lane hosts** (serialhub, gpu0, gpu1) | Pause their `projects` folder; clone their few whitelisted repos; mount the share; pull `~/.claude` by git. | A lane runs a full task: commit, push, PR, report, with no align step. | Unpause the folder: the whitelist and files are untouched. |
| **2. `~/.claude` everywhere** | Git deploy on all six; transcripts one-way to familiar; pause the two-way folder. | A merged hook is live on six hosts with no hand align; palace mining still sees every host's transcripts. | Unpause; the paused folder keeps its index. |
| **3. Large data** | Move the data-heavy dirs to the served disk; leave a symlink or a documented path. | Each project's own test or run reads its data from the new path. | Move back; the source is kept until the check passes. |
| **4. familiar ↔ katana ↔ wakizashi projects** | Commit or relocate every untracked file found in phase 0; convert repos to plain clones; pause the last folder. | `git status` is clean and true on each host; CHECK `unpushed-commits` green. | Unpause. Folders are **paused, never removed**, for 14 days; `.stversions` are kept until then, then deleted with the secret scrub rerun. |

One-way doors: none before day 14. Deleting the paused folders and version stores after that is the only
irreversible step, and it gets its own card.

## 6. What the owner picks

1. **E — split by kind** *(recommended)*: phases 0–4, about a week of lane time, one tap per phase.
2. **B + F — git for projects, Syncthing kept for `~/.claude`**: smaller change; tonight's `~/.claude` aligns stay.
3. **A — harden only**: one day; the align work and conflict copies stay.

Whatever the pick, three fixes are worth doing now and conflict with none of them: set katana's `projects`
versioning to match familiar's (it is on the setting that blew up before), add a CHECK for `sync-conflict`
files, and run phase 0's inventory.

## 7. Not verified

- The tooling claims about Mutagen and Unison are from documentation knowledge, not a trial on these hosts.
- NFS behaviour over serialhub's WiFi link was not measured; neither was sshfs.
- The size of scratch and memory alone was not measured (phase 0), so "ubox0 or familiar" is open.
- wakizashi, gpu0 and gpu1 were not read directly; their layout is taken from the log.
- The 158 GB synced figure is from serialhub's `.stignore` comment, not a Syncthing API read; the per-project
  breakdown is katana's walk only.
- No cross-model review: this is a proposal with no change applied.
