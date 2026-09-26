@RTK.md
@AGENTS.md

The shared `AGENTS.md` import above carries the agent-agnostic core (RTK
proxy policy, verifying git writes landed, Conventional Commits, `Decimal`
policy) — it is read by every AI agent driving this machine, not just
Claude Code. The Claude-Code-specific mechanics behind those same policies
live here:

- **RTK rewrite hook.** The `PreToolUse` hook rewrites `git …` → `rtk git …`
  at execution time, but the approval prompt shows the pre-hook command, so
  "don't ask again" creates a wrong allowlist entry (`Bash(git *)` instead
  of `Bash(rtk git *)`) unless the `rtk` form is what was typed.
  ⚠️ **Worktree-isolated agents are the one case where this rewrite must not
  fire.** A harness-provisioned isolated worktree (`.claude/worktrees/agent-
  <id>/`) has its own guard that refuses an `rtk`-prefixed git invocation it
  cannot statically verify — and since the rewrite runs before that guard
  sees the command, no spelling the agent types satisfies both layers
  (dotfiles-dev#417). `hooks/rtk_worktree_passthrough.sh` sits in front of
  `rtk hook claude` and skips the rewrite (stripping any `rtk`/`rtk proxy`
  prefix back to plain `git`) whenever cwd matches that path shape — a
  worktree an agent creates itself under any other name is unaffected.
- **Filtered-listing checks.** Use the **Read** or **Glob** tool — never
  rtk-proxied `ls`/`find` — to confirm a path exists. List a directory
  reliably with **Glob** (`dir/**`) or the raw escape hatch
  `rtk proxy ls <dir>` / `rtk proxy find <dir>`.
- **Git writes run under the sandbox.** A `git commit`/`push`/`tag`/
  `branch -d/-D` run through the Bash tool executes in the **default
  sandbox** overlay, which can print full success while the ref update is
  discarded on teardown and HEAD never moves. This is a Claude Code harness
  behaviour, not an RTK proxy issue (evaluated for dotfiles-dev#79 —
  cosmetic, the proxy is not the persistence culprit). Run every git write
  with `dangerouslyDisableSandbox: true`, then apply the shared AGENTS.md
  verification steps above. A rejected pre-commit hook is the other cause
  of the same symptom — never pipe `git commit` through `tail`/`head`/
  `grep`, since a rejection (`codespell`, `gitlint`, `ruff E501`) can scroll
  off past trailing `Passed` lines.
- **Qualify the target: absolute `cd`, explicit git ref.** Every command
  in an agent brief, a skill, or a hook that reads or writes repository
  state must name what it targets — `cd <absolute-path> &&` for the
  directory, `origin/<base>` for the ref, never a bare local branch or an
  implicit `HEAD`. Same family as the two rules above: the channel lies in
  silence, so qualify. Measured 2026-09-05: the harness resets cwd after
  every Bash call and can reset it to a **different repository**
  (`Shell cwd was reset to ~/github/blueprintx` with no `cd` having run),
  and in the same session an unref'd `git describe --tags --abbrev=0`
  described a stale feature-branch checkout 16 tags behind `origin/main` —
  the release gate would have diffed against the wrong tag and cut the
  wrong version with nothing red. `git -C <path>` does not fix this: it
  resolves the directory but not the implicit-HEAD half of the bug
  (dotfiles-dev#229). A second, costlier recurrence: `git worktree add
  <path> <branch>` naming a **bare local branch** checked out a ref 3
  commits behind the real PR head, and a review pass publicly refuted three
  real CodeRabbit findings (two Major) as "not in this PR", resolving all
  three threads on that false premise (blueprintx#512). Reviewing a PR
  means reading it at `origin/<head-ref>` after an explicit fetch, never at
  a local branch of the same name — `stale_local_ref_guard.sh` /
  `hooks/lib/stale_local_ref_gate.sh` now refuse a checkout/worktree-add
  whose local ref is behind `origin/<branch>` (dotfiles-dev#410).

## Superpowers spec/plan output — redirect to `.specs/`

`s:brainstorming` and `s:writing-plans` (the `superpowers` plugin) hardcode
their save path to `docs/superpowers/specs/` and `docs/superpowers/plans/`
in their own `SKILL.md`, inside the plugin cache
(`~/.claude/plugins/cache/<marketplace>/superpowers/<version>/skills/`) —
not a file any of our repos own or can edit; it is overwritten on every
plugin update. The redirect happens here instead, in the instructions read
before that stated path is followed (dotfiles-dev#303):

Before writing a spec or plan, decide which applies — **ask if it isn't
already obvious, never infer**:

1. **The project has a `.specs/` at its root already** → write there:
   `.specs/features/<feature-name>/design.md` (brainstorming) and
   `.specs/features/<feature-name>/plan.md` (writing-plans). See that
   project's own `.specs/CLAUDE.md` for what belongs there.
2. **It has none, and you own/maintain its layout** → ask before adopting
   `.specs/` there; do not create it unasked.
3. **It has none, and you're a contributor rather than the owner** (you
   didn't choose its layout, didn't scaffold it) → this is the normal case
   for that category of repo, not a fallback: write to
   `~/.claude/specs/<repo-slug>/features/<feature-name>/{design.md,plan.md}`
   instead, never inside the foreign repo.

Guessing wrong is either an unwanted directory in someone else's repo, or a
spec written where nobody will look.

## Author Claude artifacts in dotfiles-dev, never only in live `~/.claude/`

Durable Claude artifacts (commands, skills, agents, rules, hooks, global
`CLAUDE.md`, settings) must be authored in the version-controlled source under
`~/github/dotfiles-dev/ai_clients/claude/`, then deployed with `make ai_clients`
(or `cp` into place). Never write them only to `~/.claude/` — it is machine-local
and non-symlinked, so direct edits are lost on the next OS/distro install.

Enforced by the `claude_artifact_source_guard.sh` PreToolUse hook: a direct
Write/Edit into `~/.claude/{commands,skills,agents,rules,hooks}/` or `CLAUDE.md`
is blocked and redirected to its source. Not blocked by the hook:
project-scoped `.claude/`, project memory, `tasks/`, `plans/`, `settings*.json`.
⚠️ **Not-blocked ≠ write-it-live.** `settings*.json` is unblocked only because it
also carries machine-local keys — **durable** settings (permissions `allow`/`deny`/
`ask`, model, hooks, plugins) are still authored in
`ai_clients/claude/settings.json` and deployed; `configure_settings` deep-merges
(`jq '. * $base'`), so source wins and live-only keys survive. Full source-path
table: `ai_clients/CLAUDE.md`.

# Global Programming Preferences

> **Priority rule:** These are personal defaults. Whenever a project-level CLAUDE.md (or any
> instruction inside the active repository) conflicts with anything here, the project context
> takes precedence. Treat this file as a fallback, not a mandate.

Language-agnostic coding conventions — Core Philosophy, Code Style, Module
Structure, Design Patterns, Architecture, Testing, Documentation, the
always/never-do checklists, and Numeric Precision — live in
`ai_clients/claude/rules/common.md`. It auto-loads (via `paths:` frontmatter)
whenever a source file is touched, so it stays out of the always-on context.
Per-language rules (`python.md`, `bash.md`, …) layer on top. Only genuinely
cross-cutting, non-file-scoped rules remain below.

`rules/*.md` has no equivalent auto-load for skills — a skill is standalone
markdown loaded verbatim by the Skill tool, with no `@import` expansion over
its body. The comment-discipline rule ("an explanation long enough to need a
comment is documentation in disguise") therefore has one home for
skills too: `ai_clients/claude/skills/code-comments.md`, read by every
code-emitting skill via a one-line pointer, the same relationship those
skills already have with `py-standards.md`. Do not restate the rule inline
in a new code-emitting skill — add the pointer instead.

## Dispatching subagents — brief them to commit early

When a task handed to a subagent (or a worktree-isolated agent) is expected to touch
multiple files or take more than a couple of tool calls, its brief must say to commit
at the first coherent point and keep committing — not to save committing for the end.
Measured cost of the opposite (dotfiles-dev#167): three subagents were killed on the
session limit in one afternoon holding 662, 694, and 256 lines of *uncommitted* work
each, rescued only because a human happened to notice before the worktree was torn
down. The loss was never caused by running out of budget — a kill halfway through
costs the same whether it lands at 50% or 90% of the window — it was caused by work
sitting in the worktree, undurable, until the very end.

This prose rule is the probabilistic half of the fix, and prose alone is not enough
(see the `Compaction`/"rule that must fire every cycle" framing below); the
deterministic half is `uncommitted_worktree_guard.sh`, a `Stop` hook that refuses to
end a turn while `git status --porcelain` is non-empty. A **pre-dispatch** "is there
room to finish what I'm about to start?" budget check was considered and deliberately
NOT built: there is no remaining-context-window signal readable from the hook
environment, and a wall-clock/token-percentage alarm was evaluated and rejected — a
90%-alarm narrows the window in which the damage happens without shrinking the damage
itself, and it fires exactly when there is least room left to act.

## Tutoring — resume before replacing

When the user asks to resume/continue tutoring or "pick up where we left off"
(in plain language, not only via `/tutoring on`), find in-progress work before
generating any new curriculum. The `s:tutoring-resume` skill holds the mandatory
discovery sequence (project memory file → active plan → fresh only after explicit
confirmation).

## Lessons — capture and apply

Two lesson systems, both with detailed how-to in the `s:capturing-lessons` skill
(load it the moment you decide something is worth capturing):

- **Corrections log** (`~/.claude/tasks/lessons.md`) — when the user corrects a
  mistake, append an entry before moving on. Surfaced each session by the
  `session_start_context.sh` hook; read and apply entries scoped to the cwd or `global`.
- **Generalizable improvements** — when work yields a reusable seam/tooling/convention/
  guardrail (not a project-specific rule), **capture it before moving on** into the right
  backport store, routed by *where the fix lands*: a scaffolding template →
  BlueprintX store `~/.claude/memory/lessons/`; the Claude/dotfiles toolchain →
  dotfiles-dev store `~/.claude/memory/lessons-dotfiles/`.

Before ending a session, run **`/session-closeout`** (skill `s:session-closeout`). It runs the deterministic
capture audit (`session_capture_audit.sh`) and **fixes** what it finds — the missing lesson,
its index/mirror entries, the unfiled issue, the checkpoint — while the session is still live.
The `SessionEnd` hook runs the same audit but can only **report forward**: it writes unresolved
gaps to a handoff file that `session_start_context.sh` surfaces next session. It never blocks the
exit. The highest-value check is the one nobody remembers: when a session **changes a standing
rule**, grep the tracked docs for the OLD rule — a tracked doc outranks memory next session.

## Compaction

Auto-compact fires natively at **70%** of the context window
(`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE: "70"` in `env`, `ai_clients/claude/settings.json`,
dotfiles-dev#406), not at the near-100% default. Not a `s:dev-loop` step or a
hook: no remaining-context signal reaches a hook environment (dotfiles-dev#167),
and `/compact` is typed by the user, not callable through a tool — this env var
is the only native lever. Verified against the installed binary's own threshold
function (`compactionThreshold = min(floor(window * pct/100), window - buffer)`):
`70` means "compact once 70% of the window is used," not "leave 70% free." The
`env` block is process-wide, so a subagent compacting mid-task still keeps this
priority order below — it inherits the same trigger point as its parent.

When the context window is compacted, apply this priority order:

**Always keep**
- The current task description and its acceptance criteria
- File paths that have been read, created, or modified in this session
- Test results (pass/fail counts, assertion errors, failing test names)
- The current plan or step list and which steps are done vs. pending
- Any explicit user instructions or corrections given during the session
- Final state of any code written or edited (not intermediate drafts)

**Summarise (keep the conclusion, drop the detail)**
- Exploration trails: keep the finding, drop the path taken to reach it
- Tool call chains that produced a single result — keep only the result
- Repeated grep/glob searches — keep the final match, drop earlier misses

**Drop entirely**
- Error messages that have already been resolved
- Superseded approaches, rejected designs, or abandoned file reads
- Intermediate reasoning steps that led to a decision already recorded
- Duplicate information (e.g. the same file path mentioned three times)
- Any raw tool output that was only used to derive a now-recorded fact
