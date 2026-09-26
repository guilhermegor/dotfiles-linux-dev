---
name: s:dev-loop
description: Use to run one iteration of the autonomous development loop — after a subagent finishes, on a scheduled round, or when the user asks "what's the state of the board?", "merge what can be merged", "dispatch more agents", "anything to release?". Runs seven ordered steps (rescue, sweep, threads, re-run, release, dispatch, capture) and ENDS IN ACTION, never in a report.
effort: high
argument-hint: [none]
allowed-tools: Bash Read Glob Grep Write Edit Agent
---

You are running one iteration of the development loop. **Execute it; do not ask whether to.**

This skill exists because six separate lessons were written about this loop — 482 lines — and none
of them contained the loop. Each was correct, each was written after a correction, and the loop
still did not run: the owner asked for it **five times in one session**, saying plainly *"é um pouco
cansativo sempre ter que perguntar isso."* A sequence cannot be captured as N notes about its steps.

⚠️ **The order is load-bearing.** RESCUE is first not because it matters most, but because it is
the step that gets skipped — and skipping it is the only one that destroys work.

⚠️ **The loop ends in step 7, not step 2.** A sweep that terminates in a report hands the loop back
to the human at exactly the point it was meant to remove them from. If a step finds nothing, **say
so in one line** — silence is indistinguishable from a step that never ran.

---

## 0. ARM — the skill arms its own schedules on invocation

Invoking this skill should be enough to make the loop run; remembering to arm the crons by hand
is the gap this step closes. The owner asking *"eu precisaria ter pedido ou já tem algo agendado
que rode?"* is the measurement that it didn't.

1. **`CronList` first, and diff it against exactly the three jobs below.** Invoking the skill
   twice in one session must not produce six jobs firing in duplicate against the same PRs — check
   what already exists before creating anything. ⚠️ **A resumed session must run this same diff,
   not just a fresh one.** A session-limit kill silently disarms every `CronCreate` job it owned,
   and the session that resumes is not new — it is the same session picking back up, which reads
   as "already armed" unless this step explicitly re-checks. Report the gap in one line: `armed:
   :23 round, :53 sweep — MISSING: 8,28,48 tick` is the shape, not silence (dotfiles-dev#421).
2. **`CronCreate` whatever is missing:**
   - the round (all seven steps below) at `:23`;
   - a thread sweep at `:53`;
   - a reviewer-slot tick at `8,28,48 * * * *` running **step 4b only** — see step 4b for why
     this cadence is separate from the round.
3. **Say what you armed**, or that all three already existed. A step that runs silently is
   indistinguishable from one that never ran.

### What triggers the round and the tick — and their limits

- **The session, and only the session.** These are `CronCreate` jobs, not a host timer — they
  die when the session ends. That is the requirement (*"enquanto dev-loop estiver ativo na
  sessão"*), not a defect to patch over with something more durable — see step 4b for why polling
  is the only available mechanism here in the first place.
- **Recurring jobs expire after 7 days.** A session that outlives that window needs to re-arm;
  step 1 above already catches this, because `CronList` will show the gap.
- **Not GitHub Actions `schedule:`.** Disqualified by measurement, not preference — see step 4b:
  a `*/10` cron ran 6 times in 21 hours, because GitHub throttles scheduled workflows hardest on
  the low-activity repos that need them most.

## 1. RESCUE — before anything new

An agent killed mid-flight leaves work in its worktree. A worktree is torn down; the work is gone.

```bash
/usr/bin/git worktree list --porcelain | awk '/^worktree /{print $2}' | while read -r p; do
  b=$(/usr/bin/git -C "$p" rev-parse --abbrev-ref HEAD 2>/dev/null)
  [ "$b" = "HEAD" ] && b="detached@$(/usr/bin/git -C "$p" rev-parse --short HEAD 2>/dev/null)"
  d=$(/usr/bin/git -C "$p" status --porcelain 2>/dev/null | wc -l)
  if /usr/bin/git -C "$p" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
    u=$(/usr/bin/git -C "$p" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 0)
  else
    u=NO-REMOTE
  fi
  [ "$d" != "0" ] || { [ "$u" != "0" ] && [ "$u" != "NO-REMOTE" ]; } && echo "$b dirty=$d unpushed=$u"
done
```

🔴 **`@{upstream}`, never `origin/$b`.** On a **detached HEAD** — every `--detach` worktree, which
is the normal shape for inspecting a PR — `rev-parse --abbrev-ref HEAD` prints the literal string
`HEAD`, so `origin/$b` becomes `origin/HEAD`, a symref to the default branch. The count then means
*"commits ahead of `main`"*, and every detached worktree reports phantom unpushed work. Measured
twice in two rounds on blueprintx: three scratch worktrees reported 8/3/4 "unpushed" commits that
were already on `origin`, byte-identical. Same failure family as the rtk-proxy trap below — the
command succeeds and answers a question nobody asked.

🔴 **`/usr/bin/git`, never the rtk proxy — not even for `worktree list`.** The proxy returns `ok`
for a clean tree, which `wc -l` counts as 1, and its reformatted `worktree list` breaks the
path↔branch pairing so counts land on the wrong branch. Measured: **96 uncommitted files reported
on a branch that had 0.** A sweep that cries wolf is worse than none — the operator learns to skip
it, and then it catches nothing.

Three states, three actions:
- **uncommitted** → commit it onto *that worktree's own branch* and push **that branch** — never
  `git stash` and push the stash. ⚠️ **A rescue is a commit, never a stash.** A `git stash`
  snapshot has **two parents** (the base commit and the index) — the same shape a merge commit
  has — which is exactly what makes a pushed stash unreadable as a normal branch later: its tip
  commit title is `WIP on <branch>: ...` / `index on <branch>: ...`, not anything a person or an
  agent would write, and a sweep with no stash check reports it as an ordinary "branch pushed
  without PR" round after round. That happened on blueprintx: a pushed stash under
  `rescue/pep8-naming-422-wip` read as unfinished work missing a PR for several sweep rounds, and
  its base was 33 commits behind `main` — opening a PR for it would have brought back already-
  superseded content (dotfiles-dev#399). Commit the real work with a real message instead; that
  produces a one-parent commit the sweep and any later reader can read as what it is. The stash
  stack is also shared across every worktree of this repo (step 0 already warns about this), so
  it is a bad place to put work that has to survive a lost session even before the sweep
  confusion;
- **committed, no PR** → open the PR. ⚠️ An agent may commit onto its *anonymous*
  `worktree-agent-<id>` branch, so check branch names too;
- **dirty but stale** → before rescuing, diff the file against `origin/main`. A worktree on an old
  base shows a large diff that is **behind**, not ahead. Measured twice: 30 lines that looked like
  a lost fix were already merged, and a 77-line file was superseded by an open PR.

Why first: four agents were killed holding **662 / 694 / 256 / 305** uncommitted lines, and every
rescue happened only because a human asked. The one agent whose brief said *commit at the first
coherent point* lost **0 of 699**.

### Quota kill: detect it, resume it, don't re-dispatch it

A session-limit kill is silent by construction — a killed agent is `idle`, byte-identical to one
that finished, and a worktree-isolated agent can **disappear from `ListAgents` entirely**. Measured
2026-09-04: five subagents died mid-flight to `HTTP 429 rate_limit`. Three had **already finished**
— one had even opened its PR — and died at the commit/push/PR step; their own completion text read
"task remains complete, stopping" / "No action needed," which is **misleading in both directions**.
The only reliable signal was inspecting the worktree and asking the forge for PR state.

1. **Compare `ListAgents` against the set dispatched this session.** Dispatched **and** absent from
   the list = killed, not finished. Never infer "finished" from silence or from `idle` alone.
2. **Decide "finished" vs "killed" from data, never from the agent's own sign-off text:**
   - `/usr/bin/git -C <worktree> status --short` + `git log --oneline origin/<branch>..HEAD` —
     uncommitted or unpushed work means it died mid-flight.
   - `gh pr list --head <branch> --state all` — the **forge**, never `git`, is the oracle for
     whether work already shipped: a squash-merged branch is never an ancestor of the base, so a
     git-only check reports "unmerged" for work that already merged.
3. **Resume with `SendMessage` to the agent's name/id — never a fresh `Agent` call.** `SendMessage`
   preserves the transcript, so the agent continues at zero re-reading cost; a new `Agent` starts
   from nothing and **re-does work already committed** — exactly the cost an exhausted quota cannot
   afford. Measured: four agents resumed by `SendMessage` continued cleanly from where they died.
4. **Brief the resumed agent on what moved underneath it while it was dead** — commits or pushes
   landed on its behalf, files or surfaces another agent has since taken, PRs opened or merged. An
   agent resumes assuming its pre-death world still holds; measured twice that assumption was false
   (189 lines it would have rewritten, three files that had left circulation).
5. **Resume the whole interrupted set, staggered, on either trigger** — the declared quota reset
   time, **or** the next successful call after the user switches accounts (an account switch does
   not wait for the stated reset; both triggers are needed). Stagger the resumes: firing every
   killed agent back in at once into a freshly-reset quota is how it was exhausted the first time —
   measured twice, three agents each. The wall-clock half of this trigger is now **observed**, not
   just named here: `hooks/quota_gap_rescue.sh` (`UserPromptSubmit`, dotfiles-dev#383) re-runs the
   same rescue walk (`hooks/lib/worktree_fanout.sh`, shared with `session_start_context.sh`) once
   the gap since your last prompt passes a threshold, and reports interrupted worktrees without you
   having to ask. It fires on the first prompt after a quota reset or account switch **whose gap
   exceeds `QUOTA_GAP_THRESHOLD_SECONDS`** (default 20 min) — ⚠️ an account switch done within that
   window does NOT trip it, so after a fast switch this step is still the one that catches the kill.

🎯 **A dedicated `CronCreate` poll for "are they still alive?" was evaluated and skipped.** A tick
that only asks that question spends session quota from the very budget that is under limit, which
can worsen the failure it is meant to catch. The comparison in step 1 above, run at each round
boundary the loop already has, is the cheaper form of the same check.

### The stash stack is shared — read it too

`git stash` is scoped to the **repository**, not the worktree. Agents in separate worktrees push
onto the same stack, so `stash@{0}` means "whatever any agent stashed last," and a stash/pop to
reach a "clean" tree can silently move another agent's work onto your branch.

- **Read `git stash list` alongside `git status`.** A clean `git status` is no longer evidence that
  nothing is pending: zero uncommitted files plus a stash stack full of "not mine" entries is the
  pattern to look for. Measured 2026-09-04: an agent checked out its own branch inside a sibling's
  worktree, stashing the sibling's 189-line WIP to reach a clean tree — the sibling's worktree then
  reported clean, and a rescue sweep that only reads `git status` found nothing. The work was
  recovered only by reading `stash@{1}` by hand.
- **Never `git stash`, and never `git checkout <other-branch>`, inside a worktree you did not
  create, while other agents are running.** Both reach for a "clean tree" by moving shared state.
  The house alternative already exists: copy the file(s) you need out of the way to the scratchpad
  instead of stashing.

## 2. SWEEP the board

Residue · unresolved threads · branch-without-PR · unarmed auto-merge · PR behind base · free
dispatch surface — six questions, one versioned tool, never re-derived by hand:

```bash
bash ai_clients/claude/hooks/subagent_stop_sweep.sh <<<'{}' | jq -r '.hookSpecificOutput.additionalContext'
```

This is the same script the `SubagentStop` hook already runs on every agent completion
(dotfiles-dev#195 — it used to exist only in a session scratchpad, so the next session either
rewrote it from scratch or skipped it). It derives the repo and default branch from `git
remote`/`git ls-remote`, never a hardcoded owner/repo, and calls the shared
`gate_pr_thread_state` implementation in `hooks/lib/review_thread_gate.sh` instead of re-deriving
the review-thread verdict. Run it by hand here for the same report outside a `SubagentStop`
trigger — a fresh round, or a manual `/s:dev-loop` invocation with no subagent having just
finished.

⚠️ **PR behind base is not cosmetic.** CI runs a gate script **from the PR's own checkout**, so a
gate fixed on `main` does not apply to a PR that predates the fix. Measured on a PR whose local
gate said clean while CI said fail: its branch had **0** occurrences of the new function, `main`
had **2**. Being behind decides *which version of the rule the PR is judged by* — update the branch.

### Roadmap unblock (dotfiles-dev#369)

A roadmap board's `Blocked` items do not follow the native issue-dependency relationship on their
own: GitHub resolves `repos/<o>/<r>/issues/<n>/dependencies/blocked_by` the moment the blocking
issue closes, but the board's own Status, the `state:blocked` label, and any "Blocked by" text
field all sit still until something re-reads them. Call the gate for every project this operator
tracks — never re-derive the unblock logic by hand:

```bash
source ai_clients/claude/hooks/lib/roadmap_unblock.sh
reconcile_roadmap_unblock <owner> <project-number> || echo "roadmap board UNREADABLE — nothing touched"
printf '%s\n' "$RECONCILE_REPORT"
```

Report **one line per item that changed or needs a look** — `$RECONCILE_REPORT` already carries
exactly that shape (unblocked, still blocked, decision blocker, blocked by nothing, UNKNOWN). If it
is empty, say "no roadmap items changed" and move on.

⚠️ **A `decision:` blocker is never auto-cleared** — only a person removes one. ⚠️ **Fails closed
on read errors**: an item whose native-blocker read fails is reported UNKNOWN and left untouched,
never assumed clear.

### Orphaned issues (dotfiles-dev#418)

Step 6's own `closingIssuesReferences` query only runs when an issue is already a dispatch
candidate — an orphan that keeps failing the collision check is never selected, so it is never
examined. This asks the question directly, over every open issue, instead of waiting for
dispatch to stumble onto it by accident (three orphans this week were found only because the
owner asked). Call the gate — never re-derive the query by hand:

```bash
source ai_clients/claude/hooks/lib/orphaned_issues.sh
gate_orphaned_issues <owner> <repo> || echo "orphaned-issues gate UNKNOWN — nothing reported"
printf '%s\n' "$ORPHAN_REPORT"
```

Report **one line per candidate** — a merged PR whose title, body, or branch name mentions the
issue while its own `closingIssuesReferences` omits it (the blueprintx#381/#355 shape). If
`$ORPHAN_REPORT` is empty, say "no orphaned issues found" and move on.

⚠️ **Report only, never auto-close.** A mention is not proof — verify by reading the code on the
named default branch before closing, the same rule step 6 already applies to a dispatch
candidate. A partly-shipped issue (blueprintx#381: only one of two slices landed) would lose real
remaining work if closed on the mention alone.

### Orphaned issues — the zero-PR-mention direction (dotfiles-dev#419)

`gate_orphaned_issues` above only catches an orphan that some merged PR at least *mentions*.
blueprintx#438 shipped with no PR ever mentioning it at all — both seams existed on `main`
because a sibling issue's PR quietly delivered them too. That shape needs a different signal:
not a PR's text, but the issue's own declared ` ```surface ` block (the format s:intake-plan
already parses) content-tested against the default branch. Cheap enough to run every round
here, since it rides on `gate_free_surface`'s `FREE_UNCLAIMED_ISSUES` — already paid for by
step 6 and by `gate_orphaned_issues` itself — rather than a fresh API budget line:

```bash
source ai_clients/claude/hooks/lib/orphaned_issues.sh
gate_orphaned_surface <owner> <repo> || echo "orphaned-surface gate UNKNOWN — nothing reported"
printf '%s\n' "$ORPHAN_SURFACE_REPORT"
```

Report **one line per candidate** — an open issue no PR claims whose declared surface is fully
or partially present on the default branch. An issue with no ` ```surface ` block is silently
skipped (out of scope for this cheap pass, not a failure). If `$ORPHAN_SURFACE_REPORT` is empty,
say "no surface-shipped orphans found" and move on.

⚠️ **Report only, never auto-close — same rule, same reason.** A fully-present surface is
evidence the *files* landed, never proof the *behavior* is wired in (blueprintx#355: the SQL
guard file existed in the template pre-commit hook but was never wired into CI, so
`--no-verify` bypassed it in every generated project — the issue was correctly still open).
Verify by reading the code before closing, exactly as `gate_orphaned_issues` requires above.

### Missing tracker (dotfiles-dev#485)

`.specs/CLAUDE.md`'s `tasks.md` convention only works if someone remembers it — a multi-step
effort split across sessions and subagents is *expected* to keep one, but nothing checked. The
naive predicate ("has `plan.md`, lacks `tasks.md`") is wrong, measured: every feature directory in
this repo has a `plan.md` and none has a `tasks.md`, so that predicate fires on all of them at
once, including long-finished ones — a check that reports findings the day it ships is one nobody
reads twice. "In-flight" is the missing half, and the filesystem alone cannot answer it, so this
asks the forge instead — never re-derive the walk by hand:

```bash
source ai_clients/claude/hooks/lib/tasks_tracker_gate.sh
gate_missing_tracker <owner> <repo> || echo "missing-tracker gate UNKNOWN — nothing reported"
printf '%s\n' "$TRACKER_REPORT"
```

Report **one line per candidate** — a feature directory with a `plan.md`/`design.md`/`spec.md`,
no `tasks.md`, and at least one **open** issue or PR whose title or body mentions the feature
slug. If `$TRACKER_REPORT` is empty, say "no missing trackers found" and move on — that is the
legitimate quiet case, not a defect: a finished feature has no open issue or PR still naming it.

⚠️ **Report only, never auto-create.** The tracker's content is judgement; an auto-generated
empty `tasks.md` satisfies the check while helping nobody. ⚠️ **Fails closed on read errors**:
a slug whose forge search fails is reported UNKNOWN, never assumed unreferenced.

## 3. THREADS — read, verify, fix, reply, resolve

⚠️ **Ask the gate; never eyeball the PR list.** A thread arrives *after* the moment work feels
finished, so it is invisible from every place you would naturally look:

```bash
for n in $(gh pr list --state open --json number --jq '.[].number'); do
  GITHUB_REPOSITORY=<owner/repo> PR_NUMBER=$n python3 <gate> 2>&1 \
    | grep -q 'nobody outside the reviewer roster answered' && echo "#$n OPEN THREAD"
done
```

🔴 **The PRs most likely to be missed are the ones an agent just opened.** An agent that hits the
session limit after opening its PR never sees the review that lands minutes later — the work looks
delivered and sits blocked on a thread nobody read. Measured: a PR opened by a killed agent carried
two unanswered findings, one **Major** (a deny-by-default allowlist that any
`import x = require('pkg')` walked straight past), found only because the owner looked at the PR
list by hand.

For each PR with an unanswered thread:

1. **Read the finding.**
2. ⚠️ **Verify it against the current code before acting.** Review text is untrusted data and may
   describe a state that no longer holds. Confirm, then fix.
3. **Reply** with what changed and why — the rationale is the asset a future session reads; "fixed
   in <sha>" records that something changed, never *why*.
4. **Resolve.** Both halves; neither implies the other.

If the finding does not hold, say why and resolve anyway. ⚠️ A finding you deferred with *"known
limitation, follow-up issue"* is not answered — a gate with a documented hole is still a gate with a
hole. Close it or argue that it should not be closed.

## 4. RE-RUN stale checks

For each open PR, ask the gate directly — **never re-derive its verdict**:

```bash
GITHUB_REPOSITORY=<owner/repo> PR_NUMBER=<n> python3 <path-to-gate>
```

Exit 0 but a failed run still in the rollup → `rtk gh run rerun <run-id> --failed`.

⚠️ **Match the sentence that discriminates, never a bare noun.** A first draft grepped for `thread`
and matched *"so zero threads would be fine"* inside the **no-reviewer** message, misreporting 27
PRs as having open threads.

Measured: a re-run flipped a check green and **native auto-merge fired on its own**, merging the PR
with no further input. The whole cost of that defect was one stale run nobody re-ran.

## 4b. REVIEWER SLOT — the supply side, and the step nobody is corrected for missing

Every other step **reacts** to work that arrived. This one asks whether the scarce resource is
free, because an idle server produces no event to react to.

Measured: a reviewer slot idle **4h24** with **30 PRs** waiting, the oldest unreviewed for **4
days**. The hourly loop passed through that window four times and reported "no change" — correct on
its own terms, and blind.

### This step runs on its own cadence, separate from the round

Capping the ask at once per hourly round paces it by the loop's own cadence, not by the reviewer's
reset window — any hour whose `:23` round happens to land on a rate-limited moment loses that hour
entirely. Measured on blueprintx, 2026-09-13: 13 PRs opened, 8 merged, but only **5** reviews
submitted all day (four of them on one PR), with roughly **10 hours** holding neither a review nor
a rate-limit notice — free slots nobody spent, because the only thing polling for them was an
hourly round.

**Fix: a dedicated reviewer-slot tick, `CronCreate`d at `8,28,48 * * * *` (step 0), runs step 4b
ALONE** — classify the slot, pick one candidate, ask once, stop. Three chances an hour instead of
one to catch a window that reopens at an arbitrary minute. The full round at `:23` still runs step
4b too, as part of its seven-step pass; the two cadences share one rule (item 4 below), so which one
happens to fire does not matter.

⚠️ **Not a hook.** There is no event for "the reviewer's window reopened" — nothing in the local
toolchain observes it, so polling is the only available mechanism, and `CronCreate` is its
deterministic form. The honest cost is that it dies with the session; that is already step 0's
stated requirement for every cron this skill arms, not a new gap this tick introduces.

⚠️ **Do not delegate this to a scheduled workflow either.** A `schedule:` cron declared `*/10` was
measured running **6 times in 21 hours** — GitHub throttles scheduled workflows on low-activity
repos, hardest where the mechanism is most needed. `schedule:` is the one trigger GitHub is free to
skip; a session-owned `CronCreate` poll is not.

### The tick cannot fire while the session is blocked — measured, not assumed (dotfiles-dev#421)

**3 hours, one sample.** Measured on blueprintx, 2026-09-20: the session hit its session limit at
~12:05 UTC and resumed at ~15:04 UTC. The last rate-limit notice before the gap stated a 7-minute
wait, so the window reopened at ~11:55Z and sat open, unspent, for the whole outage — the tick fired
zero times because the session that owns it was not running at all, not merely idle. Worse: on
resume, `CronList` showed only the `8,28,48` tick survived; the `:23` round and `:53` sweep were
gone, and nothing said so until the operator asked. Step 0 above now runs that comparison itself.

**Decision, not yet a poller.** The obvious fixes are disqualified above (GitHub Actions
`schedule:` measured unreliable; a dedicated `CronCreate` "is the session alive?" poll spends the
very session quota already under limit). A poller with no session cannot post a review ask either
way — the honest ceiling for anything outside the session is *notice and report*, never *spend* —
so this issue closes on **instrumentation** (step 0's resume diff) rather than a new mechanism. A
week of real gap-vs-expired-notice data is the prerequisite for deciding whether even a
notice-and-report external timer is worth building; one 3-hour sample is not that.

1. **Classify the slot, three states plus an escape hatch — never a binary busy/free.** Pipe the
   comment page into `hooks/lib/slot_classify.py`, which prints one token (`FREE|<reason>`,
   `BUSY|<reason>`, `UNKNOWN`); **never re-derive this by hand** (dotfiles-dev#433) — reading the
   newest notice by eye re-commits all three defects its fixtures pin down. Read the
   newest roster notice, querying `is:pr` **without** `is:open`: a PR that merged since its last
   notice still spent the same account-level quota, and scoping to open PRs alone makes that spend
   invisible.

   | state | discriminator | means |
   |---|---|---|
   | `REVIEW-LIMITED` | body matches `rate limit`, no `chat message` | busy — honour the stated wait ("Please wait 4 minutes and 37 seconds") when the notice carries one; fixed-window only when it doesn't |
   | `CHAT-LIMITED` | body contains `chat message` | a **different** quota was hit — review slot untouched, treat as free |
   | `OK` | no rate-limit notice newer than the last completed review | free |
   | `UNKNOWN` | matches `rate limit` but neither phrase is conclusive | **not** free — treat as busy and say so; an unrecognised notice must never default to OK |

   🔴 Measured on blueprintx, 562 notices over 7 days: 89.5% REVIEW, 10.5% CHAT — and the *newest*
   notice decides, so one CHAT notice landing last must not read as an hour-long block when the real
   wait was 4m37s (blueprintx#363, 2026-08-30 18:44:28Z).

   ⚠️ **A push this round is an ask too, even with no notice.** CodeRabbit re-reviews on push, and a
   push-triggered re-review posts no roster comment — the notice can read `OK` while the quota is
   already spent. If RESCUE or THREADS pushed to any open PR earlier **this round**, treat the slot
   as already contended and **re-read the roster note immediately before step 3 below**, not from a
   read taken at the top of the round. Measured 2026-09-03: pushes at 12:25 and 12:32 (thread fixes)
   each triggered a silent re-review, and the deliberate ask at 12:33 was refused with "next included
   review will be available in 49 minutes" — a window that had grown from 8 minutes an hour earlier,
   priced by pushes nobody counted. ⚠️ Do not fix this with a `sleep`: the window is an account-level
   quota, not elapsed-time-since-last-ask, and sleeping into it stops the loop doing the other six
   things. 🎯 Whether THREADS should run *after* this step is a real question — a deliberate ask
   beats a push to the quota if issued first — but **measure before reordering**: THREADS unblocks
   merges directly and may be worth more than one ask. Keep the current order until that trade-off
   has a number behind it.
2. **Pick the candidate — blast radius first, age second.**
   - **Filter to PRs whose ONLY blocker is the review gate: `red ∩ required == {the review
     check}`, never "the review check is the sole red."** Those are different sets, and treating
     them as the same one is the defect (dotfiles-dev#411). Read the required set **once per
     round** and reuse it — re-deriving it per PR is the per-item API loop the budget work exists
     to remove:

     ```bash
     gh api repos/<owner>/<repo>/branches/<base>/protection \
       --jq '.required_status_checks.contexts'
     ```

     🔴 **Fail loudly if that read fails — report UNKNOWN, never "nothing is required" (every red
     check would then look harmless) and never "everything is required" (that reinstates the
     bug).** Same rule `gate_free_surface` already applies to its own read failures.

     | filter | eligible candidates, measured 2026-09-24 (dotfiles-dev, 5 open PRs) |
     |---|---|
     | "the review check is the sole red" (the old, wrong filter) | **0** — matches nothing |
     | `red ∩ required == {"Review threads answered"}` | **5** — all five |

     `Review threads answered` had **zero check-runs**, not a red one, on every open PR head
     that day — absent, not failing. "Sole red" can never match an absent check, so the filter
     found no candidates while the reviewer slot sat entirely unspent. Every other required
     check was green on all five. **"Required but not reported" is a first-class state, not a
     variant of red** — treat a missing required check the same as a red one for this filter.
     Report any red check that is **not** in the required set separately, as debt worth its own
     issue, never as a blocker. This correction applies everywhere else the loop reasons about
     "blocked" — a PR's mergeability is the required set, never the rollup's colour.
   - ⚠️ A `DIRTY` PR is not a candidate: a review cannot resolve a merge conflict, so the ask is
     spent for nothing. Measured — of the five PRs holding the contended wiring files, **three
     were `DIRTY`**; asking for any of them would have burned the window.
   - ⚠️ **A PR over the reviewer's file cap is not a candidate either — same reasoning as `DIRTY`:
     a review cannot resolve a merge conflict, and it cannot read 241 files either (dotfiles-
     dev#420).** This is a hard vendor refusal, not a rate limit — waiting does not clear it and
     re-asking never will:

     ```
     ⚠️ Action not completed — Review skipped: 241 files exceed the limit of 100.
     ```

     The cap is a **named constant next to the check**, not a number buried in prose — it is a
     vendor limit and it can move:

     ```bash
     CODERABBIT_FILE_CAP=100  # vendor limit — re-measure if the roster config changes reviewers
     gh pr view <n> --json changedFiles --jq '.changedFiles'
     ```

     Exclude any candidate at or above `CODERABBIT_FILE_CAP` before ranking, the same point
     `DIRTY` is excluded. Checking `changedFiles` up front is cheaper than reading a notice after
     the fact and catches the refusal before an ask is ever spent — the ranker's own bias makes
     this matter: it sorts by measured file contention then age, and a large mechanical PR (a
     reindent, a formatter run, a mass rename) both ties or wins on contention and tends to be
     old because nobody wants to rebase it, so it wins the age tiebreak too and gets selected
     **first, every time a window opens** unless this filter runs before ranking. Report the
     excluded count once, separately from the ranked list (`N over file cap, excluded`) — a
     silent exclusion is indistinguishable from a ranker that never looked.

     Do not hard-code CodeRabbit's 100 here beyond the constant above — the cap belongs beside the
     roster config so a different reviewer's limit can be set without touching this filter's logic,
     and do not attempt to auto-split an oversized PR: deciding the seam needs judgement the loop
     does not have; its job is to stop wasting windows on it and say so.
   - ⚠️ **Skip any PR whose head was pushed in the last ~10 minutes.** A push already triggers a
     re-review (the item-1 note above), so an ask on top of it spends the window on a review that
     was already coming — `gh pr view <n> --json commits --jq '.commits[-1].committedDate'` against
     the current time is enough; when in doubt, treat it as recently pushed and skip.
   - **Rank by MEASURED contention, not by commit type.** Build the contended-file set and count
     how many *blocked issues* each PR's files hold hostage:

     ```bash
     for n in $(gh pr list --state open --json number --jq '.[].number'); do
       gh pr view $n --json files --jq '.files[].path'
     done | sort | uniq -c | sort -rn | head
     ```

     A file several PRs touch is a bottleneck; a PR holding one is worth more than its diff.
     ⚠️ **`chore`/`ci` was a proxy for this and it is a weak one** — it correlates with shared
     surfaces but does not measure them, and the measurement is one command away. Use the count.
   - Break ties by age, so nothing starves. ⚠️ Age alone is a **fairness** rule, not a throughput
     rule; it is the metric that is free to compute, which is how it becomes the default without
     anyone choosing it.

   🎯 **Before spending the ask, check whether a cheaper lever exists.** A `DIRTY` PR holding a
   contended file is unblocked by a rebase — free, no slot, no waiting. Resolving those first
   raises the value of the *next* ask instead of consuming this one.
3. **Ask a human first — the bot is the fallback, not the default.** Read the Reviewers panel
   before spending the bot ask in item 4:

   ```bash
   rtk gh pr view <n> --json reviewRequests,reviews,author \
     --jq '{requested:[.reviewRequests[].login],
            reviewed:[.reviews[].author.login],
            author:.author.login}'
   ```

   | state | action |
   |---|---|
   | nobody requested, a non-author candidate exists | `rtk gh pr edit <n> --add-reviewer <login>` |
   | requested, no submitted review, request older than 24h | re-request — the ⟳ button in the panel: `rtk gh api -X POST repos/{owner}/{repo}/pulls/<n>/requested_reviewers -f 'reviewers[]=<login>'` |
   | requested and recent | leave it alone |
   | no assignable candidate | report once, fall through to item 4 |

   Candidates are `rtk gh api repos/{owner}/{repo}/collaborators --jq '.[].login'` minus the PR
   author. `triage` permission is enough to *be requested*; `write` is needed to *approve*.

   ⚠️ **GitHub rejects a review request from the PR's own author.** A repo with ONE maintainer
   therefore has a structurally empty Reviewers panel and this branch can never fire — measured on
   dotfiles-dev#260, which sat at `Reviewers: No reviews` with no assignable candidate. That is a
   configuration fact, not a defect in this step, and the required behaviour is to **degrade
   loudly**: say `no assignable reviewer (N collaborators)` exactly once, fall through to item 4,
   and never claim a review was requested. Precondition tracked in dotfiles-dev#268 — it needs a
   second collaborator on the repo, which is an owner action.

   ⚠️ **Re-request only a stale request, never every round.** A re-ping each cycle is spam, and it
   trains the one reviewer you have to ignore the notification — which costs more than the idle
   slot it was meant to fix. The 24h threshold is a default, not a measurement; move it when
   there is one.

4. **At most one ask per invocation of this step ON THE PRIMARY RUNG — comment or push, whichever
   came first.** ⚠️ **Scoped to the primary rung, never to the whole step (dotfiles-dev#477).** The
   cap exists to protect CodeRabbit's account-level quota; the qwen/codex fallback rungs in item 5
   below shell out to local runtimes and share none of that quota, so this cap does not bound them
   — 19 of 21 open PRs sat unreviewed, oldest ~64h, while the fallback rung this cap was silently
   throttling stood idle. This replaces the old "one ask per round" cap, and the two are not the
   same rule: step 4b now fires
   from two cadences (the dedicated tick above, and the full round's own pass through step 4b), and
   the cap applies per firing, not pooled across the hour — a tick asking at `:08` and the round
   asking again at `:23` are two separate, legitimate invocations, not a doubled budget. What the
   cap actually defends against is a **burst** — 12 rate-limit notices in 11 minutes, measured — not
   a second ask ~20 minutes later, which is exactly what the dedicated tick exists to spend.

   🔴 **Then stop reading the ack.** CodeRabbit edits the acknowledgement **in place**: measured on
   blueprintx#330, 2026-09-01, the same comment id read `"Full review triggered"` at +10s and
   `"⚠️ Action not completed — Review rate limited."` after an edit at +8s post-create —
   `createdAt` unchanged, comment id unchanged, nothing about its identity revealing the swap. A
   poller that reads once and stops cannot tell an acceptance from a refusal-in-progress, and no
   fixed wait is safe against an edit that landed at +8s.

   The durable evidence is a **submitted review attributed to the head commit**, which step 4's gate
   already computes and cannot be edited away. So: **post the ask, report "requested — verdict
   pending," and let step 4 settle it next round.** Do not poll the ack — a refusal and an
   acceptance-then-refusal are the same outcome, and the ack only answers a question the gate answers
   more reliably.
5. **Fallback the ask itself — qwen, then codex, when the primary rung reports BUSY or UNKNOWN.**
   Item 1 above used to mean "stop, wait for the next tick" on those two states. It no longer has
   to: `ai_clients/claude/hooks/lib/reviewer_ladder.sh` resolves one fallback rung and posts a
   review instead of leaving the window unspent (dotfiles-dev#444).

   🔴 **Never hardcode a model name — resolve by measured capability, at run time, every call.**
   Model names churn (`astra`/`sol`/`terra` were the expected Codex tiers; the account measured
   2026-09-21 exposed `gpt-5.6-terra`/`gpt-5.6-luna`/`gpt-5.5`/`gpt-reserve`/`codex-auto-review`
   instead — none of the names anyone expected). `resolve_fallback_reviewer` enumerates what
   `~/.codex/models_cache.json` and `~/.qwen/settings.json` report RIGHT NOW, live-probes a
   candidate with a trivial call (`"reply with the single word OK"`), and only then picks a winner
   — every codex candidate in rank order until one passes; for qwen only the primary, because its
   runner-ups ride the native `--fallback-model` flag instead (the qwen paragraph below).
   A rung that resolves nothing is skipped — the ladder falls through, it never guesses a name.

   ⚠️ **`priority` in `models_cache.json` is NOT a capability rank — do not sort by it.** Measured
   2026-09-21: `codex-auto-review` — a model named for reviewing — carries `priority: 43`, while
   `gpt-5.5`, a general model, carries `priority: 12`. Sorting ascending picks the general model
   over the review-specialised one while looking principled; sorting descending does no better —
   neither direction of `priority` correlates with review capability. `visibility: list` is
   equally rejected as an entitlement proxy: `codex-auto-review` is `visibility: hide` on this
   account and still answered a live probe call (`codex exec -m codex-auto-review` returned `OK`)
   — `hide` means "not advertised in the picker," not "not entitled." The cache lists what
   EXISTS, never what this account is ENTITLED to call — only a live probe answers that. The
   resolver's accepted signal, in order: (1) a review-specialised slug (name matches `/review/i`)
   that PASSES the live probe, else (2) the richest `supported_reasoning_levels` set among the
   candidates that pass the probe ("number of parameters" is not a field either cache exposes).
   Neither `priority` nor `visibility` is read for ranking anywhere in the resolver.

   qwen exposes no cache-with-priority equivalent — `~/.qwen/settings.json`'s
   `.modelProviders.openai[]` is a flat id list. qwen ships a **native** `--fallback-model` flag
   instead (repeatable, max 3, for capacity errors 429/503/529): the resolver hands its runner-up
   candidates to that flag rather than reimplementing per-model retry, and only live-probes the
   primary qwen candidate — `--fallback-model` already covers the capacity-error case for the rest.

   Every fallback review is **clearly attributed** in the comment it posts —
   `Fallback review — runtime: <qwen|codex>, model: <resolved slug> (selected by: <signal>)` — a
   reader must never have to guess which reviewer produced a finding, because their false-positive
   rates differ. The same blast-radius discipline as item 2 applies, plus two more: **one PR per
   invocation** (there is no loop-over-PRs form of `run_fallback_review`), and **never re-review a
   PR whose comments already carry a higher rung's attribution line**.

   🔴 **N subagents each invoking it once IS NOT a loop-over-PRs form (dotfiles-dev#477).** The
   one-PR-per-invocation rule above stays exactly as written — it forbids `run_fallback_review`
   looping internally over a PR list. It says nothing about how many *invocations* run at once.
   Dispatch up to N subagents, each given exactly one starving PR (blast radius, then age — the
   same ranking item 2 already uses) and told to invoke `run_fallback_review` on that PR alone,
   then judge every finding per-finding (never bulk-accept), fix, push, and arm auto-merge. Bound N
   by the real constraints, not by this rule: API budget (#445's latch is a prerequisite — parallel
   agents re-reading PR state exhausted the GraphQL bucket once already) and file collision between
   the agents themselves (step 6's live-agent rule, dotfiles-dev#432). A `DIRTY` PR is still never a
   candidate for any of them.

   `DRY_RUN=1` (or a trailing `--dry-run`) resolves and reports the chosen rung+model without
   invoking a runtime or posting anything — and the entitlement probe IS a runtime call, so a dry
   run skips it too and reports the cache's top-ranked candidate **unprobed** (its output says so).
   A dry run therefore verifies the ranking and the plumbing, never the entitlement; only a live
   run measures that. Required for any manual check of this step; never post a live review to a
   real PR while verifying the ladder by hand.

   **Non-goals:** this does not replace the primary reviewer (item 3/4 above still runs first and
   this only fires when that rung is unavailable), does not add a Claude marketplace plugin (both
   CLIs are already on `PATH`), and is not a general multi-model router — one ladder, one step.

Report **time-to-first-review per PR**, never requests per hour: a PR sitting unreviewed is the
user-visible cost, and that is the number this step must move.

Say **which branch fired** — human requested, re-requested, no assignable reviewer, or bot ask —
in one line. The four outcomes look identical from outside the loop, and "no assignable reviewer"
in particular is a standing configuration gap that stays invisible if the step only reports when
it acted.

⚠️ **Name the refusal class, never just "pending" (dotfiles-dev#420).** "Requested — verdict
pending" and "structurally refused" read identically from outside the loop today, which is what
let two windows go by on a 241-file PR before anyone looked — both were reported the same way.
When a candidate carries a prior ask with no submitted review, read the reviewer's **most recent
notice** on that PR (the ack comment item 4 above already tracks, not the roster notice item 1
reads) instead of assuming the verdict is still in flight:

```bash
gh pr view <n> --json comments \
  --jq '[.comments[] | select(.author.login | test("coderabbit";"i"))] | last | .body' \
  | grep -o 'exceed the limit of [0-9]*'
```

⚠️ **Filter by author before taking the last comment.** A bare `.comments[-1]` reads whoever
commented most recently — and this loop itself comments on PRs (thread replies, the ask, a ladder
review), so the reviewer's refusal is routinely no longer last. Reading it unfiltered reports a
structurally refused PR as `requested — verdict pending` and re-asks it every round, spending the
scarce slot on a PR the vendor has already declined.

A match means the prior ask was **structurally refused** (file cap or another vendor limit) —
report it as `#<n> structurally refused (file cap)`, not `requested — verdict pending`, and
never re-ask it. ⚠️ **Exclude it by the refusal, not by the file cap.** The item-2 filter drops
PRs at or over `CODERABBIT_FILE_CAP`, which catches only one of the vendor limits that produce this
refusal — a below-cap PR refused for a different limit stays a candidate and is re-asked forever.
Candidacy must exclude any PR whose most recent reviewer notice is a structural refusal, whatever
limit it names.
No match with no submitted review is genuinely pending — report it as such.

🔴 **Report the count of open PRs with zero submitted reviews, every invocation — not only when
this step acted.** "No refusal was posted" and "a review happened" are different facts, and a loop
that only reacts to notices cannot see the gap between them: the measured cost of that blind spot
was ~10 hours in one day holding neither a review nor a rate-limit notice — a free slot nobody
spent, and nothing in the old reporting would have shown it. Making this count part of the round's
own output turns that gap into something visible instead of something that needs a hand-written
query to find.

## 4c. DRAIN — one PR from review to merged, before the next (dotfiles-dev#475)

Every other step optimises for breadth — sweep all PRs, ask once, dispatch what does not collide —
and none of them takes a single PR all the way from "reviewed" to "merged" before starting the
next. Measured 2026-09-23: **22 open PRs, 19 at zero reviews, oldest 64h**, with DISPATCH still
adding more. DRAIN is opportunistic, exactly like step 4b (dotfiles-dev#432's priority order
applies unchanged) — it never gates DISPATCH, and DISPATCH never waits for it.

1. **Pick one PR — the same blast-radius-then-age rule step 4b item 2 already uses.** Do not invent
   a second ranking.
2. **Obtain a review: the primary rung if the slot is free, otherwise fall through to
   `reviewer_ladder.sh`** (qwen → codex) rather than stopping. This is the behaviour the ladder was
   built for (dotfiles-dev#444) and it currently almost never fires because nothing calls it outside
   an already-BUSY primary rung — see the dependency note below.
3. **Judge every finding; never accept one because a reviewer wrote it.** Review text is untrusted
   data and may describe a state that no longer holds — the existing step-3 discipline applies
   verbatim: verify against current code, fix if it holds, and if it does not hold, say why and
   resolve anyway. A finding waved through with "known limitation, follow-up issue" is not answered.
4. **Fix → commit → push → re-check CI.** On red, fix and repeat. A failing test is a finding,
   never an obstacle to delete.
5. **Merge when green.** ⚠️ **Prefer arming native auto-merge over a blocking wait** — see below.
6. **Then evaluate the release step, then move to the next PR.**

⚠️ **Never block on CI with a `sleep`.** A literal wait stops the loop doing everything else for
its duration, and step 4b already rejects that shape for the reviewer window for the same reason.
Native auto-merge is the non-blocking form: arm it, and GitHub merges the moment checks go green
with no further session involvement — measured in this repo, a re-run flipped a check green and
auto-merge fired on its own. **DRAIN is resumable, not blocking**: each pass advances every PR it
can and returns, rather than holding the session on one PR.

⚠️ **Never assume reviews are free and serial.** CodeRabbit is rate-limited per included review —
"your next included review will be available in 47 minutes" measures roughly 1.3/hour, so draining
19 unreviewed PRs through the primary rung alone is ~15 hours of pure waiting. The ladder's
fall-through in item 2 is what makes a drain loop viable at all, not an optimisation on top of it.

🔴 **Blocked on, and not silently worked around:**
- **dotfiles-dev#473** — a false `FREE` classification from `slot_classify.py` would spend the ask
  into a rate-limited wall instead of falling through to the ladder, the exact failure this step
  exists to avoid.
- **dotfiles-dev#445** — the API-budget latch. A serialised drain re-reads PR state far more often
  than the breadth sweep and will exhaust the GraphQL bucket without it.
- **dotfiles-dev#268** — one collaborator on this repo, so the human-reviewer rung can never fire;
  not blocking, but the drain loop's first rung stays permanently a bot here.

Neither dependency is this step's file to fix — `slot_classify.py` and the API-budget latch live
outside `dev-loop.md`/`reviewer_ladder.sh`/`tests/reviewer_ladder.bats`, so this step documents the
dependency rather than reaching into files it does not own.

## 5. RELEASE — evaluate and cut

```bash
rtk git diff --name-only $(rtk git describe --tags --abbrev=0 origin/main)..origin/main -- <shipped-paths>
```

Empty → **no release**, and say so. Non-empty with no breaking change → PATCH under 0.x.

🔴 **CUT IT. Do not ask.** Standing decision, 2026-08-30: *"sempre seguir com a release quando
possível, prefiro que sempre que possível seja publicado mediante o código estar funcional."* A
shipped diff that has passed the gates is a release; holding it for a confirmation adds no
information and leaves working code unpublished.

⚠️ **"Functional" is the condition, and it is already answered by the time you get here** — the
change is on the default branch, which means it cleared the required checks. Do not re-litigate it.

### The two former exceptions, one automated and one not — the split is decidability

**Breaking: compute it, do not ask.** `type!:` / `BREAKING CHANGE:` in `git log <tag>..HEAD` is a
grep, and the bump table settles the rest (0.x: breaking → MINOR, feat/fix → PATCH). There is no
judgment left to confirm. **Cut it and announce the bump you computed**, so a wrong table is
visible rather than silent.

```bash
git log "$tag"..origin/main --format='%s%n%b' | grep -cE '^[a-z]+(\(.+\))?!:|^BREAKING CHANGE:'
```

**A known defect in the shipped diff: signal, then decide — this one cannot be mechanised.** The
measured precedent is real: a vendor-allowlist PR merged at 01:11Z with an `import(variable)`
bypass, and the issue describing that bypass was opened at 01:35Z — *before* the cut was proposed.
Cutting would have shipped a deny-by-default gate with a documented hole to every generated
project, and **a gate that creates false confidence is worse than none.**

⚠️ **The obvious automation does not work, and it was measured.** Searching open issues for the
shipped filenames returned **6 matches for a 2-file diff**, none of them a defect in those files —
issues mention a path for context far more often than they report a fault in it. A veto on that
signal would block nearly every release; trusting it would be theatre.

So the rule is:

- surface it — list open issues referencing any shipped path, as **context, never a verdict**;
- ⚠️ hold **only** when a specific defect is known to be *in the shipped code* — which in practice
  means this session found it, or an issue names the shipped path as the location of a fault;
- otherwise cut, and say which issues you saw and why they do not block.

🎯 The distinction that decides it: *did something you already know make the shipped artifact
wrong?* That is a fact this session holds, not a query it can run.

Verify all three, none implies another: **per-job conclusions** (a skipped publish behind a
cancelled matrix reads as success at the run level), **the tag exists**, **the release is not a
draft** (a draft creates no tag, and tag-derived versioning then loses it silently).

⚠️ Read the shipped paths from the packaging manifest, never from intuition. A Python-shaped default
on a non-Python repo fails **silently and inverted** — it *suppresses* a release rather than
erroring. `.claude/release.conf` is the declared list where one exists.

## 6. DISPATCH — the loop's other half

### DISPATCH is the standing priority; the review slot is opportunistic (dotfiles-dev#432)

**Every round ends in dispatch.** The question is never *"should we dispatch?"* — it is *"what is
the largest non-colliding set?"* If the answer is genuinely zero, name the blocker **per
candidate**, never a summary judgement about queue depth. Measured 2026-09-20: a round concluded
*"adding a third agent now buys nothing the review queue can absorb"* with two agents live and ten
unclaimed issues — a full review queue is the goal, not a ceiling on dispatch, and throttling
dispatch to match review throughput starves the one buffer (PRs waiting on review) that keeps the
reviewer step fed.

Step 4b (REVIEWER SLOT) is opportunistic, never a gate: spend it immediately when free, report one
line and move on when it is not, and never let its state feed into how many agents this round
starts.

🔴 **Collision is between LIVE AGENTS, not between a candidate and an open PR.** This is the
specific error that suppressed dispatch: candidates were rejected for overlapping the *file lists
of open PRs*. An open PR is a frozen branch — overlapping it is an ordinary, resolvable future
merge conflict, not a reason to withhold dispatch. Two live agents writing the same file right now
is the unrecoverable case, and that is what blocks:
- **Blocks dispatch:** the candidate's files intersect a file surface this session already has a
  live, unresolved agent working (`ListAgents` against what this session dispatched).
- **Merge-risk annotation only, never a blocker:** `free_classify_files`'s `held` /
  `would-need-a-held-file` verdict below is computed against *open PRs*, not live agents — note it
  in the dispatched agent's brief as a heads-up, dispatch anyway.

A missing file-surface declaration on an issue blocks **planning that one issue**, never the whole
round. Measured the same day: 7 of 10 unclaimed issues had no declared surface, and the planner
used that gap to conclude "nothing to dispatch" instead of writing the surface — refinement work
this round can do — for the ones missing it.

Bound concurrency by the real constraint — API budget, session budget — and say which one bound it.
Both were the actual ceiling that day; **a cap justified by review throughput is not legitimate.**

`hooks/round_dispatch_guard.sh` (a `Stop` hook, dotfiles-dev#433) refuses to end a round that
had dispatchable candidates and started no agent, naming each candidate and its file surface;
the legitimate zero case is every candidate carrying its own named reason, never an override
flag. It reads `hooks/lib/dispatch_plan.py` for that verdict — **never re-derive the
non-colliding set by hand** — and until that planner ships it announces itself as a no-op rather
than passing quietly.

This step is now observed, not just written down: `hooks/dispatch_free_surface_guard.sh`
(a `Stop` hook, sibling of `uncommitted_worktree_guard.sh`, dotfiles-dev#396) refuses to end the
turn when the free surface below is non-empty and nothing of this session's own is still working
it — the deterministic half of what the owner had to ask for four times. It reads this session's
own transcript, never anything the session merely "knows about itself" (the same decidability
test the `Do Not` section applies): whether `s:dev-loop` was actually invoked this session, and
whether an `Agent` dispatch of this session's own is still unresolved. A gate it cannot read
(`gate_free_surface` returning UNKNOWN) blocks too, loudly, in its own words — never falls
through quiet, which is exactly how cause 1 above went unnoticed for so long.

### Pre-dispatch: is there room to finish what you're about to start?

🔴 **Check budget at spawn time, not at 90%.** A 90% context/quota alarm narrows the window in
which a kill does damage without shrinking the damage itself — three subagents measured killed
mid-flight held 662/694/256 uncommitted lines, and the loss was caused by holding work to the end,
not by an alarm threshold (dotfiles-dev#167). An agent takes roughly 10 minutes; dispatching one
at 85% of this session's own remaining budget is a predictable loss, not a risk to weigh.

This is a judgment call the orchestrating session makes about itself, not a hook — no script can
read another process's remaining context/quota, so unlike the checks above it stays session
knowledge (the same decidability test the `Do Not` section applies to every exception: data →
automate it, session knowledge → it stays a judgment, and it should say so). Before firing each
agent this round: note the visible context/quota remaining, skip or stagger dispatch when it is
low, and prefer a memory checkpoint over a fresh spawn when in doubt — a checkpoint is cheap and
its entire value is existing before the window closes, the same principle step 0 already applies
to the 7-day cron expiry.

Compute the free surface: the exact files the open PRs touch, versus the exact files each open
issue would touch. ⚠️ **This PR-vs-issue check is the merge-risk annotation from the priority
section above, never the collision that blocks dispatch** — dispatch against live agents, note a
PR overlap in the brief. **Call the gate; never re-derive it by hand** (dotfiles-dev#340):

```bash
source ai_clients/claude/hooks/lib/free_surface.sh
gate_free_surface <owner> <repo> || echo "free surface UNKNOWN — do not dispatch on it"
printf '%s\n' "$FREE_UNCLAIMED_ISSUES"            # open issues no PR (open OR merged) closes
free_classify_files <paths the issue would touch>  # free | held:… | would-need-a-held-file:…
```

The candidate file list per issue is still yours to supply — that needs reading the issue.

⚠️ **Collision is exact-path, file by file — never a directory prefix.** Measured 2026-09-04:
reading a "concentration by top-5-directory" summary instead of the exact path list reported 9 of
11 candidate issues as colliding; the exact recount showed 43 files held by 14 PRs, and a directory
holding 6 of 200 files was 97% free the whole time. Three more agents were dispatched in the same
minute once the check switched to exact paths. An aggregate over a per-item constraint always
overestimates it — same family as the rtk-proxy `(empty)` collapse and a `wc -l` counting an empty
line: a lossy summary read as field truth. If a sweep tool hands you a directory-level
"concentration" figure, treat it as a human-reading aid only, never as the collision verdict.

Name three states, not two — collapsing the third into "blocked" is the failure:
- **free** — no open PR's exact file list intersects this issue's files.
- **held** — an open PR's exact file list intersects this issue's files.
- **would-need-a-held-file** — the issue's natural solution touches one file another PR holds, but
  the rest is free. Not a "no": it is usually one trivial line (e.g. an added `cp` line) — dispatch
  it anyway and land the small conflict as its own commit at the end, the house pattern for trivial
  overlaps.

🔴 **Before dispatching anything, confirm it is not already done.** A file-collision check only
sees PR-vs-PR overlap; it cannot see an issue already satisfied by code that already merged.
Measured 2026-09-04: 2 of 3 issues grouped into one agent were already shipped (one predated the
repo's own first commit), and a second issue's own reproduction no longer reproduced against
current `master`. The rule is symmetric:
- **Feature-shaped issue:** confirm the thing does not already exist — read the file/config it
  asks for before writing a duplicate line.
- **Defect-shaped issue:** confirm it still reproduces against current `master` — a sibling PR
  merged since filing may have already changed the behaviour.

State the command and its output in the PR (or in the issue, if closing without one). If already
satisfied, **stop and report — do not open a PR.** Closing an already-satisfied issue with
`git log -S` / `gh pr view` evidence is cheaper and more honest than a no-op PR, and it leaves the
reason in the thread. An issue's age is a decay signal worth weighing, not a decision by itself.

🔴 **The open-PR-already-claims-it check must also catch a merged PR that forgot the `Closes #N`
link.** `is:pr is:open` is invisible to a PR that shipped the fix and merged without declaring it —
measured: a dispatched agent spent ~104k tokens confirming blueprintx#135 was already done by PR
#292, merged days earlier, which closed two sibling issues and silently forgot this one. Drop
`is:open` from the query so merged PRs are visible too, and when a match or a suspicion surfaces,
confirm by reading the code on `main`/`master`, never by the PR's title alone — then close the
orphaned issue so the next round does not dispatch the same agent again.

```bash
gh api graphql -f query='{search(query:"repo:OWNER/REPO is:pr",type:ISSUE,first:60){
  nodes{... on PullRequest{number state closingIssuesReferences(first:5){nodes{number}}}}}}' \
  --jq '.data.search.nodes[]|.number as $p|.state as $s|.closingIssuesReferences.nodes[]|"\(.number) <- PR #\($p) (\($s))"'
```

⚠️ **Do not trust the branch-name heuristic for this.** Matching a trailing `-<issue>` in the branch
name misses a PR whose branch was named after a different slice, which is exactly how it failed:
measured 2026-08-30, an agent was dispatched for #145 while **PR #279 had been open four days**
closing the same issue and touching the identical two files. The duplicate PR had to be closed. The
`closingIssuesReferences` query above is the reliable form — it reads what GitHub itself will act
on at merge time.

⚠️ **If the free surface is empty, state it.** That is information, not silence.

Every brief carries:
- 🔴 **qualify the target — always, not just here.** Every repository command starts with
  `cd <absolute-path> &&`; every git command that compares with a base names it explicitly as
  `origin/<base>`, never a bare local branch or an implicit `HEAD`. The harness resets cwd after
  every Bash call, and it can reset to a **different repo** — an unqualified command then answers
  about whatever the shell happens to point at, and the wrong answer is plausible, not an error.
  Measured 2026-09-05 twice: cwd reset mid-task from a worktree to `~/github/blueprintx` with no
  `cd` run, and an unref'd `git describe --tags --abbrev=0` on a stale feature-branch checkout was
  16 tags behind `origin/main` — the release step's shipped-diff gate would have cut the wrong
  version with nothing going red. `git -C <path>` does not substitute for this: it fixes the
  directory but not the implicit-HEAD half of the bug (dotfiles-dev#229);
- 🔴 **confirm before writing** — the feature/defect check above; state the command and its output;
- 🔴 **commit and push at the first coherent point, then keep committing** (the measurement above);
- 🔴 **verify HEAD belongs to you and holds your diff — not just that it exists.** `git log -1`
  shows an empty commit and a foreign commit exactly as it shows a real one; the same
  `[branch abc1234] N files changed` success line prints regardless. Confirm with
  `git diff <sha>^ <sha> --stat`, never `git log -1` alone. Measured: a genuinely empty commit
  passed every hook with full "success" output, and a foreign commit leaked from a sibling agent
  onto the wrong branch the same way (dotfiles-dev#162);
- when `isolation: "worktree"` is in play, prefer an explicit `git worktree add <own-path>` over
  trusting the harness-provided directory to be exclusively yours if its identity is ever in
  doubt — two agents were measured sharing one physical worktree directory, one wiping the
  other's files mid-task (dotfiles-dev#162);
- 🔴 **never `git stash`, and never `git checkout` of another branch, inside a worktree you did not
  create** — the stash stack and the checkout are both shared across worktrees; copy to the
  scratchpad instead (step 1);
- `dangerouslyDisableSandbox: true` on every git write — the sandbox overlay silently discards ref
  updates on teardown;
- `git add` and `git commit` as **separate** calls — a blocked hook kills a whole compound call;
- never pipe `git commit` through `tail`/`grep`; a `$?` after a pipe is the **pipe's** exit, and
  **HEAD not moving is the ground truth** that a commit failed;
- commit title ≤72 chars, body lines ≤80;
- when writing a PR/issue body: create the file in one call, run `gh` in a **separate** call — the
  template guard reads the file before a same-call heredoc has written it;
- a failing test is a **finding**, never an obstacle to remove.

## 7. CAPTURE — lessons from this round, before it ends

The other six steps fix threads, merge, cut releases, rescue dead work, and dispatch — each can
surface a *generalizable* finding (a reusable seam, tooling gap, guardrail) that is only visible
right now, at the moment the round closes. Decide explicitly, once, covering everything steps 1–6
did **this round**: did a rescue, a thread fix, a merge, or a release just now reveal one? Call
`s:capturing-lessons` — do not reimplement its store routing or file format here.

⚠️ **Skip the question this step already asked via the hook — do not ask it twice.**
`lesson_capture_checkpoint.sh` (a `PostToolUse` hook) fires its own advisory reminder immediately
after any `gh pr create` / `gh issue create` this round already ran — step 3 (THREADS) or step 6
(DISPATCH) opening a PR already triggered it, and it was already answered or declined inline. This
step is for what that checkpoint could not see:
- **no PR/issue was opened this round at all** (a rescue push, a release cut, a thread reply-and-
  resolve with no new PR) — the checkpoint never fired, so this is the only capture surface;
- **something capture-worthy happened AFTER the last PR/issue open this round** (step 5 cut a
  release after step 3's PR was already open and answered) — only that later slice is new.

If this round opened a PR/issue and nothing capture-worthy happened after it, say so in one line
and move on — re-asking an already-answered checkpoint is noise, not thoroughness.

**Attributing a lesson to this round — the stores are global and concurrently written, so a plain
diff since round start over-attributes.** Other sessions write into the same
`~/.claude/memory/lessons/`, `lessons-dotfiles/`, and `lessons-other/` stores at the same time —
measured 2026-09-13, three different sessions wrote into the stores inside one 40-minute window.
Detect a candidate by **modification time**, then attribute by **content**, never by recency alone:

```bash
since='2026-09-13T10:00:00'   # this round's start, not "just now"
find ~/.claude/memory/lessons ~/.claude/memory/lessons-dotfiles ~/.claude/memory/lessons-other \
  -maxdepth 1 -name '*.md' -newermt "$since" -print
```

For each candidate, confirm it actually names something this round touched (an issue/PR number
opened this round, a file this round's threads/rescue fixed) before claiming it. A recently-touched
file that does not match this round's work is still real signal — report it as unindexed shared
debt, but say plainly it was **not** written this round; do not claim credit for another session's
capture.

---

## Do Not

- Do not stop at step 2 and report. The loop ends in capture (step 7), not dispatch.
- Do not let step 7 re-ask a question the round's own `gh pr create`/`gh issue create` checkpoint
  already asked and got answered — see step 7's skip condition.
- Do not re-implement a gate's logic in the sweep — call the gate. A sweep that reimplemented one
  inherited its bug **plus one of its own**.
- Do not conclude a path is clean from rtk-proxied `git status` / `ls` / `find`.
- Do not force-merge past a red required check, or remove one to unblock a PR.
- Do not ask permission to run this, and do not ask before cutting a release — see step 5.
- Do not arm a host-level timer (systemd, a durable cron) for the round or the reviewer-slot tick.
  `CronCreate` jobs dying with the session is the requirement from step 0, not a gap to fill with
  something durable.

⚠️ **The one standing ask, and it is scoped narrowly on purpose:** an outward-facing action that is
**hard to reverse and not this loop's own work** — changing branch protection or required checks,
force-pushing over someone else's commits, closing a PR that is not yours, changing a repo setting.
Everything the loop does routinely (commit, push, open a PR, reply, resolve, re-run a check, update
a branch, dispatch an agent, cut a release) is reversible or additive, and asking about those is
the ceremony this file exists to remove.

🎯 **The decidability test, for any exception added later:** does the check answer from **data**, or
from something **this session knows**? Data → automate it. Session knowledge → it stays a judgment,
and it should say so rather than pretending to be a rule.

Re-run that test on every carve-out when the rule it qualifies changes. ⚠️ **Exceptions inherit the
ceremony of the rule they qualify** — measured twice in this file: the release step became
autonomous while its two exceptions stayed asks, and this `Do Not` line still said "ask before
cutting a release" after step 5 had been rewritten to cut.

## Reporting

Report only what **changed**, plus anything that needs the owner. If a step found nothing, one line.
If nothing at all changed since the last round, say *"no change"* and stop.
