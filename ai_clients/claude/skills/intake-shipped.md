---
name: s:intake-shipped
description: Use when an issue is about to be closed, reported as unshippable
  cruft, or dispatched to a subagent — content-test whether its deliverables
  are already on origin/main before acting, instead of trusting ancestry,
  branch existence, diff-emptiness, or the PR list.
effort: medium
argument-hint: [issue-number] [repo]
allowed-tools: Bash(gh issue view*) Bash(gh pr list*) Bash(git show*) Bash(git cat-file*) Bash(git rev-parse*) Read Grep
---

> **Priority:** this project's `CLAUDE.md` and `rules/*.md` take precedence over the
> guidance below whenever they conflict — treat this skill as a fallback, not a mandate.

**Comment discipline:** read `~/.claude/skills/code-comments/SKILL.md` before writing
any code this skill produces or edits.

## The rule

**There is no local proxy for "did this ship?"** Every cheap substitute answers a
different question and each produces a plausible, wrong number (dotfiles-linux-dev#427,
parent #422, both measured on blueprintx 2026-09-20, hours apart):

| substitute | why it lies |
|---|---|
| `git merge-base --is-ancestor <sha> origin/main` | a squash merge writes a NEW commit; a shipped branch is **never** an ancestor. Measured: reported NO for a fix that was on main, and a duplicate follow-up PR was half-built on that answer before `git cherry-pick` said "nothing to commit". |
| `git ls-remote --heads origin <branch>` | `delete_branch_on_merge` removes the branch for merged work too. Flagged 50+ worktrees as "gone" that had, in fact, shipped. |
| `git diff origin/main..HEAD` non-empty | main has moved on with everyone else's work; a merged branch still diffs non-empty forever. |
| the PR list / `closingIssuesReferences` | PR #509 delivered most of #355 and merged with `closingIssuesReferences = []` — the link that would tell you does not exist. Reliable evidence of PRESENCE only, never of absence. |

The only thing that answers the question is a **content probe against
`origin/master`**: does the deliverable's file exist there, and if it's a
behavior (a gate wired into CI, not just pre-commit) does the content match.

⚠️ **Report per slice, never a single verdict.** An issue with three deliverables
where two are on `origin/master` and one is not is `partially shipped (2 of 3)`,
listing the missing one by name — never "shipped" and never "not shipped". The
same blueprintx session that measured the table above also measured the
opposite failure: an orchestrator content-tested **one** of #355's three
slices, declared the whole issue "already on main, just needs closing," and
would have shipped a one-legged CI gate to every generated project had the
third slice not been checked.

## Procedure

Every command below names its target explicitly — absolute `cd <worktree-path> &&`
for the directory, `origin/master` (or the repo's actual default branch) for the
ref, never a bare local branch or an implicit `HEAD` (dotfiles-linux-dev#229).

1. **Extract deliverables from the issue body**, not just its `File surface`
   block — that block is a surface, not the full claim. Read the body for
   concrete file paths, function/symbol names, and gate names (a check wired
   into a specific CI job, not just "a script exists somewhere").
   ```bash
   cd <worktree-path> && rtk gh issue view <N> --repo <owner>/<repo>
   ```
2. **Fetch and content-test each deliverable against the repo's default
   branch** — resolve it explicitly first (never assume `master` vs. `main`;
   `shipped_check.sh` below does this for you via `refs/remotes/origin/HEAD`):
     ```bash
     cd <worktree-path> && /usr/bin/git fetch origin --quiet && \
       base_ref="$(/usr/bin/git symbolic-ref --quiet --short refs/remotes/origin/HEAD)"
     ```
   - A path deliverable: does it exist there at all?
     ```bash
     cd <worktree-path> && /usr/bin/git cat-file -e "$base_ref:<path>" && echo PRESENT || echo MISSING
     ```
   - A behavior deliverable (a gate wired into CI, a function actually called,
     not merely defined): grep the file's content on that branch, not just
     confirm the file exists.
     ```bash
     cd <worktree-path> && /usr/bin/git show "$base_ref:<path>" | grep -E '<symbol-or-wiring>'
     ```
   - If `ai_clients/claude/hooks/lib/shipped_check.sh` is available (it is, in
     this repo), source it instead of hand-rolling the above — it also folds
     in the `closingIssuesReferences` supplementary check and fails closed to
     `UNKNOWN` on any `gh`/`git` read error:
     ```bash
     cd <worktree-path> && source ai_clients/claude/hooks/lib/shipped_check.sh && \
       shipped_check <N> <owner>/<repo> "<path1>" "<path2>::<pattern>" && \
       echo "status=$SHIPPED_STATUS"$'\n'"$SHIPPED_DETAIL"
     ```
3. **Roll up per-deliverable results into one of three verdicts**, always
   naming which deliverables landed in which bucket:
   - `shipped` — every deliverable present.
   - `partially shipped (N of M)` — some present, some missing; list the
     missing ones by path/symbol.
   - `not shipped` — none present.
4. **Report and stop. Do not close the issue.** Closing is the operator's or
   `s:dev-loop`'s call, informed by this report — this skill is a content
   test, not an action.

## Non-goals

- Never use ancestry (`merge-base --is-ancestor`), remote-branch existence
  (`ls-remote`), or diff-emptiness as evidence — see the table above.
- Never derive a whole-issue verdict from testing one deliverable when the
  issue names several.
- Never auto-close. Report the verdict and hand it off.
