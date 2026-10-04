# Discovery: scope permissions by directory instead of by command (#163)

**Outcome: no `settings.json` change.** The measurement does not support one —
the premise that motivated the idea (`ask` is redundant with a scope-enforcing
sandbox) does not hold, and the real friction the 72-entry `ask` list causes is
already small. This doc is the written finding the issue asks for when that's
the case.

## What was measured, and how

### 1. The sandbox's real write boundary (empirical, this session)

The issue's central hypothesis was: *"the sandbox already prevents a write
from escaping [the project], so `ask` rules like `rm`/`cp`/`tee`/`sed -i` may
be pure friction with no residual risk."* Tested directly, from inside a
sandboxed Bash tool call (no `dangerouslyDisableSandbox`):

| target | write result | persisted in a **separate**, later Bash call |
|---|---|---|
| inside the repo worktree | succeeded | yes |
| `$HOME` (outside the repo) | succeeded | yes |
| `/tmp` | succeeded | yes |
| `/etc` | **failed** | n/a |

The `/etc` failure was `Permission negada` — an ordinary Unix permission
error for a non-root user writing to a root-owned directory. It has nothing
to do with Claude's sandbox; any unsandboxed shell gets the same result.

**Finding: the sandbox does not scope filesystem writes by location.** A
sandboxed Bash call can write or delete anywhere the OS user already has
permission to — home directory, `/tmp`, the repo, siblings of the repo. The
"sandbox" that the global `CLAUDE.md` warns about is a **narrower, git-specific**
behavior: git ref/object updates can silently fail to persist on overlay
teardown. That is not a general path-scoped write guard, confirmed here by the
fact that plain file writes to the same locations persist normally.

Consequence: **none of the 72 `ask` entries can be justified as redundant with
the sandbox**, because the sandbox provides no location-based enforcement for
`rm`, `cp`, `mv`, `tee`, `sed -i`, `chmod`, `dd`, etc. The "subtract" step in
the issue's checklist has nothing to subtract on this basis.

A second, independent mechanism was also observed and is worth naming because
it's easy to conflate with "the sandbox": this worktree-isolated agent's `git`
invocations are refused outright by a harness-level guard (not a silent
discard) whenever the command's target can't be verified as the agent's own
worktree — e.g. `rtk git status` was refused here with an explicit message.
That's a *different* lever from the overlay-teardown behavior, and it already
does real directory-scoping — but only for `git`, not for the general-purpose
commands the issue is asking about (`rm`, `python3`, `cp`, …).

### 2. How often the 72-entry `ask` list actually fires (static proxy, 10 sessions)

Claude Code transcripts (`~/.claude/projects/.../*.jsonl`) do not log
permission-prompt decisions — there is no `permission_result` or equivalent
field, so **exact historical prompt counts are not recoverable**. That's a
real limitation, stated plainly rather than worked around with a guess.

As a proxy, every `Bash` tool_use command across the 10 available session
transcripts for this project (4,965 transcript lines, 379 sampled commands)
was matched against the literal `ask`/`allow` prefixes in
`ai_clients/claude/settings.json`:

| category | count | % |
|---|---|---|
| matched an `ask` prefix | 10 | 2.6% |
| matched an `allow` prefix | 58 | 15.3% |
| neither (compound/multi-line scripts, `cd` + heredoc + loops, etc.) | 311 | 82.1% |

Of the 10 `ask` matches, **6 were `rtk gh pr merge`** — the friction is
concentrated, not spread evenly across the 72 entries. The remaining 4 were
one each of `chmod`, `rtk git checkout`, `rm`, `python3` — too rare (1 hit
each across 10 sessions) to justify moving to `allow` on frequency grounds,
and each is a real destructive/interpreter class the CLAUDE.md bucket rule
(`ai_clients/CLAUDE.md` point 1–3) already places in `ask` deliberately.

The 82.1% "neither" bucket is **not** evidence of an enforcement gap — it's
an artifact of this proxy only checking whether a command's first line
matches a literal prefix, while real usage is dominated by multi-line/compound
scripts (`cd ... \n <command>`, loops, `&&` chains). Claude Code's actual
permission engine evaluates each simple command inside a compound statement,
not just the first line, so this is a measurement-method gap, not a security
finding — flagged here rather than silently corrected for, since over-claiming
either direction would be worse than an honest "can't fully classify this
proxy-side."

### 3. `gh api` specifically (issue asked to re-examine it)

`gh api` / `rtk gh api` shows up repeatedly across sessions for real,
repository-mutating calls: `-X POST .../requested_reviewers`, `-X PATCH` on
repo settings, and `graphql -f query=...` mutations, plus read-only lookups.
It is reachability to GitHub, entirely outside any local sandbox — the
CLAUDE.md's existing "outward-facing → ask" bucket rule already covers this
correctly. Nothing here supports loosening it; if anything it confirms `ask`
is catching real state-changing calls.

## Why "scope by directory" can't be built as a `settings.json` rule today

Per `ai_clients/CLAUDE.md`: `Bash` permission rules are matched by **string
prefix on the command text only** — there is no `cwd`/target-path dimension
in the matcher. `permissions.additionalDirectories` scopes filesystem *tool*
access (Read/Edit/Write/Glob), not `Bash` commands. So even setting the
sandbox question aside, "only edits in the current project" is not expressible
as a `Bash(...)` allow/ask/deny rule at all — it would require a new
PreToolUse hook (the pattern `destructive_command_guard.sh` and the
worktree-isolation guard already use), which is out of this task's scope
(other agents own hooks and `lib/settings.sh` in this session) and, per the
issue's own "what the answer probably is not" section, isn't warranted by
what was actually measured here.

## Recommendation

- **No change to `ai_clients/claude/settings.json`.** The sandbox does not
  provide the location-scoped enforcement that would justify moving any
  `ask` entry to `allow`, and real usage shows the 72-entry list is already
  low-friction (10/379 sampled invocations) and concentrated on one command
  (`gh pr merge`) that should stay gated regardless.
- **`additionalDirectories` stays unset.** Nothing in this discovery
  identified a legitimate out-of-project *tool* (Read/Edit/Write/Glob) access
  pattern that's currently broken — the out-of-project *writes* the issue
  listed (lesson stores, scratchpad, project memory) all go through `Bash`
  (`echo`, `Write` tool, etc.), which this session's own probe confirmed
  already succeed unprompted from the sandbox for `$HOME`/`/tmp` paths.
- **If prompt-count friction becomes a real complaint later**, the next
  concrete step is not a bigger `allow` list — it's a PreToolUse hook that
  inspects the *target path* of `rm`/`cp`/`mv`/`tee`/`sed -i`/`chmod` (mirroring
  `destructive_command_guard.sh`'s existing precision-over-blanket-deny
  approach) and only prompts when the target resolves outside an explicit
  allowlist of directories. That is a hook change, owned elsewhere, and a
  separate issue.

## How this was tested, given the two stated constraints

- `claude -p` does not enforce `deny` rules, so it was **not** used to test
  any permission behavior — every test here ran as live sandboxed Bash tool
  calls in this interactive session (see the write-boundary table above),
  which does exercise the same sandbox `-p` would skip.
- No `settings.json` edits were made, so the "settings do not hot-reload
  mid-session" constraint doesn't apply — there is nothing to have failed to
  reload.

## Related

- dotfiles-linux-dev#68 — original rationale audit for the `allow`/`ask`/`deny`
  buckets; this discovery does not relitigate it, per `ai_clients/CLAUDE.md`.
- blueprintx#309 — same principle on the CI side: strengthen deterministic
  gates, don't remove checks to remove friction.
- dotfiles-linux-dev#159 / #162 — subagent lifecycle and worktree isolation, whose
  own guard (§1 above) already does real, narrower directory-scoping for
  `git` specifically.
