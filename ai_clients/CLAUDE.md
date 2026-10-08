# ai_clients/CLAUDE.md

Context for creating or editing anything inside this directory.

## What this directory is

Source tree for AI client configurations. `make ai_clients` runs
`ai_clients/claude/main.sh`, which copies files from this tree into
`~/.claude/` via the lib scripts in `ai_clients/claude/lib/`.

⚠️ **True for files, not for `settings.json` keys.** `configure_settings()`
merges source into `~/.claude/settings.json` with `jq '. * $base'` —
additive only. It updates a key source defines but can never remove a key
that exists only live, because a merge never deletes. Deleting an entry
from source is therefore a no-op against the live file until the `prune`
step's `prune_settings_keys()` (`lib/prune.sh`) explicitly removes it —
and that function only touches the specific, fully source-owned subtrees
named in `SETTINGS_PRUNE_KEYS` (`enabledPlugins` today), never a blanket
diff, so machine-local keys the additive merge exists to protect still
survive (dotfiles-linux-dev#272).

`ai_clients/claude/`, `codex/`, `qwen/`, `copilot/`, and `kimi/` are wired up
today (dotfiles-linux-dev#346). A new client follows the same pattern: add
`ai_clients/<name>/main.sh` and it is auto-discovered by `ai_clients/main.sh`
— `claude/main.sh` is the full model (settings, plugins, marketplaces, prune,
…); `codex/main.sh` is the small model, and `qwen/`, `copilot/`, `kimi/` are
smaller still (a single step: deliver the shared AGENTS.md).

## Permissions model (`claude/settings.json`)

`defaultMode` is `auto` — the auto-mode classifier decides every command not
covered by `allow` or `deny` (dotfiles-linux-dev#644, owner decision 2026-10-04).
The buckets: read-only / reversible → `allow` (no prompt, no classifier call);
secrets + `rm -rf ~|/` + `chmod -R 777` → `deny` (hard block, always wins);
everything else, `git push` / `gh pr merge` / `sudo` / installs included → the
classifier. **`ask` is deliberately `[]`:** every `ask` rule *overrides* auto mode
("Ask rule … overrides auto mode for this command"), and 72 of them made routine
`python3` / `rm` / `cp` prompt constantly. Keep the key present and empty — the
deploy merge (`jq '. * $base'`) replaces the live array only when source defines
it, so deleting the key would leave the old live list in force. The contents are
self-documenting in the file; the non-obvious points below are **not**, and a
future audit must not relitigate them (dotfiles-linux-dev#68, #644):

1. **Dual-list every git/gh entry in bare AND `rtk` form.** The `rtk hook claude`
   PreToolUse hook rewrites `git …` → `rtk git …` at execution, but the model is
   told to *write* the `rtk` prefix, so the `rtk`-form entry is the one that
   matches; the bare form is a fallback. A wrong-form entry fails **silently** — it
   just keeps prompting — so add both forms.

2. **Keep `deny` thin — `destructive_command_guard.sh` covers the irreversible ops
   more precisely.** Do NOT pad `deny` with `git push --force` / `git reset --hard`
   / `git clean`: the guard blocks force-push *unless* `--force-with-lease`, and
   `reset --hard`/`clean` only when the tree is dirty. A blanket `deny` is a string
   prefix — `deny git push --force` also kills the safe `--force-with-lease` — so it
   is strictly worse than the guard.

3. **The `.env` deny is enumerated on purpose — do NOT collapse it back to
   `Read(**/.env.*)`.** That one pattern also matched `.env.example`, the tracked,
   secret-free template every project needs edited, and made it uneditable (Edit
   requires Read, and deny beats allow — so adding `Read(**/.env.example)` or
   `Write(...)` to `allow` is a no-op, not a fix). The exception cannot be expressed
   in one rule: extglob negation (`Read(**/.env.!(example))`) is **unverified**, and
   if the matcher does not support it the pattern matches nothing and every `.env.*`
   silently becomes readable — a fail-open regression. The enumeration fails open
   only for suffixes nobody listed, which is auditable. Tail wildcards cover the
   framework conventions (`dev*`→dev/development, `prod*`, `stag*`, `hml*`/`homolog*`
   for BR environments). Add a row when a new secret-bearing suffix shows up.
   Note `claude -p` does **not** enforce these deny rules, so it cannot be used to
   test them; and settings do not hot-reload mid-session.

4. **No prose "never commit/push" rule** (in this doc or the global CLAUDE.md), and
   **no `ask` entries.** `commit` is in `allow`; `push`/`merge` are left to the
   auto-mode classifier (#644). A prose rule is probabilistic, and an `ask` entry
   overrides the classifier and brings the prompt friction back.

5. **No blanket `Bash(sed:*)` in `allow`.** It used to be safe only because
   `ask`'s `Bash(sed -i:*)` carved in-place edits back out; with `ask` empty, it
   would let `sed -i` rewrite files with no prompt. Read-only `sed` goes through
   the classifier like any other uncovered command.

## Body-template guards: PR and issue

Two `PreToolUse` hooks enforce a repo's own body templates on `gh`, so a
non-compliant PR/issue body is blocked (exit 2) with the template fed back,
rather than relying on prose memory:

| | Source | Applies to | Template it reads |
|---|---|---|---|
| PR guard | `hooks/pr_template_guard.sh` | `gh pr create` / `gh pr edit` | `.github/PULL_REQUEST_TEMPLATE.md` (single file, personal fallback if the repo ships none) |
| Issue guard | `hooks/issue_template_guard.sh` | `gh issue create` / `gh issue edit` | every `.github/ISSUE_TEMPLATE/*.md` (no fallback — a repo shipping none is untouched) |

Both are generic and data-driven: neither hardcodes a repo name or a
template's wording. Both find their `gh <noun> create|edit` invocation by
REAL ARGV, not by scanning raw command text: `hooks/lib/gh_cmd_match.py`
splits the command into simple commands on `;`/`&&`/`||`/`|`/`&`/newlines
(skipping heredoc bodies), tokenizes the matching one with `shlex`, and
reads `--repo`/`-R`, `--body`/`-b`, `--body-file`/`-F`, and
`--label`/`-l`/`--add-label` off that real argv — short flags in all three
pflag spellings (`-b X`, `-bX`, `-b=X`, dotfiles-linux-dev#604) — never off a regex over
the whole string, which could be fooled by that same flag text appearing
inside an unrelated quoted argument (e.g. inside `--title`), or miss an
invocation chained after a shell operator entirely (dotfiles-dev, PR #371
CodeRabbit review). `hooks/lib/gh_body_guard_common.sh`'s
`resolve_gh_command()` is the ONE shared bash entry point into that
tokenizer both guards call — each guard keeps its own message wording
(pinned by its own bats suite) rather than sharing a parameterized
formatter. A command that can't be tokenized at all (an unbalanced quote or
an unterminated heredoc) is "unknown", not "non-compliant": both guards
fail open on it, same as everywhere else uncertainty is possible.

The issue guard derives its requirements straight from each template file:

- a bold (`**`) and/or `·`-separated first non-empty body line, if the
  template's own first line is shaped that way;
- every `##`/`###` header in the template must appear (by text) in the
  body — same rule the PR guard applies to `##` sections;
- if a template's section under a header contains a `- [ ]` checklist
  item, the body's matching section must contain at least one too;
- a **conditional** requirement, declared inside the template's HTML
  comment as a one-line directive (never hardcoded in the hook):

  ```
  issue-template-guard: require "<literal text>" [if-label <label>]
  ```

  Without `if-label` the literal is always required; with it, the
  requirement is enforced only when the label is *positively known* on
  this command — `gh issue create --label`/`-l` states the new issue's
  full label set, but `gh issue edit --add-label` only ever reveals a
  label being added, never the issue's current set, so a directive whose
  label can't be determined this way is skipped (fails open), never
  enforced on a guess.

A repo with several issue templates passes if the body satisfies **any
one** of them — an issue follows one template, not all.

### Where a PR body scratch file lives (dotfiles-linux-dev#441)

`pr_template_guard.sh`'s filesystem view is sandboxed to the project
directory (see `block_unresolved_body_file()`), so a `--body-file` under
`/tmp` or any other out-of-repo path is rejected outright. The body must
live inside the repo, but a PR body is not source — it must never be
committed. The home is a **root-level `$root/.git-pr-<slug>.md`**, already
git-ignored (`.gitignore`'s `.git-pr-*.md` entry, dotfiles-linux-dev#197) —
**not** `$root/.git/`, which the guard used to recommend. `.git/` fails in
two ways: inside a git worktree it is a plain FILE, not a directory, so a
write there fails outright (this repo's own agents work almost entirely in
worktrees under `.claude/worktrees/`); and even where it is writable,
nothing ever looks at it again — 31 files rotted there in blueprintx alone
before this was caught. A `.git-pr-<slug>.md` file works identically in a
worktree or the main checkout, and stays visible to `ls` at the repo root
(unlike `.git/`, which every tool skips by convention) — easier to notice,
not easier to lose.

`hooks/pr_body_orphan_check.sh` is the deterministic reaper's first half:
run it (`ai_clients/claude/hooks/pr_body_orphan_check.sh [repo-root]`, or
`~/.claude/hooks/pr_body_orphan_check.sh` once deployed) to report every
`.git-pr-*.md` file with **no corresponding PR**, matched by CONTENT rather
than filename (a name like `issue_rmw.md` says nothing about which PR it
belongs to). It is deliberately **not** wired into `settings.json` as a live
hook — it is a manual/periodic report, run by a human or
`/session-closeout`-style flow. It **never deletes anything**: a file whose
PR can't be determined (no `gh`/`jq`, or the `gh` call itself fails) is
reported UNKNOWN, never treated as orphaned — reaping is a follow-up once
the matching is trusted, not this cut.

⚠️ "Not a live hook" is about `settings.json` event wiring only — it is
still `copy_hook_file`'d by `install_hooks()` like every other script under
`hooks/`, so it actually reaches `~/.claude/hooks/` for a human or skill to
run. It shipped tested and documented but missing exactly that
`copy_hook_file` call for a while (dotfiles-linux-dev#532): a bats suite that
exercises the script directly stays green whether or not it was ever
installed, so passing tests were never evidence it was reachable.
`tests/hooks_install_parity.bats` now asserts every script under `hooks/`
is installed, not just every script settings.json references.

## PR merge guard: review threads AND a reviewer's own check

`hooks/pr_merge_threads_guard.sh` is a third `PreToolUse` hook, but it gates
`gh pr merge` rather than a body, and it queries GitHub LIVE instead of
reading the command's own text — the full three-layer argument (why a hook,
why live, why last) lives in the file's own header, not duplicated here.

It blocks the merge on **either** of two independent findings:

1. A review thread that is unanswered or unresolved (the original guard).
2. **(dotfiles-linux-dev#379)** A roster reviewer's check — `CheckRun`/`StatusContext`
   on the head commit's `statusCheckRollup`, matched against `.review-bots.yaml`
   — still sitting in a non-terminal state. An **empty** `reviewThreads` list is
   the same shape whether the reviewer looked and found nothing or has not
   spoken yet; `statusCheckRollup` is head-scoped and answers which one it is.
   Measured on #376: merged with CodeRabbit's check `PENDING` and zero threads,
   three Major findings landed minutes later.

   ⚠️ The signal is the CHECK's terminal state, never a submitted review
   object — a review is only created when the reviewer has a finding, so "no
   review yet" is the ORDINARY shape of a clean PR (#378: zero threads, zero
   reviews, terminal `SUCCESS` check) and must never block on its own.

   Fails open exactly where the other guards do: no roster file, or the
   roster's check hasn't appeared in the rollup at all — the same repo has
   one maintainer and a structurally empty Reviewers panel (#268).

Both findings share the one escape hatch, since standing aside for either is
the same deliberate call: `ALLOW_UNRESOLVED_THREADS=1 gh pr merge <n>`.

## Stale-local-ref guard: checkout and worktree add (dotfiles-linux-dev#410)

`hooks/stale_local_ref_guard.sh` (`PreToolUse`, `Bash`) blocks `git
checkout`/`git switch`/`git worktree add` when the target is a bare **local**
branch name that is behind its `origin/<branch>` counterpart. The decision
lives in `hooks/lib/stale_local_ref_gate.sh`'s `gate_stale_local_ref()`,
which sets `STALE_REF_STATUS` (`fresh | ahead | stale | no_remote | no_local
| unreadable`) from a plain `git rev-parse` comparison — no network call, so
it never needs the `gh`-stub test pattern the other gates use.

Measured 2026-09-18 (blueprintx#512): `git worktree add <path>
fix/precommit-ci-parity-384` checked out a ref 3 commits behind the real PR
head. The file under review did not exist at that revision, and a review
pass publicly refuted three real CodeRabbit findings (two Major) as "not in
this PR", resolving all three threads on that false premise — caught only
incidentally, when an unrelated `git merge` later surfaced the very files
the replies said did not exist.

Only **behind** blocks; **ahead** (ordinary unpushed work) is always
allowed — the same asymmetry `push_pr_head_guard.sh` and
`uncommitted_worktree_guard.sh` protect from the other direction. Branch
**creation** (`checkout -b`/`switch -c`/`worktree add -b`) is a different
case, already owned by `branch_requires_issue_guard.sh`, and is skipped
here. Escape hatch: `ALLOW_STALE_LOCAL_REF=1 <command>`.

Registered in `settings.json`'s `PreToolUse` `Bash` array, next to
`branch_requires_issue_guard.sh` — the two are siblings on the same command
family, one owning branch **creation** and this one owning **checkout** of an
existing branch. The entry was missing for a while because `settings.json` was
held by a concurrent PR when the guard was written, and `install_hooks()` shipped
the file the whole time: a guard present on disk and absent from the array is
installed, inert, and indistinguishable from a working one by any check that only
looks for the file. `tests/hooks_install_parity.bats` is what made it visible
(dotfiles-linux-dev#467) — it asserts the two lists agree, in both directions.

## Dispatch coverage: the claims registry and the cap (dotfiles-linux-dev#405)

`hooks/dispatch_free_surface_guard.sh` (a `Stop` hook) enforces **coverage**, not
presence. It blocks while

```
dispatchable − in_flight − queued_by_cap  ≠  ∅
```

and names the missing issue NUMBERS, never a count. Before #405 it exited 0 the
moment *any* dispatch of the session was unresolved, so the strongest thing it
could enforce was "at least one agent is working" — the batch *size* still
depended on the model remembering, which is what the owner asked for in five
separate rounds.

| Term | Source |
|---|---|
| `dispatchable` | `hooks/lib/dispatch_plan.py`, read never re-derived (#433) |
| `in_flight` | per ISSUE: a live claim in `hooks/lib/dispatch_claims.sh`'s registry, **or** an unresolved dispatch whose Agent **name** is `issue-<N>-<slug>` (#404) |
| `queued_by_cap` | the remainder over `DISPATCH_MAX_CONCURRENT` (default 8), counted per AGENT |

⚠️ **A dispatch declares its ONE issue in the Agent's `name`, never in its prompt.** A brief
legitimately cites blockers, prior art and sibling surfaces; reading every `#N` in it made one
agent cover six issues and eat six slots at once — measured on two real dispatches, which
yielded 5 and 6 numbers each (#526 review). The name is written by the dispatcher, so it is a
declaration; a prompt is prose. An in-flight dispatch whose name declares nothing holds a slot,
covers no issue, and is **reported by name** rather than dropped.

**The cap throttles; it never drops.** The overflow is printed as queued and
demanded again as soon as a slot frees. There is deliberately **no queue file**:
the order is recomputed from the plan on every `Stop`, so there is nothing to pop
and nothing to go stale.

`hooks/lib/dispatch_claims.sh` is the agent-vs-agent half that neither the gate
nor the planner can see — two agents dispatched in the same batch are invisible
to each other until one opens a PR. `claim_files <issue> <paths…>` does an atomic
check-and-append under `flock` to `$(git rev-parse --git-common-dir)/dispatch-claims.tsv`
(shared by every worktree, never tracked) and prints `CLAIMED` / `HELD:<holder>:<path>` /
`UNKNOWN`. Three points that are **not** obvious from the file:

1. **Zero API calls, by contract.** Measured 2026-09-17: 8 agents in one batch
   each ran `gate_free_surface` inside their own claim step (33 branches, one
   compare call each) and the shared 5000/h quota hit 0 within seconds, twice —
   every claim then failed closed, correctly, and the wave stalled. So the
   orchestrator calls `refresh_pr_held_paths <owner> <repo>` **once per round**,
   writing `pr-held-paths.tsv` beside the registry, and `claim_files` reads only
   that file plus the registry.
2. **The lock is a separate `.lock` file, never the registry.** A writer replaces
   the registry by `mv` (the only atomic rewrite), so locking the registry itself
   lets the next claimer lock the *new* inode while the holder still holds the old
   one — two agents inside the critical section, i.e. the exact race being
   prevented.
3. **Claims expire (`DISPATCH_CLAIM_TTL`, default 2h).** `release_claims <issue>`
   is the intended path (a PR opened, or the agent stopped without one), but a
   killed agent never calls it, and a registry that reads "everything is in
   flight" forever is dotfiles-linux-dev#404 — a guard that never fires — with a
   different cause.

An issue with no declared file surface is `UNDECLARED`: reported, never assumed
free, never dispatched on a guess. The convention itself is named in exactly one
place — `dispatch_plan.py`'s `SURFACE_LABEL_PREFIX` (a fenced ` ```surface ` block
today; a scope label once blueprintx#314 lands) — and the one-word token is pinned
on both sides (`UNDECLARED_TOKEN` in Python, `DISPATCH_UNDECLARED_TOKEN` in bash)
by `tests/dispatch_claims.bats` so they cannot drift.

## Review fan-out: "needs a review?" is about the HEAD, not a count (dotfiles-linux-dev#480)

`hooks/lib/review_fanout_plan.py` computes which open PRs need a reviewer and
`hooks/review_fanout_guard.sh` (`Stop`) refuses to end a dev-loop round that had
assignable PRs and started no review agent — the same planner+guard pair
`dispatch_plan.py` + `round_dispatch_guard.sh` already are for issues, applied to
step 4b. Both files carry their full reasoning in their own headers; the two
points a future audit must not relitigate are here.

**1. The predicate.** `reviews | length == 0` is wrong in BOTH directions, and
each direction has a measured counter-example from 2026-09-26:

| PR | `reviews` | Truth | What the naive answer does |
|---|---|---|---|
| #520 | 9, all against older heads | unreviewed at the head that would merge | calls it reviewed |
| #453 | 0, plus 2 real fallback reviews posted as comments | those comments predate the head | calls it never reviewed; a head-agnostic attribution match calls it covered |

A push moves the head and invalidates every earlier review — GitHub's own check-run
said so in words ("no reviewer has reported on this new head yet"). So coverage is
per-head, across **both** publication channels, because the two rungs write to
different places and neither sees the other:

1. a submitted review whose `commit.oid` equals `headRefOid` (the primary rung);
2. a comment carrying `ladder_attribution_line`'s text whose second line
   (`Reviewed head: <sha>`) names `headRefOid`, posted strictly after the head
   commit's `committedDate` (the fallback rung, which creates no review object).

⚠️ Channel 2 is head-scoped by SHA **and** time (#564). The time clause alone is defeated
by a backdated head (committer date is the pusher's to set); a marker with no
`Reviewed head:` line fails closed into "needs a review". The time clause still earns its
place: a comment written before the head existed provably did not review it.

**2. `statusCheckRollup` has no single answer keyed by name.** A head can carry two
`CheckRun`s with the SAME name and opposite conclusions (measured on #520: `Review
threads answered` as both `SUCCESS` and `FAILURE` — one from the workflow job, one
POSTed by the workflow). `check_states()` groups by name and reports a disagreeing
name as `ambiguous`, never as pass or fail. This is why #480's third candidate
predicate — "use the step-4 review-thread gate's verdict" — was **evaluated and
rejected**: it is not resolvable by name-and-first-match. Separately, `status` and
`conclusion` are different fields and an in-flight `CheckRun` has an EMPTY
`conclusion`, so `conclusion != "SUCCESS"` reports a running suite as red; running is
decided first, from `status` (`CheckRun`) or `state` (`StatusContext`). `.conclusion
// .state` is not a safe fallback — it mixes the two vocabularies.

🔴 **Determinism belongs to the SCHEDULING, never to accepting a finding.** The plan
decides which PRs get a reviewer; the agent still judges every finding against the
current code, refutes what does not hold with measurement, replies with rationale, and
resolves. A fan-out that auto-applied findings would industrialise the false positives
and be strictly worse than the prose it replaces. Nothing in either file writes to a PR
— `tests/review_fanout_plan.bats` asserts the planner issues no `gh` mutation.

**`rung.status` has THREE outcomes, and each gets a different exit — do not collapse any
two of them:**

| status | Meaning | Guard |
|---|---|---|
| `ok` | a rung resolved | blocks if anything is assignable and nothing was started |
| `none` | the #479 probe RAN; neither qwen nor codex is assignable | **announces once per session, never blocks** (`exit 1`) |
| `unknown` | the probe could not be run, or timed out | **blocks** (`exit 2`) |

⚠️ **`none` is NOT the legitimate zero case**, and reading it as one conflates two facts:
*"every PR carries its own named reason"* means the planner ran and **judged** each PR —
that legitimately passes; *"no rung resolved"* means the mechanism that produces those
reasons was never available and **nothing was judged at all**. A guard that passes
silently there asserts "nothing needed asking" when the honest statement is "I could not
tell" — the same family as a filtered listing's `(empty)` read as "absent", an empty
`conclusion` read as "failing", and a `case` with no `*)` arm dropping a status. But
blocking is equally wrong: nobody should be unable to end a turn for not having signed
into a reviewer runtime, and a re-ping every cycle trains the operator to ignore the
notification — worse than the idle slot it was meant to fix. Announcing once per session
is the only option that keeps both properties, and it is deliberately the same mechanism
`round_dispatch_guard.sh`'s `announce_no_planner` already uses: two near-identical
"mechanism unavailable" conditions handled two different ways would read as a bug.

⚠️ **`exit 1`, not `exit 0`.** A Stop hook blocks on 2 and surfaces stderr on any other
non-zero; **exit 0 discards the message entirely**, which would make the announcement
invisible and turn it back into the silent pass it exists to replace. The non-blocking
announcement is only expressible because 1 and 0 differ this way.

N is capped by API budget, not reviewer quota (#445) — neither file implements a latch of
its own.

**3. Serial drain (#646).** Under a strict required-status-checks policy merging is
inherently serial: every merge puts all other PRs behind, and updating a branch voids its
review, so a reviewer per PR is thrown away (blueprintx, 2026-10-04/05: 13 agents, 3 session
limits and a weekly limit for 2 merges). `merge_is_serial()` reads the policy from the
effective **rulesets** (`rules/branches/<base>`) *and* classic branch protection —
classic said `strict: false` on the repo that motivated this, so it cannot be the only
source — or from `REVIEW_FANOUT_SERIAL=1|0` (declared for every base; overrides the API).
Strictness is decided **per PR base branch** (`baseRefName`), one cached read pair per
distinct base, never from the default branch alone. For each strict base the plan lists
only its lowest-numbered dispatchable PR (that queue's head) and excludes the rest with a
named `serial drain` reason; non-strict bases stay parallel. It emits `"serial": true` when
any dispatchable PR sits on a strict base. The invariants hold: every
PR still carries a reason, no bare override, and an unreadable policy falls back to the
parallel plan, never to a guessed serial one. The guard needs no new branch — "the queue
head has a `review-pr-<N>` agent in flight" is already its pass condition.

## Worktree rescue fan-out: two callers, one implementation

`hooks/lib/worktree_fanout.sh` (`fanout_worktrees()` + `classify_worktree_diff()`,
dotfiles-linux-dev#383) is the shared implementation of "walk every worktree of this
repo and classify its dirty state as interrupted work vs. a stale revert" —
same pattern as `hooks/lib/free_surface.sh` and `hooks/lib/review_thread_gate.sh`.
It has two callers now, not one:

1. `hooks/session_start_context.sh` (`SessionStart`) — the original caller,
   unchanged in output by the extraction.
2. `hooks/quota_gap_rescue.sh` (**`UserPromptSubmit`**, the repo's first hook on
   this event) — re-runs the same walk when the gap since this session's last
   prompt exceeds a threshold (default 20 min, `QUOTA_GAP_THRESHOLD_SECONDS`).
   SessionStart only fires once; a quota kill resumes the SAME session, so
   nothing re-checked the worktrees between the kill and the next `s:dev-loop`
   round (up to an hour away) until this hook existed. It runs on **every**
   prompt, so it stays cheap (skips the walk entirely below the threshold, and
   never calls `gh`) and prints only when `fanout_worktrees()`'s own summary
   line reports interrupted work — never for a clean worktree or a stale
   revert, reusing the classifier's verdict rather than re-deriving it.

## A gate's contract: a usable answer, not just a clean exit (dotfiles-linux-dev#398)

Every shared gate above (`free_surface.sh`, `review_thread_gate.sh`,
`roadmap_unblock.sh`) calls `gh` and fails closed on a read error — but
"fails closed" and "never crashed" are not the same claim, and #395 shipped
the gap between them: `gate_free_surface` hit an orphan branch's compare
404, returned its documented `exit 1` with empty output, and its caller
rendered that as routine text ("free surface UNKNOWN"). Nothing was ever
red. No test called the gate itself — only its sub-helpers — so the defect
shipped and stayed invisible for four dispatch rounds with 40 issues
unclaimed, found only when a human ran it by hand.

**A gate's test contract has two halves, and a passing suite must prove
both:**

1. **Success returns a usable answer.** `exit 0` with empty output is
   exactly as wrong as `exit 1` — it is the easier failure to accept
   silently, because nothing downstream treats an empty success as an
   error. A contract test asserts the *shape* of the answer (the
   documented globals are set, and are non-empty on a fixture that
   provably has non-empty content), not merely that the function returned
   0.
2. **The fail-closed path is exercised deliberately**, with a fixture that
   makes the underlying `gh` call fail, asserting the gate's status field
   reads "unknown"/"unreadable" and every result global stays empty (never
   a partial answer) — only the status field and its diagnostic detail
   (e.g. `GATE_DETAIL`) are set. Skipping this half is how a fail-closed gate
   quietly drifts into fail-open: "tolerate this one 404" (#395's own fix)
   is one bad refactor away from "treat any API failure as empty" if
   nothing pins the *other* branch red.

Tests for all three `gh`-calling gates use stubbed `gh` fixtures (a shell
function or fake-`gh`-on-`PATH`, never a live token) so CI stays
deterministic — see `tests/free_surface.bats`, `tests/review_thread_gate.bats`,
and `tests/roadmap_unblock.bats` for the pattern. `roadmap_unblock.bats`
already covers both halves for `reconcile_roadmap_unblock()` (its own
top-level function); `free_surface.bats` and `review_thread_gate.bats`
originally tested only their internal sub-helpers (`_free_held_paths`,
`_gate_problems_filter`, …) and were extended to also call the top-level
gate function (`gate_free_surface`, `gate_pr_thread_state`) directly, since
a sub-helper passing proves nothing about the wiring above it.

## Lesson mirrors (`.specs/_lessons/`)

A lesson store (`~/.claude/memory/lessons*`) is global — it lives outside every repo. A
**mirror** is a per-repo, git-ignored copy of the subset of a store whose `**Origin:**`
line names that repo, so a session working in the repo can `grep` its own history
without leaving it. Two things this is not: it is not documentation (`docs/`, shipped,
human-authored to be read) and it is not hand-written.

**Who writes it:** the generator, never a person. `make lessons_mirror`
(dotfiles-dev repo) or `bash ~/.claude/hooks/lib/generate_lesson_mirrors.sh` (any other
repo, deployed by `install_hooks()`) reads `LESSON_STORES`
(`ai_clients/claude/hooks/lib/lesson_mirrors.sh`), collects every lesson whose Origin
names the current repo, and overwrites `.specs/_lessons/<store>-lessons.md` wholesale.
Before dotfiles-linux-dev#386 this was a third hand-write per lesson (file + store README +
mirror) and it drifted — measured 2026-09-14, 19 of 43 `Origin: dotfiles-dev` lessons
were missing from the hand-maintained copy. Regenerating removes the drift class
instead of adding a check for it. **Never hand-edit a file under `.specs/_lessons/`** —
the next regeneration overwrites it silently.

`session_capture_audit.sh`'s `check_mirrors()` verifies the *result* (presence +
not-stale) using the same `lesson_mirrors.sh` predicates the generator uses, so the
two can never independently drift on what a mirror is supposed to contain. A store
whose `target-repo` equals the current repo (same-repo mirror) or is the `-` sentinel
(`lessons-other`) never gets a mirror anywhere — see `.specs/CLAUDE.md` for the
directory's naming rationale (`_lessons/`, not `lessons/` or `mirrors/`).

## Agent-agnostic bridge (`ai_clients/shared/AGENTS.md`)

| | |
|---|---|
| **Source** | `ai_clients/shared/AGENTS.md` |
| **Installs to** | `~/.claude/AGENTS.md` (Claude, via `@AGENTS.md` import in `~/.claude/CLAUDE.md`); `~/.codex/AGENTS.md`; `~/.qwen/AGENTS.md`; `$COPILOT_HOME/copilot-instructions.md` (default `~/.copilot/`; Copilot does not read AGENTS.md); `$KIMI_CODE_HOME/AGENTS.md` (default `~/.kimi-code/`, **unverified** — Kimi Code CLI is not installed on this machine, dotfiles-linux-dev#346) |
| **Lib script** | `ai_clients/lib/shared_agents_md.sh` → `install_shared_agents_md(dest)`, called once per client with that client's live path — Claude and Codex both use step key `agents_md`/`shared_agents_md`; Qwen, Copilot, and Kimi each have exactly one step, also named `agents_md` |

**The seam: `AGENTS.md` is the source; each tool's config is a generated
view (or an import) of it, never a second hand-authored copy.** One
authored file plus N generated/imported views cannot drift; two authored
files covering the same policy always will. Concretely:

- `ai_clients/claude/config/CLAUDE.md` carries `@AGENTS.md` as an import —
  Claude Code's own import mechanism, already proven by the existing
  `@RTK.md` import — so the shared content is never re-typed there. Only
  genuinely Claude-Code-specific mechanics (hook names, tool names,
  `dangerouslyDisableSandbox`, ...) stay inline in `config/CLAUDE.md`.
- Every other adopted tool (Codex, Qwen, Copilot, Kimi) has no import syntax
  of its own, so each deploys a literal copy of the same source file via
  `install_shared_agents_md(dest)` — never a second hand-authored copy.
  Codex used to hand-author its own `config/AGENTS.md` and drift from this
  source; that gap is closed (dotfiles-linux-dev#346) by pointing it at the shared
  helper like every other non-Claude client.
- Content belongs in `ai_clients/shared/AGENTS.md` only if it holds for any
  agent driving this machine (RTK proxy policy, verifying git writes
  landed, Conventional Commits, `Decimal` policy). Anything that names a
  hook, a skill, a subagent, plan mode, or a memory path is Claude-Code-
  specific and stays under `ai_clients/claude/`.
- Only the AGENTS.md-shaped file is versioned for Qwen/Copilot/Kimi.
  Everything else in their live config dirs — credentials, session ids,
  usage/tip history, IDE locks, debug logs, first-launch timestamps, and
  (for Qwen) a `settings.json` that mixes real model-provider config with a
  live API key — is machine-local state or a possible secret, deliberately
  left unversioned (dotfiles-linux-dev#346's inventory of `~/.qwen`/`~/.copilot`
  on the reporting machine).

Do not symlink the deployed copies to the source — a symlink degrades to a
broken plain-text file on a Windows checkout without Developer Mode
(measured on the repo-level sibling of this mechanism, blueprintx#273), and
these dotfiles are installed across machines.

## Three artifact types

### 1. Commands (slash commands)

| | |
|---|---|
| **Source** | `ai_clients/claude/commands/<name>.md` |
| **Installs to** | `~/.claude/commands/<name>.md` |
| **Lib script** | `lib/slash_commands.sh` → `install_slash_commands()` |
| **Invoked by user as** | `/name` (filename without `.md`) |

**Required frontmatter fields:**

```yaml
---
name: c:<kebab-name>          # c: namespace prefix is mandatory
allowed-tools: Bash(...), Read, Glob, Grep   # whitelist only what the command needs
description: <one-line, user-visible>
argument-hint: <hint shown in autocomplete>  # optional but recommended
---
```

**Writing conventions:**
- Open with `You are <doing X> for this repository. Follow these steps exactly.`
- Number steps sequentially (`## 1.`, `## 2.`, …); sub-steps use `## Na.`
- Reference user input as `$ARGUMENTS`; always handle the empty-arguments case
- Bash commands shown inline use backtick blocks; use `!cmd` notation for
  commands the model should run in the conversation
- `allowed-tools` must use glob patterns for Bash (`Bash(git diff*)`) —
  never `Bash(*)` (too broad)
- No trailing `Co-Authored-By` footers unless explicitly requested
- Every command example that reads or writes repository state qualifies its
  target: absolute `cd <path> &&` for the directory, explicit `origin/<base>`
  for any git ref compared against a base — never a bare local branch or an
  implicit `HEAD`, and never `git -C <path>` as a substitute (it fixes the
  directory, not the ref). Same rule as `config/CLAUDE.md`'s
  "Qualify the target" bullet (dotfiles-linux-dev#229).

### 2. Agents (subagent definitions)

| | |
|---|---|
| **Source** | `ai_clients/claude/agents/<name>.md` |
| **Installs to** | `~/.claude/agents/<name>.md` |
| **Lib script** | `lib/agents.sh` → `install_agents()` |
| **Invoked by user as** | `a:<name>` (via the `name` field) |

**Required frontmatter fields:**

```yaml
---
name: a:<kebab-name>          # a: namespace prefix is mandatory
description: <one-line trigger description>
model: opus                   # sonnet | opus | haiku
color: green                  # green | blue | yellow | red | purple
memory: true                  # persist memory across invocations
disable-model-invocation: true
effort: high                  # low | medium | high
argument-hint: [hint]
---
```

**Writing conventions:**
- Agents orchestrate skills (`/s:skill-name`) and other commands — they do
  not implement logic themselves
- Always start by asking for any required inputs not already in `$ARGUMENTS`
- Define explicit checkpoints (`### --- Checkpoint N ---`) where the agent
  pauses for user confirmation before continuing
- End with a structured `## Final summary` block
- Include a `## Do Not` section listing prohibited behaviors
- Use `## Memory` section when `memory: true` to define what to persist
- Same target-qualification rule as commands, above (dotfiles-linux-dev#229) —
  agent briefs are exactly where it matters most, since a dispatched agent's
  cwd can reset to a different repo mid-task with no `cd` ever run

### 3. Skills (mid-task reference guides)

| | |
|---|---|
| **Source** | `ai_clients/claude/skills/<name>.md` (flat) |
| **Installs to** | `~/.claude/skills/<name>/SKILL.md` (directory — **not** a flat `.md`) |
| **Lib script** | `lib/skills.sh` → `install_skills()` |
| **Invoked** | Loaded by Claude's Skill tool mid-task (not user-invoked) |

> **The install layout is not cosmetic.** Claude Code's skill loader only
> discovers `skills/<name>/SKILL.md`. A flat `skills/<name>.md` copies fine,
> shows up in `ls`, and is silently never loaded — the failure is invisible
> except as an absence in the session's available-skills list. Commands are
> the opposite (flat `commands/<name>.md` is correct); do not generalise one
> convention onto the other.
>
> The invocation name comes from the **path**, not the frontmatter `name`
> field — `commands/act.md` with `name: c:act` still surfaces as `/act`. The
> `s:` / `c:` prefixes are an organisational convention only.

**Required frontmatter fields:**

```yaml
---
name: s:<kebab-name>          # s: namespace prefix is mandatory
description: Use when <specific triggering conditions — no workflow summary>
effort: high                  # low | medium | high
argument-hint: [hint]
allowed-tools: Read Glob Grep  # space-separated for skills (no commas)
---
```

**Writing conventions:**
- Description must start with "Use when…" and describe *when* to load the
  skill, never *what* the skill does — Claude reads the description to decide
  whether to load it; a workflow summary causes Claude to follow the
  description instead of reading the skill body
- Skills are read-only reference guides by default; add `allowed-tools` only
  if the skill legitimately needs to run commands
- Keep total token count low — skills load into every conversation that
  triggers them
- Same target-qualification rule as commands, above (dotfiles-linux-dev#229) — a
  skill's example commands are copied into a running session verbatim

## Session profiles (cheap-brain runtime, dotfiles-linux-dev#151)

| | |
|---|---|
| **Source** | `ai_clients/claude/settings.<provider>.json` (an `env`-only overlay, not a full settings.json) + `ai_clients/claude/profile_functions.sh` (the launcher) |
| **Installs to** | `~/.claude/settings.<provider>.json` (token resolved from `.env`) + `~/.claude/profile_functions.sh`, sourced from `~/.bashrc` |
| **Lib script** | `lib/profiles.sh` → `install_profiles()`, step key `profiles` |
| **Invoked by user as** | `claude-profile <provider>` (shell function; e.g. `claude-profile deepseek`) |

A profile points `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN` at an
Anthropic-compatible endpoint so the harness — every skill, hook, gate,
guard, and MCP server — survives; only the model changes. The token is
never committed: the source file ships the placeholder `KEY-GOES-HERE` and
`_install_deepseek_profile` in `lib/profiles.sh` substitutes it from the
project root `.env` at deploy time, the same pattern `mcp_servers.sh`
already uses for `CONTEXT7_API_KEY`/`TAVILY_API_KEY`.

**Verified endpoint:** DeepSeek, `https://api.deepseek.com/anthropic`, auth
via `ANTHROPIC_AUTH_TOKEN` — **verified 2026-08-26** (see the runtime
roster issue, dotfiles-linux-dev#151, for the sourced comparison against
Zhipu/GLM, Moonshot/Kimi, and MiniMax). Re-verify and update this date
before relying on it again; provider compatibility is the field most
likely to rot.

⚠️ **The two-session pattern, and why it's two sessions and not one.**
`ANTHROPIC_BASE_URL` is process-level: it swaps the model for the WHOLE
session, subagents included, because a subagent inherits the parent
process's endpoint. So "premium orchestrator managing cheap-model
subagents" cannot be built inside a single session — there is no per-
subagent endpoint override. The working pattern is **two separate
sessions**:

- a normal (premium) session for work that needs the strong model, and
- a `claude-profile <provider>` (cheap-brain) session for delegated or
  AFK-shaped work,

handed off between them via `gh issue list --label afk --label
oracle:strong` (dotfiles-linux-dev#150's routing label), not via subagent calls
within one process.

## Namespace prefixes (summary)

| Prefix | Type | Invocation |
|--------|------|------------|
| `c:` | Command | `/c:name` by user |
| `a:` | Agent | `a:name` in task list |
| `s:` | Skill | Loaded by Skill tool |

## File naming standard

Filenames (without `.md`) follow the pattern **`<tool>-<action>`** or
**`<language>-<action>`**, where the prefix identifies the primary tool or
language the artifact targets:

| Prefix | Targets | Examples |
|--------|---------|---------|
| `py-` | Python language | `py-audit`, `py-create`, `py-unit-test` |
| `bash-` | Bash scripts | `bash-create` |
| `gh-` | GitHub CLI (`gh`) | `gh-create-pr` |
| `git-` | Git commands | `git-rebase` (hypothetical) |
| `design-` | Cross-tier design-family primitives (tokens, interview, exports) shared across the three design tiers | `design-color-system`, `design-token-export`, `design-write-language` |
| `brand-` | Brand-tier–specific concerns (identity, voice, logo, brand book assembly) | `brand-identity`, `brand-logo-imagery`, `brand-write-book` |

**Rules:**
- Use the tool/CLI name as prefix when the skill wraps a specific external
  tool (e.g. `gh`, `git`, `docker`).
- Use the language name as prefix when the skill targets a programming
  language workflow (e.g. `py`, `bash`).
- The action segment is a short imperative verb phrase: `create`, `audit`,
  `unit-test`, `create-pr`.
- Never use a bare action without a prefix (e.g. `create-pr.md` is wrong;
  `gh-create-pr.md` is correct).
- The `name` field in frontmatter follows the same pattern with the
  namespace prefix: `s:gh-create-pr`, `s:py-audit`, `c:commit-code`.

## Design family (3-tier agent architecture)

The repo ships **three independent agents** that mirror the three deliverables
of a professional design org. They share a foundation library of `design-*`
skills and compose through on-disk artifacts — never through agent-to-agent
calls.

### Tiers

| Tier | Agent | Output | Machine export |
|---|---|---|---|
| Brand | `a:brand-design` | `design/brand/brand-book.md` (prose-first identity manual + 5-colour identity palette + 1–3 typefaces) | none |
| Language | `a:design-language` | `design/language/<purpose>.md` (foundation tokens + Overview/Colors/Type/Layout/Elevation/Motion/Responsive prose) | `tokens.*.json` + `theme.css` |
| System | `a:design-system` | `design/system/<purpose>.md` (foundations + components-with-`states:` + themes + accessibility audit + governance/changelog) | `tokens.*.json` + `theme.css` |

Tiers conceptually nest (system ⊃ language ⊃ brand), but agents stay
independent. Each higher tier's `s:design-interview` checks disk for a
lower tier's artifact and offers to reuse it; if absent, it gathers
what it needs itself.

### Skill split

- **`design-*` skills** — tier-neutral primitives reused across language
  and system tiers (and lightly by brand): `design-interview`,
  `design-color-system`, `design-type-system`, `design-layout-system`,
  `design-motion-system`, `design-component-system`,
  `design-accessibility-audit`, `design-theming`, `design-governance`,
  `design-token-export`. Plus per-tier writers `design-write-language`
  and `design-write-system`.
- **`brand-*` skills** — brand-tier–specific: `brand-identity`,
  `brand-logo-imagery`, `brand-write-book`. The brand tier owns its own
  palette + typeface picks at identity level; the full token scale
  lives in design-language.

### Runtime choices

Format/behavior decisions are deferred to the *runtime user*, not baked in:

- `s:design-token-export` asks **which JSON shape(s)** to emit (W3C DTCG /
  flat namespaced / Style Dictionary) and **which CSS naming** to use
  (dot-flattened / path-preserved / Tailwind v4 `@theme`).
- `s:design-color-system` asks **WCAG verification mode** (flag-only /
  auto-suggest replacements / skip).
- `s:design-theming` asks **which theme variants** to generate (dark /
  high-contrast / compact / none).

### Output directory layout

```
design/
├── brand/
│   └── brand-book.md
├── language/
│   ├── <purpose>.md
│   ├── tokens.dtcg.json        (per export selection)
│   ├── tokens.flat.json
│   ├── tokens.style-dictionary.json
│   └── theme.css
└── system/
    ├── <purpose>.md
    ├── tokens.*.json
    └── theme.css
```

`<purpose>` is the kebab-case surface slug (e.g. `web-app`, `app-cellphone`,
`dashboard`, `ecommerce`). The brand book is per-brand (one file, no
purpose suffix); language and system docs are per-purpose.

### Upstream of the design family: `s:problem-framing`

`s:problem-framing` (known as Shape Up, Basecamp) sits **before** the design tiers,
not inside them. It answers *what are we building and how big is the budget* —
appetite, persona, breadboard, rabbit holes, no-gos, demoable scopes. It deliberately
produces **no layout**: a breadboard shows places, affordances and connections
only.

The seam is sharp and the two never overlap:

| | Answers | Produces |
|---|---|---|
| `s:problem-framing` | what + how big | appetite, breadboard, no-gos, scopes |
| `a:design-language` / `a:design-system` | what it looks like | tokens, type, components |

Shaping stops exactly where design-language begins. When a shaped scope needs UI,
`s:problem-framing` hands off to the relevant design tier.

### Do-not list (architecture invariants)

- Agents never invoke each other. Reuse is always via on-disk artifacts
  read by `s:design-interview`.
- The brand tier never produces a full token scale or component spec —
  those belong to language and system respectively.
- The language tier never produces a `components:` block — components
  are the system tier's concern.
- The markdown frontmatter is the canonical source of truth for tokens.
  JSON / CSS exports are pure derivations emitted by `s:design-token-export`.

## Pruning orphaned artifacts

The `install_*` steps only copy — they never delete. Anything removed or renamed
in source therefore stays behind in `~/.claude/` forever, and a leftover in a
loadable layout is a *live* artifact: a renamed command shipped both the old and
new name for months before this was caught.

`lib/prune.sh` → `prune_orphans()` is the delete path, exposed as the `prune`
step. It diffs each artifact type against its source directory and removes only
what has no source counterpart, **always asking first**. Source is authoritative
and every removal is recoverable from git history.

```bash
./ai_clients/claude/main.sh prune
```

Artifact types are registered in the `PRUNE_TARGETS` map as
`<src subdir>:<ext>:<dest subdir>:<layout>` — add a row there when adding a new
artifact type, or its orphans go unnoticed.

Note the division of labour with `install_skills()`: prune removes **name**
orphans (no source counterpart), while `install_skills()` separately sweeps
**layout** orphans (flat `skills/*.md`, which are never loadable regardless of
whether a source file of that name exists). Neither one subsumes the other.

### Pruning stale `settings.json` keys (dotfiles-linux-dev#272)

File orphans and settings-key orphans are different shapes of problem, and
`prune_orphans()` handles both: `_prune_file_artifacts()` for the file types
above, then `prune_settings_keys()` for `settings.json`. The settings side
can't reuse the file logic's "anything live without a source counterpart is
an orphan" rule — the live file legitimately carries machine-local keys
(API tokens, per-machine `env` entries) that must survive every deploy,
which is the entire reason `configure_settings()`'s merge (`lib/settings.sh`)
is additive-only (`jq '. * $base'`, never deletes).

So `prune_settings_keys()` is scoped to the object keys named in
`SETTINGS_PRUNE_KEYS` (`lib/prune.sh`) — subtrees that are *entirely*
source-owned, `enabledPlugins` being the concrete case: every entry is added
by `run_plugins()`, never hand-edited live, so anything live-but-not-in-source
is unambiguously stale (e.g. a plugin reference removed from source after the
marketplace stopped shipping it). It diffs only inside those named keys, asks
before removing, and never touches a top-level key or any key not listed —
adding a key to `SETTINGS_PRUNE_KEYS` is an explicit claim that source is the
full authority for everything under it.

## AI-state sync (`hooks/ai_state_sync.sh`, dotfiles-linux-dev#655)

Authored `~/.claude` state that no deploy step reproduces lives in a **private** repo
(`AI_STATE_REPO`, default `guilhermegor/ai-clients-state`), one script with three
subcommands and two callers:

| Caller | Invocation | Behaviour |
|---|---|---|
| `SessionStart` hook | `ai_state_sync.sh pull --hook` | bounded `pull --rebase --autostash`; offline is silent; prints only a conflict |
| `SessionEnd` hook | `ai_state_sync.sh push --hook` | secret guard, commit, push; always exit 0 |
| Shortcut / terminal | `~/.local/bin/ai-state-sync pull\|push` | same code, prints the outcome, `notify-send` without a TTY, non-zero on failure |
| Step `state_sync` | `ai_state_sync.sh setup` | clone + materialise; refuses to overwrite a divergent live file; no remote means the `gh repo create --private` hint and nothing else |

**Work-tree, not symlinks.** The git dir lives at `~/.ai-clients-state/claude.git` with
`--work-tree=~/.claude`. Symlinking `memory/`, `projects/*/memory/` etc. would need a
link per project dir (a project created tomorrow is unlinked until a re-run), would
replace real directories on a fresh machine, and degrades on Windows. The work-tree
needs no link at all. Membership is the whitelist in the git dir's `info/exclude`
(`/*` then explicit `!` entries; `*.jsonl`, `.env*`, `.credentials.json` re-denied
last), rewritten on every run so a whitelist change deploys with the hooks.

**`issue-trackers.conf` lives in the state repo**, not here: it is owner-specific
config (which trackers the owner's repos use), this repo is public, and a deployed copy
would need a per-machine override anyway.

**Default remote follows `gh config get git_protocol`**: https gives
`https://github.com/<repo>.git` (gh's credential helper authenticates it), ssh gives the
SSH form, and https is the fallback when gh is absent or fails. An explicit
`AI_STATE_REMOTE` always wins.

**Secret guard**: token shapes and PEM keys only (same patterns as
`commit_secret_guard.sh`, kept in sync by hand). A flagged file is unstaged and reported
by NAME (never the value); the rest still syncs. A password-assignment heuristic was
left out on purpose: it would false-positive on memory prose and wedge the sync.

**Conflicts are never resolved.** A push whose rebase conflicts is aborted (local
commits kept); a pull conflict leaves git's markers. Both write
`~/.claude/session-audit/ai-state-sync.md`, which the next `pull --hook` prints.

**Extension point (#656)**: `AI_STATE_GIT_DIR`, `AI_STATE_WORK_TREE`, `WHITELIST`,
`BRANCH` and `AI_STATE_SQLITE` are the per-client inputs, selected by `AI_STATE_CLIENT`
(`claude` default, `codex`); a client is a second invocation, not a change to the modes.

**Codex (`AI_STATE_CLIENT=codex`)**: git dir `~/.ai-clients-state/codex.git`, work tree
`${CODEX_HOME:-~/.codex}`, branch `codex` of the same private repo, handoff
`session-audit/ai-state-sync-codex.md`. Whitelist is only `/state-dump/`; `auth.json`,
`*.sqlite*`, `*.jsonl` are re-denied last. `push` first exports `memories_1.sqlite` and
`goals_1.sqlite` (WAL mode) as `state-dump/<name>.sql`: sqlite's online `.backup` into a
private `mktemp -d` snapshot, then `.dump` of the snapshot, so a running Codex never
yields a torn copy; the dump then passes the same secret guard. Binary DBs are never
committed. `setup` (step `state_sync`) restores a dump only when the target DB is absent,
zero bytes, or has no user table; a populated DB is **refused** with a message and left
untouched. The `SessionEnd` hook runs the codex push after the claude one.

⚠️ **Contract: seed-only restore, one writer at a time.** Codex sync is a backup plus a
first-machine seed, not a bidirectional merge. A populated DB is never updated from the
remote, and two machines that both write Codex memory produce two competing versions of the
same `.sql` file: the second `push` hits a rebase conflict, which is aborted and reported
like any other conflict (never auto-resolved). Use Codex's memory on one machine at a time.
To move it, stop on the old machine, delete the DBs on the new machine, and re-run
`state_sync`. A row-level SQLite merge was considered and left out (#675 review): the DB
schema belongs to Codex and can change under any update.

**Clients with no invocation (measured 2026-10-07)**: `~/.qwen`, `~/.copilot`,
`~/.kimi-code` carry no authored state beyond the deployed `AGENTS.md` (Qwen
`settings.json` holds a live API key; Kimi `credentials/`, `oauth/` and session history
are never synced). Rule for any future client: authored state only, never credentials,
session history, caches or logs. Keyboard-shortcut wiring
(`distro_config/set_custom_shortcuts.sh`) is a separate follow-up.

## Deployment

```bash
make ai_clients        # interactive menu (choose steps individually)
# or via main.sh directly:
./ai_clients/claude/main.sh slash_commands   # install only commands
./ai_clients/claude/main.sh skills           # install only skills
./ai_clients/claude/main.sh agents           # install only agents
./ai_clients/claude/main.sh all              # install everything
```

### Stale-checkout guard (dotfiles-linux-dev#643)

`ai_clients/lib/upstream_guard.sh` → `ai_clients_upstream_guard` runs first in
`ai_clients/main.sh` and every client `main.sh`. It fetches, and **refuses** (exit 1)
when `HEAD..@{upstream}` is non-empty: a deploy from a stale `master` once rewrote
`~/.claude/hooks/lib/reviewer_ladder.sh` and silently reverted a merged fix.

- Ahead or equal: allowed. Only behind is refused.
- Escape hatch: `AI_CLIENTS_ALLOW_STALE=1 make ai_clients` (warns, deploys anyway).
- Fetch fails (offline) or no upstream configured: **warns and proceeds** — a flaky
  network must not wedge a deploy; the guard is only as fresh as the last fetch then.
- The router exports `AI_CLIENTS_UPSTREAM_CHECKED=1` so child client scripts skip a
  second fetch.

## Adding a new step to the orchestrator

1. Create the lib function in `ai_clients/claude/lib/<step>.sh`
2. Source it in `ai_clients/claude/main.sh`
3. Add `"key|Label"` to the `STEPS` array
4. Add a `case` branch in `dispatch_step()`

## Commit message constraints (gitlint)

This repo enforces gitlint. Commits must satisfy:

- Title line: ≤ **72 characters** (including `type(scope): `)
- Body lines: ≤ **80 characters** each (including `  - ` prefix and ` → file` suffix)
- Measure with `echo -n "..." | wc -c` before committing; never estimate
