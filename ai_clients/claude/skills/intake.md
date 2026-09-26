---
name: s:intake
description: Use when unfiled or unrefined work needs to become a dispatchable
  queue before a development round — "what's fallen through the cracks",
  "sweep the backlog before we dispatch", "get the queue dispatch-ready", "what
  can we run in parallel right now" — or right before s:dev-loop's DISPATCH
  step. Screens three global stores into a refined, planned queue; dev-loop
  consumes the queue but does not collect it.
effort: medium
argument-hint: [owner/repo, default: current repo] [--quick]
allowed-tools: Skill Read
---

# s:intake

Orchestrator only. `s:intake` carries no screening logic of its own — it
sequences four already-shipped skills and hands their combined output to
`s:dev-loop`'s DISPATCH step. dev-loop's boundary is to *develop* an
already-dispatchable queue (rescue, sweep, threads, re-run, release, dispatch,
capture); it must not be the one going looking for unfiled or unscored work —
the stores this skill reads have nothing to do with a development round.

⚠️ dotfiles-dev#179 measured **14 of 14** by-product issues in one session
bypassing `/issue` via bare `gh issue create` — a command that must be
remembered is a command that is not run. Composing skills that load on their
own trigger, rather than a slash command an operator has to type, is the
existing house precedent (`s:dev-loop` step 7 loads `s:capturing-lessons`;
`/issue` step 5a loads `s:story-score`) — this skill follows the same shape.

**Comment discipline:** read `~/.claude/skills/code-comments/SKILL.md` before
writing anything durable this skill or any child it calls produces — not
restated here.

## 🔴 Reuse, never re-derive — four children already own the logic

Load each via the Skill tool, in this order:

| order | skill | issue | question it answers |
|---|---|---|---|
| 1 | `s:intake-discover` | #424 | what exists but was never filed? |
| 2 | `s:intake-refine` | #425 | what's filed but not dispatchable? |
| 3 | `s:intake-shipped` | #427 | is this candidate already on `origin/master`? |
| 4 | `s:intake-plan` | #426 | what can run simultaneously, right now? |

## 1. Discover — `s:intake-discover` (#424)

Load it. It walks the four unfiled-work stores and reports candidates,
grouped by store, each either matched to an existing issue or flagged as
missing. **It does not file anything** — that boundary is stated in its own
Output section, not a gap this step closes silently.

⚠️ **A discovered candidate is not yet input to step 2.** `s:intake-refine`
only screens issues already on the tracker (its own § 1 reads open issues,
not scratch files). A "no match found" candidate needs a human, or a future
`/issue`-driven filing pass, to become an issue before refine can act on it —
**report every such candidate by name and stop there**; do not invent a
filing step this skill was never asked to own (`/issue` is user-invoked only,
`ai_clients/CLAUDE.md` § 3 vs § 1 — the same limit `s:intake-refine` already
states about its own step 5a).

## 2. Refine — `s:intake-refine` (#425)

Load it, passing the same `owner/repo` (and `--quick` if the caller asked for
it). It closes every dispatch-blocking gap — work type, mode, oracle
strength, score, board card — on every open, unclaimed issue, using
`c:issue` steps 4/5a/7 and `s:story-score` exactly as it documents. A `SPLIT`
row it reports is not applied automatically; carry it forward for the
operator to re-file via `/issue`, per its own Output section.

## 3. Shipped check — `s:intake-shipped` (#427), applied per refined issue

Before handing the refined queue to the concurrency planner, content-test
each candidate's deliverables against `origin/master` — a `partially
shipped` or `shipped` issue burns a planning slot, and worse, a dispatch
slot, for work already on the default branch (its own header: two
orchestrator sessions on blueprintx, 2026-09-20, hours apart, each trusting a
cheap substitute for this exact question).

Load `s:intake-shipped` once per candidate from step 2's output, never in
bulk — its own Non-goals: never derive a whole-issue verdict from testing
one deliverable when the issue names several.

- `shipped` → drop the candidate from the queue; report it as closeable, do
  not close it yourself (its own step 4: report and stop).
- `partially shipped (N of M)` → keep the candidate, but pass only the
  missing slice's surface to step 4 — planning the original full surface
  would claim files that are already merged.
- `not shipped` → pass through to step 4 unchanged.

## 4. Plan — `s:intake-plan` (#426)

Load it, passing the survivors of step 3. It parses each candidate's
` ```surface ` block, classifies against `free_classify_files`, resolves
collisions between candidates (not just against open PRs), caps the round by
the measured API budget, and prints the dispatch plan in its own documented
shape (`ELIGIBLE` / `BLOCKED-ON-OWNER` / `EXCLUDED`).

## Output

Print, in order: step 1's discovery report, step 2's applied-classification
table, step 3's per-candidate shipped verdicts, step 4's dispatch plan — then
stop. **This skill never dispatches.** The same refusal `s:intake-plan`
already states applies one level up: `s:dev-loop`'s DISPATCH step reads the
plan and decides what actually runs.

## Non-goals

- Does not implement discovery, classification, shipped-testing, or
  collision planning itself — see the reuse table above.
- Does not file a discovered-but-unfiled candidate — flag it and stop.
- Does not dispatch agents, open branches, or write briefs.
- Does not run inside `s:dev-loop`'s seven steps — it is the thing that runs
  *before* dev-loop, producing the queue DISPATCH consumes. A one-line
  pointer belongs in `s:dev-loop` naming this skill as its upstream and
  stating dev-loop does not collect; that edit is tracked separately (see
  this skill's own PR description for why it isn't in this diff).

## Documentation

The measured counts behind each child's own rules (10/41 unclaimed, 31/41
zero-labelled, the API-budget derivation, the single-writer contention rule,
the ancestry/branch-existence/diff-emptiness/PR-list failure table) stay in
their own files — this file states only the order they run in and what each
hands to the next.
