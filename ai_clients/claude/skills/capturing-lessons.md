---
name: s:capturing-lessons
description: Use when capturing or writing a lesson — logging a user correction to the project lessons log, or saving a generalizable scaffold/toolchain improvement to a lessons store and deciding which store (BlueprintX, Claude-toolchain, or any other repo) it belongs in. Load it the moment you decide "this is worth capturing", before writing the lesson.
effort: medium
argument-hint: [none]
allowed-tools: Read Glob Grep Write Edit
---

> **Priority:** this project's `CLAUDE.md` and `rules/*.md` take precedence over the guidance below whenever they conflict — treat this skill as a fallback, not a mandate.

Two distinct lesson systems live here. Pick by what you are capturing.

---

## System 1 — Corrections log (`~/.claude/tasks/lessons.md`)

**When:** the user corrects a mistake — wrong approach, wrong assumption, style violation,
misunderstood requirement, etc. Append an entry **immediately**, before moving on. Create the
file and its parent directory if they do not exist.

**Entry template:**

```markdown
## YYYY-MM-DD — <short description of the mistake>

- **Project:** <absolute path of current working directory, or "global" if the user says it
  applies across all projects>
- **Mistake:** <one sentence — what I did wrong>
- **Correction:** <what the user said or did to fix it>
- **Rule:** <an imperative rule that prevents this mistake — "Never…" or "Always…">
- **Why:** <one sentence explaining the underlying reason>
```

**Scope:** default to the current project (absolute path). Escalate to `global` only when the
user explicitly says it applies everywhere.

**Iteration discipline:**
- After writing a lesson, re-read the last five entries for the current project; if any is now
  violated again, add a `**Recurrence:** <date> — still happening` line and tighten the rule.
- If the same mistake recurs **three or more times**, promote it to a top-level rule in the
  project's `CLAUDE.md` (or the global one if scoped globally) and mark the entry
  `**Promoted:** YYYY-MM-DD`.
- Never delete or archive lessons — accumulate them so trends stay visible.

*(Session-start surfacing of this file is emitted by the `session_start_context.sh` hook, not
this skill.)*

---

## System 2 — Generalizable backport stores (capture before moving on)

**When:** work in **any project** yields a *generalizable* improvement — a reusable seam,
tooling, convention, guardrail, command/skill/agent/rule/hook/config/installer change — **not**
a project-specific business rule. Capture it **before moving on**.

There are three stores, two with a fixed backport target and one with none. **Route by where the
fix ultimately lands, never by what the lesson is about.**

### Which store?

- Fix edits a **scaffolding template** under `~/github/blueprintx/templates/` (changes what a
  *generated project* contains — source seams, `pyproject.toml`, `.gitignore`, CI, `Makefile`,
  `.pre-commit-config.yaml`, `mkdocs.yml`, docs, a baked-in convention)
  → **BlueprintX store** `~/.claude/memory/lessons/`.
  Format: `# Title` then `Tier / Lesson / Why / Scaffold into / Origin`. Tier ∈
  `language-common`, `python-common`, `language-specific (<lang>)`, or a scaffolding tier
  (`mvc-*`, `ddd-*`, `react-*`, …). Backport target: `~/github/blueprintx/templates/`.

- Fix edits the **Claude/dotfiles toolchain** under `~/github/dotfiles-dev/ai_clients/claude/`
  (a slash command, skill, agent, rule, hook, global `CLAUDE.md` rule, `settings*.json`, or
  installer — changes how *Claude itself* behaves across every project)
  → **Claude-toolchain store** `~/.claude/memory/lessons-claude-toolchain/`. Named for the
  CONCERN, not a repo (dotfiles-dev#536) — `LESSON_STORES` in
  `ai_clients/claude/hooks/lib/lesson_mirrors.sh` declares its full repo set
  (`dotfiles-dev`, `dotfiles-linux-dev`, `dotfiles-macos-dev`, `dotfiles-linux-prod`)
  explicitly, since the toolchain repo has already been renamed once and the local
  checkout directory may not match the current remote name.
  Format: `# Title` then `Area / Lesson / Why / Apply to (dotfiles-dev) / PR / Origin`.
  Backport target: `~/github/dotfiles-dev/ai_clients/claude/`, each landing via its own PR.

- Fix edits neither of the above — the repo is a standalone project (a scaffolded-but-independent
  app, or a future extraction like the `determinism` package, dotfiles-dev#119) with **no**
  template to re-scaffold from and **no** shared toolchain to reinstall — a fresh environment can
  only inherit the fix by that specific repo being fixed again
  → **third-party store** `~/.claude/memory/lessons-other/`.
  Format: `# Title` then `Lesson / Why / Portable to / Status / Origin`. `Portable to` is
  freeform: name a sibling repo likely to hit the same seam, or `unclear` when none is known yet —
  it exists so a *future* standalone repo can grep for this store's lessons, not because anything
  backports automatically. Backport target: **none** — see the mirror exception below.

**Decision test** — ask *"how does a fresh environment inherit this fix?"*: via **scaffolding a
new project** → BlueprintX; via **reinstalling the Claude toolchain (`make ai_clients`)**,
surviving across all projects → dotfiles-dev; via **neither — only by fixing that one repo again**
→ the third-party store.

A lesson *about* the dotfiles toolchain whose fix lands in a **template** is a **BlueprintX**
lesson; a hook that helps *capture* scaffold lessons is a **dotfiles-dev** lesson. If one
finding needs changes in **both** a template and the toolchain, write **two** lessons, one per
store, cross-referencing. Misrouting parks a fix in a queue that never applies it.

⚠️ **All three stores are global and concurrently written — by other sessions, other projects, at
the same time as you.** Measured 2026-09-13: three different sessions wrote into two of the
stores inside one 40-minute window. Never assume a file you didn't write yourself is idle: before
touching a store's `README.md` or a lesson file, re-read it — a stale in-memory copy from earlier
in the session can silently lose another session's concurrent write when you overwrite the whole
file instead of appending. When *auditing* a store for what changed recently (e.g. deciding what a
given round captured), detect a candidate by **modification time**, then attribute it by
**content** (does it actually name this round's work?) — recency alone attributes other sessions'
lessons to work that never touched them.

### Steps for any store

1. Save it as **one file per lesson** (kebab-case) in the store, using that store's format.
2. Add it to the store's `README.md` index.
3. **Regenerate this repo's mirror — do not hand-write it (dotfiles-dev#386).** The mirror
   (`.specs/_lessons/blueprintx-lessons.md` or `.specs/_lessons/claude-toolchain-lessons.md`) is a
   git-ignored, **generated** index of the lessons whose `**Origin:**` line names this repo —
   run `make lessons_mirror` (inside dotfiles-dev) or
   `bash ~/.claude/hooks/lib/generate_lesson_mirrors.sh` (any other repo) after step 2. It is
   a no-op, correctly, when the origin repo **is** the backport target repo (mirror
   deliberately absent by convention) or when the store is `lessons-other` (no backport
   target other than the origin repo itself, so a mirror there would just restate the file
   already sitting beside it). Never hand-edit a file under `.specs/_lessons/` — it is
   overwritten wholesale on the next regeneration and any hand edit is silently lost.
4. Later, apply the captured lessons to the backport target so future work inherits them — for
   `lessons-other`, this step is a no-op: the origin repo already **is** the backport target, so
   fixing it once already applied the lesson.

Full conventions: `~/.claude/memory/lessons/README.md` and
`~/.claude/memory/lessons-claude-toolchain/README.md`. `lessons-other/` has no README yet (nothing has
been written there) — its format is fully specified inline above; create the README index the
first time a lesson lands there.
