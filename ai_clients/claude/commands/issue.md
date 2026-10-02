---
name: c:issue
allowed-tools: Bash(rtk gh issue*), Bash(rtk gh pr view*), Bash(rtk gh project*), Bash(rtk gh repo*), Bash(rtk gh api*), Bash(rtk git*), Bash(rtk proxy curl*), AskUserQuestion, Read, Grep, Skill
description: Create or resume a tracked issue (assigned to you), add it to the kanban, and open a linked recommended-name branch
argument-hint: "<description | #number | issue-url> [--new] [--quick] [--parent <n>] [--work <type>] [--label <name>] [--project <name|number>] [--tracker <github|linear>]"
---

You are taking a work item end to end: an issue, its kanban card, and a linked branch — the
authoring half of a Linear-style flow. This command only sets the card's *starting* column
(step 7); the runtime transitions are then automatic and NOT set here:

- **In progress** (on branch open) and **In review** (on PR open) are driven by the
  `kanban_lifecycle.sh` PostToolUse hook — GitHub Projects' native workflows cannot trigger
  on those events.
- **Done** is driven by GitHub Projects' own "item closed / PR merged → Done" workflow (the
  `Closes #N` link in step 9 feeds it). GitHub can silently drop that link
  (`closingIssuesReferences: []`), so after `gh pr create` run
  `gh pr view <n> --json closingIssuesReferences` and warn when empty. A repo-level
  `close-linked-issues` workflow (guilhermegor/blueprintx#604) closes the issue from the
  branch name and complements — never replaces — this native workflow.

Follow these steps exactly. `$ARGUMENTS` holds an issue reference *or* a work description,
plus optional flags.

**`--quick`** exists for the by-product case: an issue that surfaces mid-round, not the
task at hand (dotfiles-dev#179 — measured 14/14 such issues on one session bypassing this
command entirely via bare `gh issue create`, so step 4's classification table never ran
and no card was ever placed). `--quick` keeps that classification reachable without the
full interactive cost: it requires `--work <type>` (step 4's ask is already skipped by
`--work` alone), forces a flat issue (step 5's ask never fires), and skips step 8 (no
branch — you are not switching context to this work now). Title/slug inference, the
issue create, and the board-card column set (step 7) all still run. If `--quick` is
passed without `--work`, stop and ask for the work type — never default it silently.

## Three axes — never conflate them

| Axis | Values | Drives |
|---|---|---|
| **Conventional type** | `feat` `fix` `docs` `refactor` `test` `chore` | title prefix, branch name |
| **Work type** (`--work`) | `research` `prototype` `grilling` `task` | issue type field, HITL/AFK label, **starting column** |
| **Oracle strength** | `oracle:strong` `oracle:weak` | which runtime may take it — **independent of HITL/AFK**, see step 4 |

Conventional type says *what the change is*. Work type says *how the ticket gets resolved*.
Oracle strength says *who may resolve it*. A `feat` is perfectly able to be a `research` ticket,
and a `task` that is `afk` may still be `oracle:weak` — nobody needs to watch it, and it still
must not go to a cheaper model, because nothing would catch a wrong answer.

## 0. Resolve the tracker

Precedence — identical to `branch_requires_issue_guard.sh`, so hook and command can never
disagree about a repo:

1. `--tracker <github|linear>` in `$ARGUMENTS`
2. `$CLAUDE_ISSUE_TRACKER`
3. `~/.claude/issue-trackers.conf` — lines `<match>  <github|linear|none>`, first match wins.
   `<match>` is a substring tested against the `origin` remote URL first, then the repo
   directory name. Read it with the **Read** tool; `#` and blank lines are comments.
4. auto-detect: a `github.com` origin → `github`, otherwise `none`.

`none` → **stop.** Say the repo has no tracker configured and point at
`~/.claude/issue-trackers.conf`. Do not guess a tracker and do not create anything.

`linear` → check `LINEAR_API_KEY` is set (`printf '%s' "${LINEAR_API_KEY:+set}"`). If it is
**not**, stop and say so, then offer exactly two ways forward — never authenticate on your own:

> This repo tracks in Linear, but `LINEAR_API_KEY` is unset, so I cannot reach the API.
> Either export a Linear personal API key (the same one
> `branch_requires_issue_guard.sh` uses), or say the word and I will run
> `mcp__linear__authenticate` for this session only.

All Linear API calls in this command go through `rtk proxy curl` — **raw, unfiltered**, because
the responses are JSON parsed by `jq` and the token-filtering proxy would corrupt them:

```
rtk proxy curl -sS --max-time 15 -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" -H 'Content-Type: application/json' \
  --data "$(jq -n --arg q '<query>' --argjson v '<variables>' '{query:$q,variables:$v}')"
```

Never use the Linear MCP server here. It requires OAuth and, once authenticated, its tools
surface in every session of every project — a standing token cost for a command that is mostly
run against GitHub.

## 1. Detect workspace context

**github:** `rtk gh repo view --json name,owner,defaultBranchRef` → `name` (repo),
`owner.login`, `defaultBranchRef.name` (base branch).

**linear:** resolve the team. Take the key from `--tracker`'s companion if given, else the
`issue-trackers.conf` match, else ask. Then one query for everything downstream needs:

```graphql
query($k:String!){ viewer{ id }
  teams(filter:{key:{eq:$k}}){ nodes{ id key name
    states{ nodes{ id name type position } }
    labels{ nodes{ id name } } } } }
```

Keep `viewer.id` (the assignee), the team id, its workflow states and its labels.

## 2. Resolve the target issue

The issue may already exist. This step decides; everything after is either *create* or *resume*.

If `$ARGUMENTS` has no description and no reference, ask the user what the work is.
If `--new` was passed, skip straight to step 3 (create path).

| `$ARGUMENTS` looks like | Action |
|---|---|
| `#42`, `42` | **github:** `rtk gh issue view 42 --repo <owner>/<repo> --json number,title,url,state,labels` |
| `ABC-42` | **linear:** query `issues(filter:{team:{key:{eq:"ABC"}},number:{eq:42}})` |
| a URL ending `/issues/42` | as above, using the owner/repo **from the URL** |
| anything else | search (below) |

**Search path.** Treat the text as a query, not a title:

- **github:** `rtk gh issue list --repo <owner>/<repo> --state all --search "<text>" --json number,title,url,state --limit 10`
- **linear:** `issueSearch(query:"<text>", first:10){ nodes{ identifier title url state{ name } } }`

Then:

- **Exactly one hit whose title clearly covers the request** → confirm with AskUserQuestion
  ("Resume `#<N> <title>`?" / "No — create a new issue"). Never adopt an existing issue silently.
- **Two or more plausible hits** → AskUserQuestion listing the top 3 as
  `#<N> — <title> (<state>)`, plus a final **"None of these — create a new issue"** option.
  Order by relevance as returned; prefer open over closed when scores are close.
- **Zero hits** → say so in one line and fall through to the create path.

**`--quick`** skips this whole search-and-confirm dance — go straight to the create path
unless `$ARGUMENTS` is itself an explicit reference (`#N`, a bare number, or an issues URL).

Once resolved to an existing issue:

- If it is closed, ask whether to reopen (`rtk gh issue reopen <N>` / `issueUpdate` with the
  team's first `backlog` state) or create a new one. Do not reopen without an answer.
- Skip steps 3–6. Keep the existing title/body. Derive the **slug** from its title and the
  **conventional type** from its `<type>:` prefix (default `feat`). Read the **work type** and
  **mode** from its existing type field or `type:` / `hitl` / `afk` labels rather than re-asking.
- **Check for an existing score, never left blank.** A score already present is kept — never
  re-derived or overridden here. One that is absent runs step 5a before anything else proceeds:
  resuming is the natural moment to close that gap, and silently leaving it blank is what makes
  the requirement optional in practice (dotfiles-dev#178). **Linear** exposes the native
  `estimate` on the issue already fetched above — check it right here. **GitHub** has no such
  field on the issue itself; its `Points` value lives on the board item, so this check happens
  in step 7 once the card is located — run step 5a there, before setting the column, if it reads
  empty.
- Continue at step 7 — the card and branch steps are idempotent: `item-add` on an issue already
  on the board is a no-op, and step 8 checks for an existing linked branch first.

## 3. Derive title, conventional type, and slug

From the description:
- Infer a Conventional type: `feat` (default), `fix`, `docs`, `refactor`, `test`, or `chore`.
- **Title:** `<type>: <concise summary>`.
- **Slug:** kebab-case of the summary — lowercase ASCII, words joined by `-`, no accents.

## 4. Classify work type and mode

Infer the work type from the description, then **confirm with AskUserQuestion** (skip the ask
entirely if `--work` was passed). Explain the table in the prompt so the choice is deliberate:

| Work type | Mode | Column | Which upstream is still open |
|---|---|---|---|
| `research` | AFK | `Backlog` | *how* — the approach is unproven, but an agent can settle it alone |
| `prototype` | HITL | `Backlog` | *how* — needs a cheap, rough, concrete artifact built with you |
| `grilling` | HITL | `Backlog` | *what* — no acceptance criteria written down yet |
| `task` | AFK unless the body names a decision for you | `Ready` | none — *why*, *what* and *how* are all cleared; pull-ready |

This **derives the starting column**, so step 7 confirms a value rather than re-judging the
three upstreams from scratch every time. The user can still override to any board column.

**Recording it.** GitHub issue *types* are defined at organisation level, so a personal-account
repo may not have them. **Never let a mutating command be the probe.** `gh issue create` creates
the issue and resolves `--type` afterwards, so a rejected `--type` exits 1 with the issue
**already created**, and a documented retry without the flag files a second one — measured three
times, most recently `gh issue create --type task` exiting 1 with #185 already on the tracker.

Probe **read-only**, once per repo, before step 6 creates anything:

```
rtk gh api graphql -f query='query($o:String!,$r:String!){
  repository(owner:$o,name:$r){ issueTypes(first:20){ nodes{ name } } } }' \
  -F o=<owner> -F r=<repo>
```

An empty node set, no error but no matching `<work-type>` name, or any error → skip `--type`
entirely and use the `type:<work-type>` label instead (create the label first if missing — see
step 6's label-exists check, which now covers this label too). A matching name present → pass
`--type <work-type>` at create time. Either way, **create the issue exactly once.** Linear has no
type field at all, so it always uses the label form.

The mode is always a label on both trackers: `hitl` or `afk`. `task` used to read "either", which
left the most common work type with no rule while this line insisted a label always gets written —
so the default is now stated: **AFK unless the body names a decision that is yours to make.**

### Oracle strength — a SECOND, orthogonal label

Also apply exactly one of `oracle:strong` / `oracle:weak`, asked in the same `AskUserQuestion`:

| Label | Test | Consequence |
|---|---|---|
| `oracle:strong` | a gate, test, or measurable outcome decides correctness **mechanically** | safe to delegate to a cheaper model or another runtime — verification is an exit code |
| `oracle:weak` | correctness is a judgement call; a wrong answer looks right | keep it on the primary model |

⚠️ **This is NOT the same axis as `hitl`/`afk`, and collapsing them ships an inversion.** `afk`
answers *"does a human need to be in the loop?"*; oracle strength answers *"will anything catch a
wrong answer?"* The table above proves they are independent: **`research` is AFK** — an agent can
settle it alone — and is simultaneously the *least* oracle-backed work in the set, because its own
row says the approach is **unproven**. Routing on `afk` would send unverifiable work to the
cheapest runtime, which is exactly backwards.

⚠️ **Judge the oracle, never the size.** Two measured counter-examples (blueprintx, 2026-08-26)
where a complexity scale mis-routes:

- **blueprintx#238** looked small and mechanical. Two decisive facts existed only after
  measurement: deptry's `--config` re-points it at that file as its **manifest** (27 findings vs
  0), and running outside the venv **inverts** the verdict (9 findings, all false; both real
  defects gone). A delegate writes the obvious shared `deptry.toml`, it reads clean, exits 0, and
  the gate is silently blind.
- **"the five tiers share no state"** was asserted and wrong: 6 of the 8 cache fixtures
  `scaffold_lint_test.sh` seeds live in one shared tree and its EXIT trap deletes them, so a naive
  parallel run races and blames an innocent tier.

Both are *small* with *weak oracles* — what a size label sends away and this label keeps.

**Who reads it.** Deliberately a query, not an orchestrator — there is no dispatcher yet, and a
router with no consumer is the abstraction this repo keeps refusing to build:

```bash
gh issue list --label afk --label oracle:strong --state open   # the delegate-safe queue
```

Any decision to hand work to a cheaper model or another runtime **must** consult that queue rather
than re-judging from the title. When a dispatcher does arrive, it reads the same two labels.

On Linear, resolve label ids from the team's labels fetched in step 1; create any that are
missing with `issueLabelCreate(input:{teamId:…,name:…})` before attaching them.

## 5. Decide hierarchy

Default to a single flat issue. Ask about a parent/sub-issue split **only** when at least one
of these holds — otherwise do not raise it at all:

- `--quick` was passed → always flat; skip the ask entirely regardless of the other
  triggers below.
- `--parent <n>` was passed → file directly as a sub-issue of `<n>`; skip the ask entirely.
- The **Scope** section you are about to write would carry more than 3 bullets.
- The description names two or more independently shippable deliverables.
- A `s:problem-framing` artifact for this work exists with more than one scope.

When you do ask, offer: one flat issue, or a parent plus one sub-issue per deliverable (list the
deliverables you inferred so the user can correct them).

Parent bodies carry **Goal** plus a checklist of their children; children carry the full
template. There is no separate `/epic` command — it would duplicate the repo, board and branch
logic for no gain.

## 5a. Score the issue(s) — blocking

*(Runs here — after hierarchy so the final subtask boundaries are known, before step 6's create
so the score exists to write. Also entered directly from step 2's resume path when a score is
missing.)* No issue is filed or left resumed without a score, on either tracker — see
dotfiles-dev#178.

Load `s:story-score` via Skill tool, passing the Scope/description of each unit step 5 settled
on as context — the single flat issue, or each child (never the parent as one lump; the scale
scores subtasks, and a parent's score is their sum, never a number of its own). Do not restate
or reinvent the scale here — it lives in the skill.

- **A subtask lands on 1–3.** Show the point value and its justification, then confirm with
  AskUserQuestion (`Score <n> — <justification>. Use it?` / an override to type a different
  1–3 value). **Skip the ask under `--quick`** — accept the skill's derived score without
  confirmation, consistent with `--quick`'s existing "skip the interactive asks" contract; the
  score itself is still never skipped.
- **A subtask lands on 4.** Per the skill, this is not a score — it is a split signal. Do not
  create anything yet: take the skill's proposed decomposition back to step 5 and re-run its ask,
  offering the new pieces as the sub-issue list (or additional siblings under the existing parent
  if step 5 had already split). Re-enter this step for each resulting piece.
- **No score can be derived and the operator supplies none.** Stop. Say plainly that the issue
  cannot be filed without a score, and do not create it (or, on resume, do not proceed past this
  step).

Parent score = the sum of its already-scored children, computed here before step 6 creates
anything — never recomputed later, since neither tracker recomputes it and children are always
scored before the parent is written.

## 6. Create the issue(s)

*(Create path only — skip if step 2 resolved an existing issue.)*

Body template. The **Documentation** section is mandatory and stays verbatim — it is a standing
requirement. It is written in English, like the rest of this repo's durable record
(`gh_prose_language_guard.sh` enforces exactly that for whatever is published here — a template
demanding non-English prose would fight its own guard, dotfiles-dev#187):

```
## Goal
<one-paragraph statement of what this work delivers>

## Scope
- <bullet(s) scoping the change>

## Documentation
- Update `docs/` and the `README.md` where relevant — new behaviour, a change to the public API,
  or a new usage example. The work is not complete until the documentation matches it.
```

A quoted non-English literal (a UI string, a Gherkin keyword, a foreign source identifier) is
data, not prose — keep it verbatim in backticks so it stays greppable in the code it describes;
the guard exempts inline `code` spans exactly for this case (dotfiles-dev#187).

Per-tracker operations — one spine, two arms:

| Operation | `github` | `linear` |
|---|---|---|
| create | `rtk gh issue create --title "<title>" --body-file <f> --assignee @me` | `issueCreate(input:{teamId,title,description,assigneeId})` |
| work type | `--type <work-type>` if step 4's read-only probe found it, else `type:<work-type>` label | `type:<work-type>` label |
| mode | `--label hitl\|afk` | label id |
| oracle | `--label oracle:strong\|oracle:weak` | label id |
| extra label | `--label <name>` when `--label` was passed | label id |
| parent | `--parent <n>` | `parentId` on `issueCreate` |
| score | *(not an issue attribute — set on the board's `Points` field in step 7)* | `estimate` on `issueCreate` (native field, set here directly) |

⚠️ **On GitHub, ensure the label exists before attaching it.** `gh issue create --label <name>`
**fails the whole create** when the label is absent from the repo — and `oracle:strong` /
`oracle:weak` exist in no repo yet, `hitl` / `afk` exist only where they were added by hand, and
a `type:<work-type>` label (step 4's fallback when the read-only probe finds no matching issue
type) is created ad hoc, per work type, the first time it is needed. So run this first, for each
label being attached:

```bash
rtk gh label create "<name>" --description "<why>" --color "<hex>" --force
```

`--force` makes it idempotent (it updates an existing label instead of erroring), so this is safe
to run unconditionally. The Linear arm already did the equivalent — *"create any that are missing
with `issueLabelCreate(...)` before attaching them"* — and the GitHub arm silently did not, which
is the asymmetry that turns a new label into a failed `issue create` on first use.

Write the body with the Write tool to a scratchpad file and pass `--body-file` — never inline a
multi-line body into the shell, where the accented characters and backticks get mangled.

Capture the issue number/identifier and URL. Create the parent first when splitting, so its
number is available for the children's `--parent`.

## 7. Board card and column

**linear:** skip this step entirely. Linear's workflow states *are* the board — set the issue's
state directly with `issueUpdate(input:{stateId:…})`. Map by state **`type`**, never by display
name (teams rename states freely): `Backlog` → the first state of type `backlog`, `Ready` → the
lowest-`position` state of type `unstarted`. Then go to step 8.

**github:** list the owner's projects with `rtk gh project list --owner <owner> --format json`
and match the project titled exactly **`<repo> kanban`** (e.g. `filings-cvm kanban`).

- **More than one project with that title → stop and ask which to use** (list them as
  `#<number> — items:<count>`). Never pick one silently: the lifecycle hook matches boards by
  title too, so two same-named boards make every card move non-deterministic. Offer to delete the
  extras once the user names the keeper (`rtk gh project delete <number> --owner <owner>`).
- If `--project <name|number>` was passed, use that instead.
- **No match and none passed → ask** (AskUserQuestion). Offer: (a) **create** a project named
  `<repo> kanban` (recommended), (b) create one under a name they type, or (c) use an existing
  project they name. Do not guess and do not silently create.
- To create: `rtk gh project create --owner <owner> --title "<chosen name>" --format json`, then
  record its number and node id.

  **Then normalize the Status columns.** A `gh`-created board ships GitHub's *default* options
  (`Todo` / `In Progress` / `Done`), which do **not** match the standard kanban. Get the Status
  field id from `field-list`, then:

  ```
  rtk gh api graphql -f query='
  mutation($fieldId: ID!) {
    updateProjectV2Field(input: { fieldId: $fieldId, singleSelectOptions: [
      {name: "Backlog",     color: GRAY,   description: "This item hasn'"'"'t been started"},
      {name: "Ready",       color: GREEN,  description: "This is ready to be picked up"},
      {name: "In progress", color: YELLOW, description: "This is actively being worked on"},
      {name: "In review",   color: PURPLE, description: "This item is in review"},
      {name: "Done",        color: PURPLE, description: "This has been completed"}
    ] }) { projectV2Field { ... on ProjectV2SingleSelectField { options { name } } } }
  }' -F fieldId="<status-field-id>"
  ```

  **Then ensure a `Points` field exists.** GitHub has no native estimate field, so the score from
  step 5a is recorded as a project (board) `Number` field — summable in a board view, unlike a
  `points/<n>` label (dotfiles-dev#178 weighed both and picked the field for exactly that reason).
  Check `field-list` first; create it only if missing:

  ```bash
  rtk gh project field-create <project-number> --owner <owner> --name "Points" --data-type NUMBER
  ```

  **Then tell the user to enable the Done workflows — the API cannot.** A `gh`-created board
  ships its built-in workflows **disabled**, and the GraphQL API exposes no mutation to enable
  them (only `deleteProjectV2Workflow`). So the "card → Done on merge" automation this command
  relies on is **off until a human flips it**. Print this and wait for confirmation:

  > Open `https://github.com/users/<owner>/projects/<number>/workflows` and enable, each with
  > **Set value → Status → Done**:
  > - **Item closed**
  > - **Pull request merged**
  >
  > Do **not** enable **Pull request linked to issue** — the `kanban_lifecycle` hook already
  > moves the card to *In review* when the PR opens, and enabling this native workflow would
  > fire at the same moment and race it (it defaults to *In progress*, dragging the card
  > backwards). This is the same defect class the hook itself guards against (#131): a card
  > must never move backwards once its issue's real state has passed that point.

Add the card (parents and children both):
`rtk gh project item-add <project-number> --owner <owner> --url <issue-url>`
(Safe to re-run — an issue already on the board is not duplicated.)

Set the column to the value **derived in step 4**. State the derivation in one line
(`work type <x> → <column>`) and let the user override; do not re-ask the three upstreams.

**On the resume path**, first read the card's current status and `Points` value from
`item-list --format json`. If status is already past `Ready` (e.g. `In progress`), report it and
leave it alone. If `Points` is empty, run step 5a now — this is the deferred GitHub half of the
resume-path score check from step 2 — and write the result below rather than proceeding unscored.

If the board genuinely lacks the derived option (a not-yet-normalized board), fall back to the
first not-started option.

Resolve the ids and set it:
- `rtk gh project field-list <project-number> --owner <owner> --format json` → the `Status`
  field id and the chosen option's id.
- `rtk gh project item-edit --project-id <project-node-id> --id <item-id> --field-id <status-field-id> --single-select-option-id <option-id>`

(`item-add` prints the item id; if not, get it from `rtk gh project item-list … --format json`.)

**Also set `Points`, every time** — the score from step 5a (or the sum, for a parent), never
skipped, using the field id from the same `field-list` read:
`rtk gh project item-edit --project-id <project-node-id> --id <item-id> --field-id <points-field-id> --number <score>`

## 8. Open the linked branch — leaf issues only

**`--quick` → skip this step entirely.** No branch is opened; report
`Branch:  (skipped — --quick)` in step 9 instead of a ref.

**Never cut a branch for a parent issue.** `branch_requires_issue_guard.sh` would allow it (the
ref is real), but a parent is a container: a PR closing it would close the children's tracking
with work still outstanding. When step 5 produced a split, branch from the first child and say so.

First check whether the issue already has one:

**github:** `rtk gh issue develop <N> --repo <owner>/<repo> --list`

- **A linked branch exists** → check it out (`rtk git checkout <branch>`, fetching first if it
  is only on the remote). Do not create a second branch.
- **None** → create one linked to the issue (the recommended-name step — it makes the future PR
  auto-associate with the issue):

  `rtk gh issue develop <N> --repo <owner>/<repo> --name <type>/<N>-<slug> --base <base> --checkout`

**linear:** Linear has no branch-linking API, so create it directly:

`rtk git checkout -b <type>/<team-key-lowercase>-<number>-<slug>`

The ref must stay in **leading slug position**: `branch_requires_issue_guard.sh` strips the
`<type>/` prefix before matching `[A-Za-z][A-Za-z0-9]*-[0-9]+`, so `feat/dit-456-add-thing`
resolves to `DIT 456`. This deviates from Linear's own `username/dit-456-slug` convention on
purpose — the house `<type>/` prefix is what the rest of the toolchain reads.

## 9. Report

Output, concisely — omit any line that does not apply:

```
Mode:    created | resumed
Tracker: github | linear
Issue:   #<N> <url>                    (or <TEAM>-<n>)
Type:    <conventional> / <work-type> (<hitl|afk>)
Score:   <n> (<justification>)         (parent: <n> = sum of children)
Parent:  #<P>                          (omit when flat)
Board:   <project> → <column>          (omit for linear)
Branch:  <type>/<ref>-<slug> (checked out)   (omit for parents)
```

Then the **PR snippet:** ```Closes #<N>``` — tell the user to paste it in the PR body so merging
the PR closes the issue, which the board's "Item closed → Done" workflow then moves to Done.
After opening the PR, verify the link took: `gh pr view <n> --json closingIssuesReferences`.
