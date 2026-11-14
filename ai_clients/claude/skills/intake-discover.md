---
name: s:intake-discover
description: Use when the user asks to find work that was never filed as an issue — "what's fallen through the cracks", "sweep the backlog for unfiled work", "check for drafted-but-abandoned issues", or before running s:intake-refine on a repo that has never been screened this way.
effort: medium
argument-hint: [repo path, default: current repo]
allowed-tools: Bash Read Glob Grep
---

# s:intake-discover

Discovery only. Walk four stores that can hold work which exists but was
never filed, and report what is missing from the tracker as a plain list of
candidates. Do not classify, score, or place a card (that is `s:intake-refine`,
#425) and do not decide what can run in parallel (that is `s:intake-plan`,
#426). Do not auto-file anything — some drafts were superseded on purpose;
a human or `s:intake-refine` decides what to do with each candidate.

Parent: `s:intake` (#422).

**Comment discipline:** read `~/.claude/skills/code-comments/SKILL.md` before
writing anything durable this skill produces (a filed issue body, a report
saved to disk) — an explanation long enough to need a comment is
documentation in disguise; not restated here.

## The four stores, and the question each answers

| store | what hides there | reuse |
|---|---|---|
| `~/.claude/memory/lessons*` | a captured finding never scheduled | `hooks/session_capture_audit.sh` — call it, do not re-derive it |
| `<repo>/.git/*.md` and `.git/*.txt` | a drafted issue/PR body, written and abandoned | walk it yourself (nothing else checks this) |
| `<repo>/.specs/_lessons/` | the generated mirror; a lesson whose origin repo is this one | read-only cross-check against the lessons store above |
| the repo's own tracker convention (`docs/backlog/*.md`, `.specs/features/*/tasks.md`) | a backlog item never turned into an issue | walk it yourself (nothing reconciles this) |

⚠️ **Match by CONTENT, never by filename.** A drafted body's filename tells
you nothing about which issue it became — `issue_rmw.md` matching some
issue's title/body text is the only reliable signal. A convention-based
match silently mis-pairs and reports filed work as missing.

### 1. Lessons — reuse `session_capture_audit.sh`

Do not re-implement the lessons↔issues cross-check; it already audits both
directions (a lesson with no issue reference, and an open issue with no
lesson) and already asks each store's own format the question it can
answer (BlueprintX lessons carry no `PR:` field by design; the dotfiles
store does) rather than a naive shared grep.

```bash
cd /absolute/path/to/<repo> && bash ai_clients/claude/hooks/session_capture_audit.sh
```

(Or, outside dotfiles-dev, the deployed copy: `bash ~/.claude/hooks/session_capture_audit.sh`.)
Read the `--- completeness (both directions...) ---` section. Candidates are:

- every lesson listed under **"genuinely unaccounted"** (no issue/PR ref
  anywhere in the lesson, and no delivered/advisory/superseded Status) — a
  captured finding still owed. A ref counts in any form (`#N`, `repo#N`,
  `pull/N`, a github URL) and on any line, so this list is the true residue,
  not format drift; the **Origin:** line is where the problem was seen and
  never counts as delivery. `lib/lesson_status_backfill.sh` (dry run by
  default) derives the Status of the rest from the forge.
- every issue listed under **"open issues with no lesson"** is the inverse
  finding (an issue with no captured rationale) — out of scope for this
  skill's "unfiled work" question, but worth surfacing alongside it since
  the script already computed it for free.

### 2. `.git/*.md` / `.git/*.txt` — drafted-then-dropped bodies

`pr_template_guard.sh` and `issue_template_guard.sh` refuse a `--body-file`
outside the project directory, so every PR and issue body written by an
agent in this repo lands in `<repo>/.git/`. Nothing tracks which of those
were actually filed.

```bash
cd /absolute/path/to/<repo> && find .git -maxdepth 1 -type f \( -iname '*.md' -o -iname '*.txt' \)
```

For each file found: read its first heading/line as the candidate title,
then content-search both open and closed/merged issues and PRs for a match
— a filed draft is often later closed, so `--state open` alone under-reports:

```bash
cd /absolute/path/to/<repo> && rtk gh issue list --search "<snippet from the file>" --state all
cd /absolute/path/to/<repo> && rtk gh pr list --search "<snippet from the file>" --state all
```

No matching issue/PR title or body text found → candidate: a drafted body
that was never filed (or was filed and then the draft file was never
cleaned up — read both to tell which).

### 3. `.specs/_lessons/` — read-only cross-check, not a new leg

This is the per-repo, git-ignored mirror of lessons whose `Origin:` line
names this repo (`ai_clients/CLAUDE.md` § "Lesson mirrors"). It carries the
same content as store 1, scoped to this repo and faster to `grep` locally.
Use it only to sanity-check store 1's "genuinely unaccounted" list against
a local copy — never as an independent signal, and never hand-edit it:

```bash
cd /absolute/path/to/<repo> && grep -l . .specs/_lessons/*.md 2>/dev/null
```

An unaccounted lesson from store 1 that is *absent* from its mirror here
means the mirror is stale (`make lessons_mirror` / the deployed generator),
not that the lesson doesn't exist — report the staleness, do not drop the
candidate.

### 4. The repo's own tracker convention — backlog files / task lists

```bash
cd /absolute/path/to/<repo> && find docs/backlog -maxdepth 1 -iname '*.md' 2>/dev/null
cd /absolute/path/to/<repo> && find .specs/features -maxdepth 2 -iname 'tasks.md' 2>/dev/null
```

For a backlog file, the whole file is one candidate item. For a
`tasks.md`, only `- [ ]` (not-yet-started) lines are candidates — `[~]` and
`[x]` are already accounted for by the feature's own tracker. Content-match
each candidate the same way as store 2 (`gh issue list --search "..."
--state all`), never by filename or line number.

## Output

Report one list, grouped by store, each line:

```
[store] <snippet or filename> — no match found in issues/PRs (candidate)
[store] <snippet or filename> — matches #<n> (already filed, not a candidate)
```

End with a one-line count per store and a reminder that this is a
discovery report, not a filing action: hand candidates to `s:intake-refine`
(#425) for classification, scoring, and card placement.
