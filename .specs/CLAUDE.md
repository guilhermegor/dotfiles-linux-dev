# .specs/

This is the one home for work-in-flight feature specs and plans in this repo —
what `s:brainstorming` and `s:writing-plans` (the `superpowers` plugin skills)
produce before and during implementation, and what `s:work-breakdown`'s
auto-sizing step (dotfiles-dev#306) produces for a decomposed feature. See
dotfiles-dev#303.

## Top-level allowlist

`.specs/` may contain exactly these entries at its top level — nothing
else, including a change-type folder (`bugfix/`, `chore/`, `feat/`, …; see
"Type-folders are rejected" below). Mechanically enforced by
`tests/check_specs_structure.sh` (dotfiles-dev#443), wired into CI and the
local pre-commit hook.

| Entry       | What it holds                                                    |
|-------------|-------------------------------------------------------------------|
| `CLAUDE.md` | this file — required whenever `.specs/` exists                    |
| `features/` | one directory per unit of work (see "What belongs here" below)    |
| `backlog/`  | cross-feature efforts that map to no single feature (see below)   |
| `_lessons/` | generated lesson mirrors, git-ignored (see below)                 |

## Type-folders are rejected — recorded so this is not re-raised

`bugfix/`, `chore/`, `feat/` and similar change-type folders at the
`.specs/` top level were considered and deliberately **not** adopted
(dotfiles-dev#442):

- `features/` splits on **lifecycle** (design → plan → tasks → PR), not
  change type. Change type is an orthogonal axis, and mixing the two forces
  a choice with no right answer: a bugfix that needed a real design
  document, a chore that produced three PRs.
- The type is already recorded twice — the Conventional-Commit prefix and
  the branch name. A third copy in a path is a third thing to keep in sync.
- A feature directory is not the place to learn what kind of change it
  was — that is what the PR and the commits say.

`tests/check_specs_structure.sh` enforces this by construction: the
top-level allowlist above has no entry for a type-folder, so anything
outside `CLAUDE.md`/`features/`/`backlog/`/`_lessons/` fails — type-folders
included, with no special-casing needed.

## `backlog/` — cross-feature efforts that map to no single feature

Not every piece of work fits `features/<name>/`'s one-unit-of-work shape.
Some records are cross-cutting notes, decisions, or triage items that map
to no single feature. Those live flat under `.specs/backlog/`, one file per
entry — this is distinct from "Backlog / issue-triage notes", which still
routes to `docs/backlog/` (see "What does NOT belong here" below); this
directory is for cross-feature *spec-shaped* records, not triage notes.

**Naming: `<kebab-slug>.md`** — the same convention `features/<name>/`
uses, not the `<topic>_YYYYMMDD_HHMMSS.md` timestamp pattern blueprintx's
migrated backlog files use (blueprintx#575). One naming rule across
`.specs/` is simpler than two to state, follow, and mechanically check, and
dotfiles-dev's own `.specs/backlog/` starts empty — there is no existing
content whose pattern needs preserving. git history already carries the
timeline, the same reasoning `features/<name>/`'s slug-not-date naming
uses below.

## Scaffolded `.specs/` (generated projects) — a different, smaller contract

blueprintx's `templates/common/.specs/` (blueprintx#446) ships `spec.md` +
`features/.gitkeep` to every generated project. That is a deliberately
smaller, different contract from this file's — a generated project has not
adopted the full `CLAUDE.md`/`features/`/`backlog/`/`_lessons/` layout
described here just because it was scaffolded a `.specs/` starting point.
`tests/check_specs_structure.sh` checks dotfiles-dev's own tree only; it is
not run against scaffolded output, so this is stated explicitly rather than
reconciled here (dotfiles-dev#442 non-goal — blueprintx#583 owns the
scaffold-side validator).

## What belongs here

Per feature, one directory: `.specs/features/<feature-name>/`

**Required: at least one of `spec.md`, `design.md`, `plan.md`.** Everything
else below is optional. `tests/check_specs_structure.sh` checks this
mechanically.

- `spec.md` — `s:work-breakdown`'s always-present output: acceptance criteria,
  sized one-liner/brief/full per its auto-sizing table (#306)
- `design.md` — a feature's design decisions: either the `s:brainstorming`
  output, or `s:work-breakdown`'s own Large-scope decisions (#306). Never
  `architecture.md` — it records one feature's decisions, not the system's.
- `plan.md` — the `s:writing-plans` output (a single-agent implementation plan)
- `tasks.md` — the per-feature task tracker; two writers, one file.
  `s:work-breakdown`'s Large-scope per-task breakdown for a decomposed,
  multi-issue feature (#306) — a different shape than `plan.md` — writes it
  up front whenever the feature was split into parallel-dispatchable issues.
  A multi-step effort carried across sessions and subagents is **expected**
  to keep one, updated in the same round that ships each slice. ⚠️ This is
  an enforced check, not only a convention: `s:dev-loop` step 2 (SWEEP)
  runs `gate_missing_tracker` (`ai_clients/claude/hooks/lib/tasks_tracker_gate.sh`,
  dotfiles-dev#485) every round, reporting one line per feature directory
  that has a `plan.md`/`design.md`/`spec.md`, no `tasks.md`, and at least
  one **open** issue or PR mentioning the feature slug — "in-flight by the
  forge, not by the filesystem," since every feature directory in this repo
  has a `plan.md` and the naive "has plan.md, lacks tasks.md" predicate
  fires on all of them at once, including long-finished ones. A finished
  feature with no open issue or PR still naming it is the legitimate quiet
  case: it reports nothing. Report only — the gate never auto-creates a
  `tasks.md`, since its content is judgement an empty file cannot satisfy.
  Not in `docs/`, and not only in a session-local task tool: an account
  switch or session limit erases either of those, but not a file in the
  repo.

  **Status markers** — the same three states as `progress.md` below, plus one
  addition: `[~]` **must name its owner**, as `[~] <branch-or-agent>`. The
  branch name is the durable half — an agent id dies with its session — so N
  concurrent subagents each writing a bare `[~]` recreate the exact collision
  the tracker exists to prevent.

  ⚠️ **A marker is a claim, not evidence — reconcile it against the forge,
  never read it as the answer.** A `[x]` with no merged PR behind it is the
  #509 failure (merged with an empty `closingIssuesReferences`, issue never
  closed) reproduced in a cheaper file. The shipped-check (sibling issue to
  #428) takes the tracker as one input among others, never its verdict.
- `pr.md` — the PR body, written before the PR exists (dotfiles-dev#441
  settled this as `pr.md`'s home). A single PR: `pr.md`. Several PRs from
  one feature: `pr-N-<slug>.md` per PR — the body is written **before** the
  PR number exists, so the filename can't carry it; the number goes on a
  header line inside the file instead (e.g. `# PR 3: <slug>`).
- `progress.md` — **optional**, and unlike the four above it is not written up
  front by a planning skill: the session doing the work writes and updates it
  as the work happens, so an interrupted session can be resumed without
  reconstructing state by inference (#313). Three states, not two:
  `- [ ]` to do, `- [~]` **in progress**, `- [x]` done. `[~]` is the point —
  it is the state git cannot represent. Worth writing for any size of change;
  a three-file fix can have one, a Large feature can go without. Distinct
  from `tasks.md` above: `progress.md` is one session's own resumption
  state and stays optional; `tasks.md` is the cross-session, cross-agent
  tracker `s:dev-loop` requires and reconciles against the forge.

## Lesson mirrors (`_lessons/`) — not a feature directory

`.specs/_lessons/<store>-lessons.md` (e.g. `.specs/_lessons/blueprintx-lessons.md`) is this
repo's git-ignored, GENERATED mirror of a global lesson store
(`~/.claude/memory/lessons*`) — regenerated by `make lessons_mirror`
(`ai_clients/claude/hooks/lib/generate_lesson_mirrors.sh`), never hand-edited
(dotfiles-dev#386). It is **not** a feature directory and follows none of the
`spec.md`/`design.md`/`plan.md` shape above — it is flat, one file per store.

⚠️ This is a deliberate exception to "What does NOT belong here" below, not a
contradiction of it: a mirror is not "documentation" in the `docs/` sense, because
it is a **derived, machine-checked index** of a store that lives entirely outside
this repo (`~/.claude/memory/`) — nobody ships it, nobody reads it as prose, and
it is regenerated on demand rather than authored. `docs/` is for content a human
wrote to be read; `.specs/_lessons/` holds output a script wrote to be `grep`ped.
It also does not "outlive the feature it was written for" in the sense the second
bullet means — it has no feature, it tracks a global store's content over time.
See `ai_clients/claude/hooks/session_capture_audit.sh` (`check_mirrors`) for what
it verifies and `ai_clients/CLAUDE.md` for the full mirror contract.

**Why `_lessons/`, not `lessons/`.** This repo's `.specs/` top level otherwise
namespaces *work units* (`features/<slug>/`); a lessons mirror is neither a
feature nor a project, so it gets the leading-underscore "not a work unit"
marker the greenfield-style repos already use for the same collision
(`_ecosystem/`) — reusing an existing convention rather than inventing a
second one, and it sorts to the top, visually separate from `features/`. And
`_lessons`, not `_mirrors`: the name describes the **content** (lessons), not
the **mechanism** (a mirror) — this very change turns the file from
hand-written to generated, so a name built on "mirror" would describe a
property the change removes.

A repo that has no `.specs/` at all when its first mirror is generated gets
one created for exactly that mirror — approved consequence of generating
mirrors repo-wide (dotfiles-dev#386), not an invitation to also scaffold a
`.specs/CLAUDE.md` there: that contract describes the feature-spec layout
(`spec.md`/`design.md`/`plan.md`) the repo has not adopted just because it now
has a mirror. The generator creates only the `_lessons/` directory it needs.

`design.md`/`tasks.md` are omitted at smaller scope by design (see #306's
sizing table) — that means the decisions stay inline in `spec.md`, not that
they were skipped. `progress.md` is omitted whenever nothing is in flight.

A stale tracker misleads worse than no tracker, so the honesty half is
deterministic: `tests/spec_audit_gate.sh` reports `TRACKER_STALE` when a
`progress.md` carrying a `[~]` is older than the newest commit touching its
feature directory. It is a **finding, not a block** — and a feature with no
`progress.md` is not a finding at all.

`<feature-name>` is a kebab-case slug, not a dated filename — the directory
holds both artifacts for one feature, and git history already carries the
timeline. No feature directories are created by #303 itself; this file only
defines the shape new ones follow.

## What does NOT belong here

- Shipped or reference documentation → `docs/` (see the `_lessons/` exception above
  — a generated mirror is not "documentation" in this sense)
- Backlog / issue-triage notes → `docs/backlog/` (dotfiles-dev#428: measured
  on blueprintx 2026-09-20, `docs/backlog/` had accumulated 44 files despite
  mkdocs' `exclude_docs` hiding them from the published site — the
  accumulation was the defect, the hiding was never the fix. A tracked doc
  outranks memory next session, which is why this routing is written here
  instead of left as a habit to re-litigate)
- Anything meant to outlive the feature it was written for (ADRs, README,
  CLAUDE.md changes) — the `_lessons/` mirrors above are the one exception: they
  outlive not a *feature* but the global store they mirror, which is the point
- An audit-gate verdict — the gate reports to CI, it does not write a file here
  (#305)
- A **cross-feature** progress board (what is dispatched, merged, released) —
  that is `s:dev-loop`'s job, and it is session-shaped, not feature-shaped.
  `progress.md` is deliberately per-feature only (#313).

## What happens to a feature directory once it ships

Undecided — Q-2 in the epic (#302) is still open (does a shipped feature's
`.specs/features/<name>/` get deleted, archived, or left in place; does it
migrate anywhere). Leave existing directories alone until that lands; moving
them now would just relocate the same open question.

## The out-of-repo rule

Not every project gets a `.specs/`. A repo you contribute to but do not
own — did not choose its layout, did not scaffold it, can't add a top-level
directory to it uninvited — does not get `.specs/` added. For that category
of repo, specs live outside it entirely, at
`~/.claude/specs/<repo-slug>/features/<feature-name>/`, using the exact same
`design.md` / `plan.md` shape as above. That is the normal path for those
repos, not a fallback — the value is highest exactly where a fresh session
has the least context to reconstruct, which is precisely the unfamiliar
codebase this rule is for.

**Which of the two locations applies is asked, never inferred** — guessing
wrong is either an unwanted directory in someone else's repo, or a spec
written where nobody will look. The redirect logic that makes this decision
before `s:brainstorming` / `s:writing-plans` write anything lives in
`ai_clients/claude/config/CLAUDE.md` (deployed to every session, not just
this repo) — this file only defines the shape once a location is chosen.

The two locations are deliberately identical in shape: no relative path, no
CI gate, no `make` target may assume the in-repo tree, because any of those
would silently break the out-of-repo case.
