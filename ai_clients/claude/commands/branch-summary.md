---
name: c:branch-summary
allowed-tools: Bash(git log*), Bash(git diff*), Bash(git status*), Bash(git merge-base*), Bash(git branch*), Bash(git rev-parse*), Read, Glob, Grep
description: Summarize all changes on the current branch vs its base
argument-hint: "[--pr] — optional flag to format output as a PR description"
---

You are summarizing all work done on the current branch. Follow these steps exactly.

## 1. Detect branch context

Run these in parallel:
- `git rev-parse --show-toplevel` — absolute repo root; keep it as `$REPO_ROOT` and prefix every
  command below with `cd "$REPO_ROOT" &&` — the harness resets cwd between Bash calls and can
  reset it to a different repo entirely (dotfiles-linux-dev#229)
- `git rev-parse --abbrev-ref HEAD` — current branch name
- `git rev-parse --abbrev-ref --symbolic-full-name @{u}` — tracking remote (may fail if unset)
- `git branch --show-current`

Determine the base branch: try `main`, then `master`, then the default remote HEAD. Compute the
merge base against the **remote** base ref, never the bare local branch name — a stale local
tracking ref silently mis-scopes the diff the same way an implicit `HEAD` does:
- `cd "$REPO_ROOT" && git fetch origin "<base>" --quiet && git merge-base "origin/<base>" HEAD`

## 2. Gather all changes

Run these in parallel using the merge base commit:
- `cd "$REPO_ROOT" && git log <merge-base>..HEAD --oneline --no-decorate`
- `cd "$REPO_ROOT" && git log <merge-base>..HEAD --format="%h %s" --reverse`
- `cd "$REPO_ROOT" && git diff <merge-base>..HEAD --stat`
- `cd "$REPO_ROOT" && git status --short`

## 3. Read key diffs

For files with significant changes (more than a few lines in the stat output), read the actual diff:
- `cd "$REPO_ROOT" && git diff <merge-base>..HEAD -- <file>`

Focus on understanding the intent — what was built, fixed, or changed — not just the line counts.

## 4. Categorize changes

Group every change into one of these categories based on commit messages and diff content:
- **Features** — new functionality
- **Fixes** — bug fixes
- **Refactors** — structural improvements without behavior change
- **Tests** — new or modified tests
- **Docs** — documentation changes
- **Config / Infra** — CI, build, tooling, dependency changes

## 5. Produce the summary

Output a structured summary with:

```
## Branch: <branch-name> (vs <base-branch>)

**Commits:** N | **Files changed:** M

### What this branch accomplishes
<2-3 sentence narrative connecting the individual changes into a coherent story>

### Changes
**Features**
- <bullet> → <file(s)>

**Fixes**
- <bullet> → <file(s)>

**Refactors**
- <bullet> → <file(s)>

(omit empty categories)

### Files touched
<flat list of all modified/added/deleted files>

### Open concerns
- <uncommitted changes, if any>
- <TODO/FIXME comments added, if any>
- <merge conflicts, if any>
```

## 6. PR format (optional)

If `$ARGUMENTS` includes `--pr`, reformat the output as a ready-to-paste PR description:

```
## Summary
<bulleted list of changes>

## Test plan
- [ ] <verification steps based on what changed>

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```
