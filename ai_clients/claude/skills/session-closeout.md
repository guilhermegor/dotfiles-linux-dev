---
name: s:session-closeout
description: Use when ending or wrapping up a work session — before /exit or /clear, or when the user asks "did I capture everything?", "safe to end?", "wrap up", "anything I forgot?". Runs the deterministic capture audit and FIXES the gaps (writes the missing lesson, indexes and mirrors it, files the missing issue, updates the checkpoint) while the session is still live — the SessionEnd hook can only report a gap forward, it cannot fix one.
effort: high
argument-hint: [none]
allowed-tools: Bash Read Glob Grep Write Edit
---

> **Priority:** this project's `CLAUDE.md` and `rules/*.md` take precedence over the guidance below whenever they conflict — treat this skill as a fallback, not a mandate.

You are closing out a work session. The question *"did I capture every lesson / issue /
checkpoint?"* is **deterministic and checkable** — do not answer it from memory, because memory
is exactly what is under audit. Run the audit, then **act on every finding while the session is
still live**. This is the fixer; the `SessionEnd` hook is only a safety net that reports gaps
forward to the next session.

## 1. Run the audit

```bash
bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/session_capture_audit.sh"
```

It prints three blocks: **mechanical gaps** (git / lesson-index / mirror — already decided for
you); a **completeness table** (both directions — see step 3); and a **judgment checklist**
(superseded rules / issues-PRs / checkpoint / lesson routing — the script cannot decide these; you
must). Work every line of all three.

## 2. Fix the mechanical gaps

- **`[git] uncommitted changes` / `unpushed commits`** — surface them and ask the user whether to
  commit/push. **Never commit or push without an explicit request** (global rule) — report and let
  them decide.
- **`[git] on branch '…' (not default)`** — remind the user the branch is unmerged; offer to open
  a PR (`s:gh-create-pr`) if the work is done.
- **`[lessons] '<file>' is not in the <store> README index`** — a lesson file exists but is
  unindexed = a lost lesson. Add its one-line index entry to that store's `README.md`.
- **`[lessons] '<file>' … not in .specs/_lessons/<mirror>.md`** — the mirror is GENERATED, never
  hand-appended (dotfiles-linux-dev#386): run `make lessons_mirror` (inside dotfiles-dev) or
  `bash ~/.claude/hooks/lib/generate_lesson_mirrors.sh` (any other repo), then re-run the audit.
- **`[lessons] '<file>' has no **Tier:** line`** — add a `- **Tier:**` line. Tier is an **open
  field**: pick the best fit (`python-common`, `language-common`, `language-specific (<lang>)`, or a
  layout/archetype like `mvc-*`, `ddd-*`, `library`) — and a **new/unknown tier is fine**, never
  reject one against a hardcoded list.

## 3. Resolve the completeness table (both directions)

The audit prints a two-row table — never trust a single number, because a one-directional
lessons→issues check hid an open issue (#75) that had no lesson at all:

```
lessons → issues : <N> in store, <M> reference an issue/PR, <K> unaccounted
issues  → lessons: <I> open, <S> sourced by a lesson, <O> orphan
```

- **`! open issues with no lesson` (row 2 orphans)** — the dangerous side. For each, decide with
  judgment: if it captures a generalizable finding, **write its lesson now** (file + README index +
  mirror, routed by where the fix lands) so the rationale is not lost when the PR closes the issue;
  if it is a plain feature/chore with no lesson, that is fine — leave it. These are candidates, not
  automatic gaps: not every issue is lesson-born.
- **`! lessons with no issue/PR reference` (row 1 unaccounted)** — a captured finding that was
  never scheduled or linked. Add the issue/PR reference to the lesson's `**PR:**` line, or file the
  issue via `/issue` if the work is still open.
- Row 2 prints `skipped` at SessionEnd or without `gh` — that is by design (no network on exit).
  Under `/session-closeout` it runs live; if it shows `skipped` here, note it rather than claiming clean.

## 4. Work the judgment checklist

- **Superseded rules — the highest-value check, and the one nobody remembers.** If this session
  **changed a standing rule**, the new rule got written (memory, lesson) but the **old rule keeps
  living** in whatever tracked doc / README / backlog ledger first stated it — and a tracked doc
  outranks your memory for the *next* session. `grep` the tracked docs for the old rule and delete
  or rewrite it. (A real audit found a revoked "minor-bump every merge" release rule still sitting
  in a tracked ledger; a future session would have read and obeyed it.)
- **Issues / PRs** — every issue created this session is on the repo's board and its card is in the
  right column; open PRs are accounted for. Fix stragglers via `/issue` / `s:gh-create-pr`.
- **Checkpoint** — does the project memory hold a resume point covering this session's work? If not,
  write one so the next session can pick up.
- **Lessons routing** — did any work yield a *generalizable* toolchain/scaffold improvement not yet
  captured? Load `s:capturing-lessons` and route it by **where the fix lands**: a scaffolding
  template → BlueprintX store (`~/.claude/memory/lessons/`); the Claude/dotfiles toolchain →
  Claude-toolchain store (`~/.claude/memory/lessons-claude-toolchain/`). Every lesson needs the file + the
  README index by hand, then the repo mirror **generated** (`make lessons_mirror` or the
  deployed `generate_lesson_mirrors.sh`) — never hand-appended to `.specs/_lessons/`.

## 5. Re-run and report

Re-run the audit from step 1. Report, concisely:
- What you **fixed** (lessons indexed/mirrored, checkpoint written, stale rule removed, …).
- What remains and **needs the user** (uncommitted/unpushed work, an unmerged branch).
- Confirm whether the mechanical block is now clean. Only then is it safe to end.
