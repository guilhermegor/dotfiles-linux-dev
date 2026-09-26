---
name: c:greenfield-new
allowed-tools: Bash(rtk gh issue*), Bash(rtk gh project*), Bash(rtk gh label*), Bash(rtk gh api*), AskUserQuestion, Read, Write, Skill
description: File a BlueprintX scaffold backlog item in guilhermegor/greenfield from named keys, never a prompt list
argument-hint: "[--skeleton <name>]"
---

You are filing a backlog item in `guilhermegor/greenfield` for a future, unattended
`bin/blueprintx.sh` scaffold run — captured now as a GitHub issue with a named `key: value`
answer map, so the run can happen later without a person re-answering an ordered list of
prompts. Follow these steps exactly. `$ARGUMENTS` may carry `--skeleton <name>` to preseed
step 1's skeleton pick.

## 0. Why named keys, not a prompt list

This is the same defect class as guilhermegor/blueprintx#481. An unattended scaffold run
pipes answers into the CLI **positionally** (`printf '%s\n' n "" 3 "" "" "" y n | bin/
blueprintx.sh`), so a PR that adds one prompt silently shifts every answer after it onto the
wrong question. A backlog item authored against that surface inherits the fragility if it is
itself just an ordered list. This command never produces or asks for an ordered list: every
answer is gathered under its own named key via `AskUserQuestion`, held as a `key: value` map,
and the full map is shown back for confirmation (step 4) before anything is filed. Nothing
here is positional, including the per-skeleton questions in step 2 — they are looked up by
skeleton name in the table below, not asked in a fixed slot order.

## 1. The measured answer surface

⚠️ This table is a measurement of `bin/blueprintx.sh` and `bin/scaffold/` taken for
dotfiles-dev#363 — re-measure it (same method: read `prompt_*` call sites in
`bin/blueprintx.sh` and each `templates/*/skeleton.meta`-driven scaffold) before trusting it
if BlueprintX's own prompts have moved on since.

**Top-level** (`bin/blueprintx.sh` itself — always asked):

| key | notes |
|---|---|
| `name` | project name |
| `description` | optional |
| `root` | destination path |
| `language` | menu built from `templates/*/skeleton.meta` |
| `skeleton` | filtered by `language` — accept `--skeleton <name>` to skip this ask |
| `license` | offer MIT / Apache-2.0 / GPL-3.0 / proprietary-or-none / other (free text) |

**Shared** (every scaffold — always asked):

| key | notes |
|---|---|
| `github_username` | |
| `remote_setup` | wire a git remote now? |
| `create_repo_now` | create the GitHub repo now, or scaffold only? |
| `repo_visibility` | `public` / `private` — **also drives the `registry` derivation in step 3** |
| `protect_branch` | protect the default branch? |
| `human_reviewers_gate_merges` | require human review before merge? |

**Per-skeleton** (scoped — ask only the row matching the `skeleton` key from step 1):

| skeleton | keys to ask |
|---|---|
| `lib-minimal` | `logging_helper` · `publish_to_pypi` · `testpypi_staging` · `private_index_or_git` · `docker_compose` · `db_backend` |
| `ddd-service-*` | `docker_compose` · `db_backend` · `schemaless_storage` · `custom_output_dir` · `output_base` · `dated_subdirs` · `webhook` · `webhook_platform` (teams/slack/custom) · `email_handler` · `email_backend` |
| `mvc-service-*` | `docker_compose` · `db_backend` · `custom_output_dir` · `output_base` · `dated_subdirs` · `webhook` · `webhook_platform` (teams/slack only — no `custom`) · `email_handler` · `email_backend` · `multiple_run_intents` |
| `react-spa-webpack` | `state_management` · `deploy_target` · `module_federation` · `docker` · `js_copy` · `wait_for_deploy` · `enable_pages` |
| `ts-lib` | *(shared set only — no extra keys)* |

Never offer a key from a different skeleton's row — `webhook_platform: custom` does not exist
for `mvc-service-*`, and a flat key list would offer it anyway.

## 2. Ask — grouped by named key, never by position

Three `AskUserQuestion` calls, each one batch of related keys (not one call per key, and not
one call for everything — a batch per concern keeps each question legible):

1. **Identity + stack**: `name`, `description`, `root`, `language`, `skeleton` (skip if
   `--skeleton` was passed), `license`.
2. **Repo**: `github_username`, `remote_setup`, `create_repo_now`, `repo_visibility`,
   `protect_branch`, `human_reviewers_gate_merges`.
3. **Skeleton-specific**: exactly the row from step 1's per-skeleton table matching the chosen
   `skeleton` — nothing else.

Record every answer under its key name in a `key: value` map. Do not renumber or reorder keys
between this step and step 4 — the map is looked up by key, never replayed by position.

## 3. Derive — never re-ask what a key already implies

Compute these from the map above and add them to it. None of these is its own question:

- `kind`: `lib-minimal` / `ts-lib` → `lib`; `ddd-service-*` / `mvc-service-*` → `service`;
  `react-spa-webpack` → `app`.
- `lang`: the `language` key's value, taxonomy-cased (`python`, `typescript`).
- `registry`: `kind:service` ⇒ `none` (services are never published to a package registry).
  Otherwise (a `lib`/`app` kind): `repo_visibility:private` ⇒ `git-only`; else use
  `publish_to_pypi`/an npm-equivalent answer if the skeleton asked one, defaulting to `none`
  when it didn't.
- `repo`: the `repo_visibility` value verbatim (`public` / `private`).
- `state`: always `backlog` — this command only files a backlog item, it never starts work.

## 4. Confirm the full map

Print the complete `key: value` table — asked keys and derived keys both, each marked
`(asked)` or `(derived)` — and confirm with `AskUserQuestion` (`File it as shown` / `Let me
change a value`) before anything is created. A "change a value" answer loops back to the
specific key in step 2 or 3, never to a full re-ask.

## 5. Score

Load `s:story-score` via the Skill tool, passing the `name`/`description` keys as context, to
get the `Points` value filed in step 7. Follow the skill's own escalation rule if it returns a
split signal instead of a 1–3 score.

## 6. Ensure labels exist, then file the issue

For each of `kind:<value>`, `lang:<value>`, `registry:<value>`, `repo:<value>`,
`state:backlog`, ensure the label exists before attaching it (idempotent — safe to always run):

```
rtk gh label create "<name>" --repo guilhermegor/greenfield --description "<why>" --color "<hex>" --force
```

Write the issue body with the Write tool to a scratchpad file, then create it:

```
## Goal
Scaffold `<name>` from the `<skeleton>` template.

## Answer surface
| key | value | source |
|---|---|---|
<one row per key from step 4, `source` = asked or derived>

## Documentation
- Update `docs/` and the `README.md` where relevant — new behaviour, a change to the public
  API, or a new usage example. The work is not complete until the documentation matches it.
```

```
rtk gh issue create --repo guilhermegor/greenfield --title "feat: scaffold <name> (<skeleton>)" \
  --body-file <scratchpad-file> --assignee @me \
  --label "kind:<value>" --label "lang:<value>" --label "registry:<value>" \
  --label "repo:<value>" --label "state:backlog"
```

Capture the issue number and URL.

## 7. Board card and Points

List `guilhermegor`'s projects (`rtk gh project list --owner guilhermegor --format json`) and
match the one titled exactly `greenfield kanban`. More than one match → stop and ask which to
use. No match → ask whether to create it (recommended) before doing anything else.

Add the card (`rtk gh project item-add <project-number> --owner guilhermegor --url <issue-url>`
— safe to re-run), set its `Status` to `Backlog` (the fixed `state` value from step 3), and set
`Points` to step 5's score — same field-resolution mechanics as `c:issue` step 7
(`field-list` → field id + option id → `item-edit`).

## 8. Report

```
Issue:  #<N> <url>
Kind:   <kind> / Lang: <lang> / Registry: <registry> / Repo: <repo>
Score:  <n> (<justification>)
Board:  greenfield kanban → Backlog
```
