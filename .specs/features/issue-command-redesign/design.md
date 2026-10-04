# `/issue` redesign — tracker-agnostic, typed, hierarchical

**Date:** 2026-08-04
**Status:** approved design, not yet implemented
**Target:** `ai_clients/claude/commands/issue.md`

## Problem

`c:issue` takes a work item end to end — issue, kanban card, linked branch. Three limits
have shown up:

1. **It hardcodes GitHub.** Every step shells out to `gh`. Meanwhile
   `hooks/branch_requires_issue_guard.sh` already resolves a tracker per repo
   (`github|linear|none`) from `~/.claude/issue-trackers.conf`, and already talks to Linear
   over GraphQL. `/issue` is the only artifact in the chain that cannot follow it.
2. **It only ever creates one flat issue.** GitHub shipped Issues 2.0 (native sub-issues,
   issue types, blocking relations); the installed `gh 2.96.0` exposes `--parent`, `--type`,
   `--blocked-by`, `--blocking`. None of it is used.
3. **The `Backlog` vs `Ready` question is re-judged from scratch every time.** Step 5 asks the
   user to assess three upstreams (why / what / how) in prose, every invocation. The answer is
   derivable if the ticket carries a *work type*.

## Design decisions

### D1 — Two type axes, kept separate

The command currently derives one type (`feat|fix|docs|refactor|test|chore`) and uses it for
the title prefix and the branch name. Wayfinder-style types answer a different question. They
must not be merged.

| Axis | Values | Drives |
|---|---|---|
| **Conventional type** (exists) | `feat` `fix` `docs` `refactor` `test` `chore` | title prefix, branch name |
| **Work type** (new) | `research` `prototype` `grilling` `task` | issue type field, HITL/AFK marker, starting column |

Conventional type says *what the change is*. Work type says *how the ticket gets resolved*.
A `feat` can perfectly well be a `research` ticket.

### D2 — Work type derives the starting column

This is the payoff. The existing why/what/how gate is preserved verbatim in meaning, but
named instead of re-judged:

| Work type | Mode | Column | Open upstream |
|---|---|---|---|
| `research` | AFK | `Backlog` | *how* — approach unproven, but an agent can settle it alone |
| `prototype` | HITL | `Backlog` | *how* — needs a cheap concrete artifact, built with the user |
| `grilling` | HITL | `Backlog` | *what* — no acceptance criteria yet |
| `task` | either | `Ready` | none — all three upstreams cleared, pull-ready |

The step-5 AskUserQuestion becomes a **confirmation of the derived column**, not an open
question. The user can still override to any board column.

### D3 — Linear over GraphQL, not MCP

The Linear MCP server requires OAuth, and once authenticated its tools surface in every
session in every project. `branch_requires_issue_guard.sh` already reaches Linear with
`curl` + GraphQL + `LINEAR_API_KEY`, because a PreToolUse hook is a standalone bash process
that cannot reach an MCP client at all.

`/issue` uses the same path. Consequences:

- Zero standing token cost — `Bash(rtk curl*)` costs nothing when the tracker is `github`.
- One credential (`LINEAR_API_KEY`) serves both the guard and the command.
- No login is ever mandatory.

**Degradation:** when the tracker resolves to `linear` and `LINEAR_API_KEY` is unset, the
command says so plainly and offers `mcp__linear__authenticate` as an explicit, single-session
opt-in. It does not fail silently and does not authenticate on its own.

### D4 — Hierarchy decided inside `/issue`, on a concrete trigger

No separate `/epic` command: it would duplicate the repo-context, board and branch logic.
`/issue` asks about hierarchy only when at least one of these holds:

- `--parent <n>` was passed (file directly as a sub-issue of `<n>`; skip the ask entirely);
- the derived **Escopo** section would carry more than 3 bullets;
- the description names two or more independently shippable deliverables;
- a `s:problem-framing` artifact for this work exists with more than one scope.

Otherwise it creates one flat issue, as today.

### D5 — Parents never get a branch

Step 7 runs for leaf issues only. `branch_requires_issue_guard.sh` would happily allow a
branch cut against a parent issue — the ref is real — but a parent is a container, and a PR
closing it would close the children's tracking with work outstanding.

### D6 — Explicitly out of scope

| Wayfinder idea | Why not |
|---|---|
| The `wayfinder:map` issue as canonical artifact | `s:problem-framing` already owns "what are we building and how big"; a parent issue with sub-issues owns the tracking half. Two overlapping planners is the bloat. |
| "Never resolve more than one ticket per session" | `branch_requires_issue_guard.sh` already enforces one branch per issue. |
| `--blocked-by` / `--blocking` wiring | Native and cheap, but nothing consumes the relation yet. Add when something reads it. |

## New step structure

```
0. Resolve tracker                 NEW
1. Detect workspace context        (today's step 2, moved up — step 2 needs it)
2. Resolve target issue            (today's step 0)
3. Derive title / conventional type / slug
4. Classify work type + HITL/AFK   NEW
5. Decide hierarchy                NEW
6. Create issue(s)
7. Board card + column             (column derived in step 4)
8. Branch                          (leaf only)
9. Report
```

Today's step 0 opens with "run step 2 first" — a forward reference that only worked because a
human read the whole file before executing. Context detection now genuinely precedes the
lookup that needs it, and for `linear` it also resolves the team, viewer id, workflow states
and labels in a single query.

### Argument surface

```
/issue <description | #number | issue-url>
       [--new] [--label <name>] [--project <name|number>]
       [--parent <n>] [--work <research|prototype|grilling|task>]
       [--tracker <github|linear>]
```

`--work` is named to avoid colliding with the conventional type. `--tracker` is a one-shot
override of step 0, mirroring `$CLAUDE_ISSUE_TRACKER`.

### Step 0 — Resolve tracker

Precedence, identical to the guard so the two can never disagree:

1. `--tracker` argument
2. `$CLAUDE_ISSUE_TRACKER`
3. `~/.claude/issue-trackers.conf` — lines `<match>  <github|linear|none>`, first match wins,
   `<match>` tested against the `origin` URL then the repo directory name
4. auto-detect: a `github.com` remote → `github`, else `none`

`none` → stop and point at the conf file. Do not guess.

### Step 4 — Classify work type + mode

Infer from the description, then confirm. Probe issue-type support **once** per repo,
**read-only**:

- `gh issue create --type` requires org-level issue types. Personal-account repos
  (`guilhermegor/*`) may not have them. Never let a mutating command be the probe — `gh issue
  create` creates the issue and resolves `--type` afterwards, so a rejected `--type` exits 1
  with the issue already created, and a retry without the flag files a second one (measured,
  dotfiles-linux-dev#186). Probe with a read-only `gh api graphql` query against
  `repository.issueTypes`, and on an empty/no-match result fall back to a `type:<work-type>`
  label. Linear has no type field either, so it uses the label form too.
- The HITL/AFK mode is always a label (`hitl` / `afk`) on both trackers.

On the **resume** path, read the existing labels/type rather than re-asking.

### Steps 6–8 — per-tracker operations

One spine, a lookup table instead of duplicated prose:

| Operation | `github` | `linear` |
|---|---|---|
| create | `gh issue create --title … --body … --assignee @me` | `issueCreate` mutation; `assigneeId` = viewer |
| hierarchy | `--parent <n>` | `parentId` on `issueCreate` |
| work type | `--type <x>` when supported, else `type:<x>` label | `type:<x>` label |
| mode | `hitl` / `afk` label | `hitl` / `afk` label |
| board | `gh project item-add` + `item-edit` on the `<repo> kanban` board | none — Linear's workflow states *are* the board |
| column | Status single-select option id | `stateId` from the team's workflow states |
| branch | `gh issue develop <N> --name <type>/<N>-<slug> --checkout` | `git checkout -b <type>/<TEAM>-<n>-<slug>` |

**Linear branch names must keep the ref in leading slug position.** The guard's
`linear_ref_in` matches `([A-Za-z][A-Za-z0-9]*)-([0-9]+)`, and `##*/` strips the `<type>/`
prefix first, so `feat/dit-456-add-thing` resolves to `DIT 456`. This deviates from Linear's
own `username/dit-456-slug` convention on purpose — the house `<type>/` prefix is what the
rest of the toolchain reads.

**Linear column mapping.** Query the team's workflow states and map by `type`:
`Backlog` → the `backlog` state, `Ready` → the first `unstarted` state. Do not match on
display name, which teams rename freely.

### Step 9 — Report

Unchanged in shape, plus the two new fields:

```
Mode:    created | resumed
Tracker: github | linear
Issue:   #<N> <url>       (or <TEAM>-<n>)
Type:    <conventional> / <work-type> (<hitl|afk>)
Parent:  #<P>             (omitted when flat)
Board:   <project> → <column>   (omitted for linear)
Branch:  <type>/<ref>-<slug>    (omitted for parents)
```

The `Closes #<N>` PR snippet stays.

## Impact on existing artifacts

| Artifact | Change |
|---|---|
| `hooks/kanban_lifecycle.sh` | **none.** It already no-ops when no `<repo> kanban` board exists, which is exactly the Linear case. |
| `hooks/branch_requires_issue_guard.sh` | **none.** Branch shapes produced here are already covered by `github_ref_in` and `linear_ref_in`. |
| `~/.claude/issue-trackers.conf` | No format change. It currently has no active lines — `ditto  linear` needs uncommenting for that repo to route to the Linear arm. |
| `skills/problem-framing.md` | No change; the seam is unaltered. Worth a one-line cross-reference: a shaped scope becomes a parent issue whose scopes become sub-issues. |

## Verification

The command is a prompt, not code, so verification is behavioural. Minimum checks before
calling it done:

1. `github`, flat, `task` → one issue, `Ready`, branch cut, card on board.
2. `github`, flat, `research` → `Backlog` + `afk` label, column *not* asked open-endedly.
3. `github`, hierarchy → parent + 2 children; parent has **no** branch; child branch cut.
4. `github` repo without org issue types → falls back to `type:` label, no error.
5. `tracker=linear`, `LINEAR_API_KEY` unset → states the situation, offers MCP opt-in, stops.
6. `tracker=none` → refuses, points at the conf file.

Deploy with `make ai_clients` (or `./ai_clients/claude/main.sh slash_commands`) — an edit to
the source file does not reach live `~/.claude/` on its own.

## Sources

- [mattpocock/skills — wayfinder SKILL.md](https://github.com/mattpocock/skills/blob/main/skills/engineering/wayfinder/SKILL.md)
- [Manage sub-issues, types, and dependencies from GitHub CLI — GitHub Changelog](https://github.blog/changelog/2026-06-10-manage-sub-issues-types-and-dependencies-from-github-cli/)
- [cli/cli#13057 — Add Issues 2.0 support](https://github.com/cli/cli/pull/13057)
