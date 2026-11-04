# Kanban tracker port — design note (dotfiles-linux-dev#889)

Research output. No production code changes; the build is a follow-up.

## Problem

`/issue` and `branch_requires_issue_guard.sh` resolve a tracker per repo
(`github | linear | none`). The board automation does not: `lib/kanban_reconcile.sh`,
`lib/kanban_reconcile_done.sh`, `lib/roadmap_unblock.sh` and `kanban_lifecycle.sh` call
`gh project`, `gh api graphql`, `gh issue` and `gh pr` directly. A Linear-tracked repo gets no
board automation. The rules ("open PR -> In review", "closed -> Done", "No Status -> placed",
"label blocked -> Blocked", "closed blockers -> Ready") are provider-neutral; only reads and moves
are vendor-specific.

## 1. Operations the rules need

Derived from the four files. "Card" = a unit with a status; "column" = an ordered status name.

| # | Operation (port verb) | Used by |
|---|---|---|
| 1 | `board_resolve OWNER REPO` -> opaque board handle on stdout; rc 3 = no board, rc 1 = ambiguous/unreadable (reason on stderr) | all |
| 2 | `board_columns HANDLE` -> ordered column names, left to right | reconcile, done (rank: never move backwards) |
| 3 | `board_cards HANDLE` -> non-Done cards: `id, issue_ref, status, labels, blocked_by_text, url` | reconcile, done, unblock |
| 4 | `card_move HANDLE CARD COLUMN` | all four |
| 5 | `card_find HANDLE ISSUE_REF` -> card id (lifecycle hook only) | lifecycle |
| 6 | `issue_state REF` -> `open|closed|unknown` | lifecycle, done, unblock (`_ru_ref_state`) |
| 7 | `open_issues OWNER REPO` -> `ref, state, labels` | done |
| 8 | `pr_linked_issues OWNER REPO` -> for each open PR, the issues it closes | reconcile |
| 9 | `pr_state REF` -> `open|closed|merged` | done (`_krd_pr_state`) |
| 10 | `issue_blockers REF` -> native blocker refs + state | unblock (`_ru_native_blockers`) |
| 11 | `issue_label_swap REF ADD REMOVE` | unblock (`state:ready` / `state:blocked`) |
| 12 | `issue_note REF TEXT` (idempotent: skip if exact text present) | unblock |
| 13 | `card_blockers_clear HANDLE CARD` (clears the free-text blocker record, whatever form the provider keeps it in) | unblock |
| 14 | `throttled?` -> budget/backoff signal | reconcile (`_board_throttled`) |

Not tracker operations, stay in the rules: `git ls-remote` for pushed branches, dispatch claims,
`decision:` prefix handling, rank comparison, report formatting, fail-closed-per-item behaviour.

## 2. Mapping

| Port verb | GitHub ProjectV2 (today) | Linear |
|---|---|---|
| board_resolve | `gh project list` -> title `<repo> kanban`; cache id + Status field id + option ids | Team resolved from `issue-trackers.conf` key; handle = team id **plus a repo scope** (conf `project=` or `label=`; required when the team spans several repos, else rc 1). The issue IS the card, no board object. |
| board_columns | Status single-select options (`gh project field-list`) | `team.states` ordered by `type` (`backlog < unstarted < started < completed`), then `position`. Canceled excluded. |
| board_cards | `gh project item-list` (or one GraphQL fallback) | `issues(filter:{team, <repo scope>, state:{type:{nin:[completed,canceled]}}})`, paginated |
| card_move | `item-edit --single-select-option-id` | `issueUpdate(id, stateId)` |
| card_find | scan item-list for issue number | identity: card id == issue id |
| issue_state | `gh issue view --json state` | `state.type in (completed, canceled)` = closed. Treating `canceled` as closed is a deliberate choice (a canceled blocker unblocks its dependents, like GitHub "closed as not planned"), not a mechanical mapping. |
| open_issues | REST `issues?state=open` | same query as `board_cards` (folds into it) |
| pr_linked_issues | GraphQL `closingIssuesReferences` | Linear attachments of source `github` on the issue (PR url + state), inverted; or `issue.attachments`. Linear's own GitHub integration auto-moves on PR events, so many of these rules become no-ops there (see Q3). Attachments for every issue are an extra nested fetch; see Q7. The reverse direction (PR body/branch citing `ACME-123` rather than `#N`) is a build-time question. |
| pr_state | REST `pulls/N` | attachment metadata, else `gh pr view` on the PR url (PRs stay on GitHub even when the tracker is Linear) |
| issue_blockers | REST `dependencies/blocked_by` | `issue.inverseRelations(filter:{type:{eq:"blocks"}})` (the issues that block THIS one; `relations` is the opposite direction), native, one call per issue or batched in the list query |
| issue_label_swap | `gh issue edit --add/--remove-label` | `issueUpdate(labelIds)` (needs label id lookup, cached with the board handle) |
| issue_note | `gh issue comment` | `commentCreate` |
| card_blockers_clear | `item-edit --field "Blocked by" --clear` | no project field; the "Blocked by" text lives in the issue description. rc 3 on Linear, the native relation is authoritative. |
| throttled? | fresh `rateLimit` GraphQL probe | `X-RateLimit-*` response headers / complexity budget; same boolean contract |

Column-name semantics. The rules speak the repo's column vocabulary (`Backlog, Ready, In progress,
In review, Blocked, Done`). Linear has typed states with free names. The adapter owns a name map:
rules ask for a **role** (`ready`, `in_progress`, `in_review`, `blocked`, `done`), the adapter maps
to a column name (GitHub: the literal Status option, found by name as today) or a state id
(Linear: `ready` = first `unstarted`, `in_progress` = first `started`, `done` = first `completed`).
Linear has no `in_review` or `blocked` type: both would collapse onto a `started` state, so those two
roles **require** a name override in the conf; without one the verb returns rc 1 (never a type
fallback). Rank is by position, never by name.

## 3. Proposed seam

```
hooks/lib/tracker/port.sh        # dispatcher + contract doc, ~60 lines
hooks/lib/tracker/github.sh      # today's gh code, moved, not rewritten
hooks/lib/tracker/linear.sh      # GraphQL via curl + LINEAR_API_KEY
hooks/lib/tracker/none.sh        # every verb returns "not applicable" (rc 3)
hooks/lib/kanban_reconcile*.sh   # rules; call tracker_<verb> only
```

- `port.sh` exposes `tracker_resolve` and `tracker_<verb>`; it validates `TRACKER` against
  `github|linear|none` first (anything else -> `none`), `source`s the one adapter file chosen once and
  defines each `tracker_<verb>` as a thin forward (`"${TRACKER}_<verb>" "$@"`). Bash-native, no
  registry, no plugin loader. Every adapter function and helper carries its adapter prefix
  (`github_*`, `linear_*`, `_github_*`): `linear.sh` sources `github.sh` for `pr_*`, so unprefixed
  helpers such as `_board_*` would silently override each other.
- Rules never contain `gh`, `graphql`, `ProjectV2`, `stateId`. A word-bounded grep (`\bgh\b`, not
  bare `gh`, which matches `through`) for those tokens outside `tracker/` is the enforceable
  boundary test (one bats case).
- **Resolution** reuses the existing precedence verbatim, extracted once into
  `hooks/lib/tracker/resolve.sh` and sourced by the guard, the reconcile entry points, and
  documented as the single owner (so `/issue` stays prose but cites the file):
  `--tracker` (a `/issue` flag, absent in hook context) > `$CLAUDE_ISSUE_TRACKER` >
  `~/.claude/issue-trackers.conf` (substring match on origin URL then dir name, first wins) >
  `github.com` origin -> `github` > `none`. Substring matching is fine for a guard that allows on
  unknown but not once the same resolver drives board writes (`acme` would match `acme-tools`):
  `resolve.sh` matches whole path segments for the reconcile entry points (follow-up 1).
  Today `resolve_tracker` is a function inside `branch_requires_issue_guard.sh`; moving it is the
  only edit to that file.
- **Contract kept**: every verb returns rc 0 ok, rc 1 unreadable (rules map this to the
  existing `unknown` / fail-closed branch), rc 3 not-applicable (`none`, or Linear for
  `card_blockers_clear`). Rules treat rc 3 as success for an idempotent write and as a skip for a
  read; only rc 1 is the fail-closed branch. Output is TSV, one record per line, so rules stay `read`-loops. The
  `RECONCILE_*_STATUS/REPORT` globals do not change.
- **Migration**: GitHub first, behaviour-preserving, because the 3 existing bats files
  (`kanban_reconcile*.bats`, `roadmap_unblock.bats`, `kanban_lifecycle.bats`) stub `gh` and are the
  regression net. Linear adapter second, tested with a stubbed `curl`.
- Throttle/fallback machinery (`_board_item_list`, `_board_throttled`) is GitHub-internal and moves
  wholly into `github.sh` behind `board_cards`; rules only see "cards or rc 1".

## 4. Open questions, resolved

1. **One verb set or per-rule adapters?** One. 14 verbs cover all four files; no rule needs a
   vendor-shaped call. Fewer than the sum of the call sites because `open_issues` folds into
   `board_cards` on Linear.
2. **Is there a Linear "board" to discover?** No, by design. `board_resolve` returns the team id;
   `card_find` is identity. Same verbs, trivial Linear bodies. No Linear project/cycle concept is
   introduced.
3. **Do the rules even apply to Linear?** Partly. Linear's GitHub integration already moves issues
   on branch/PR events, which is what `kanban_lifecycle.sh` does for GitHub. **OPEN, owner decision needed**: proposed that the
   lifecycle hook is **GitHub-only** for now (`tracker_resolve` = `linear` -> exit 0 silently
   unless `LINEAR_KANBAN_HOOKS=1`); the **reconcile** (recovery for missed events) ports, because a
   missed integration event has no other recovery. Revisit if the integration is found reliable.
4. **Auth from a hook.** MCP is unreachable from a hook (same finding as the guard). Linear adapter
   needs `LINEAR_API_KEY`; absent -> every verb rc 1 -> reconcile reports `unknown`, never a
   silent skip and never a guess. Matches the guard's "upgrade only when key set" stance, except the
   guard may allow-on-unknown while reconcile must not move on unknown. The report says
   "tracker unauthenticated" once, not one `unknown` line per card.
5. **Column naming.** Roles via adapter map (section 2); the conf gains an optional trailing
   `key=value` list for Linear overrides, e.g. `acme.linear  linear  team=ACME project=dotfiles in_review="In Review" blocked="Blocked"`.
   The existing two-field lines stay valid (the guard ignores extra fields).
6. **Blocked by (text field) vs relations.** GitHub keeps both (field + native). Linear is native
   only; `decision:` blockers move to a label (`decision`) on Linear since there is no text field.
   Rule behaviour unchanged: a decision blocker is never auto-cleared.
7. **Rate budget.** Linear counts complexity, not GraphQL points; the port's `throttled?` verb
   hides which. The "one board read per round" budget carries over: `board_cards` is one paginated
   query per round, **not** guaranteed: attachments + labels + relations nested in one query can
   exceed the complexity limit and force small pages, or need an extra fetch per issue; measure in
   the build prototype. Expect a race with Linear's own integration moving the same card; the
   never-move-backwards rank guard is the only protection, so it needs the role map above.
8. **PRs stay on GitHub.** A Linear-tracked repo is still hosted on GitHub; `pr_*` verbs call `gh`
   in the Linear adapter by delegating to the GitHub adapter's PR functions (source both; the
   linear adapter does not re-implement PR reads). This is the one allowed adapter-to-adapter
   dependency, limited to `pr_*`.

## 5. Prototype

None built. The mapping is mechanical and the one thing that could be wrong (state ordering by
`type` then `position`) is already what `/issue` queries (`states{ nodes{ id name type position } }` in the `/issue` command).
A prototype is only warranted in the build issue, against a real Linear team.

## 6. Follow-up issues to file

1. Extract `resolve_tracker` to `hooks/lib/tracker/resolve.sh` (+ guard sources it). Small.
2. Introduce `port.sh` + `github.sh` by moving existing code; rules switch to verbs; add the
   "no vendor tokens outside `tracker/`" bats test. Behaviour-preserving.
3. `linear.sh` + stubbed-`curl` bats; conf `key=value` overrides; docs in `ai_clients/CLAUDE.md`.

Risk: step 2 touches the files under active concurrent edits (#567-style conflicts); sequence it
after open reconcile PRs land.
