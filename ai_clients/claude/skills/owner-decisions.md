---
name: s:owner-decisions
description: Use when the owner asks "what is pending from a decision of mine?", "what do you need from me?", or "anything waiting on me?" — builds the answer from collected data (flagged PRs, decision-blocked cards, OFF workflows, REPORT-REMOTE branches, hitl issues), never from recall.
effort: medium
argument-hint: [none]
allowed-tools: Bash Read
---

> **Priority:** this project's `CLAUDE.md` and `rules/*.md` take precedence over the
> guidance below whenever they conflict — treat this skill as a fallback, not a mandate.

The orchestrator used to rebuild this list from memory each time, so items were missed or asked
again after being answered (dotfiles-linux-dev#1033). The list now comes from a collector.

## Procedure

1. Run the collector, never a hand-assembled list:

   ```bash
   cd /home/guilhermegor/github/dotfiles-linux-dev && bash ai_clients/claude/hooks/lib/owner_decisions.sh
   ```

   (installed copy: `bash ~/.claude/hooks/lib/owner_decisions.sh`, run from the repo to scan.)
   It prints one table row per item: **decision, context, suggestion, pros/cons**.

2. Present that table. Sharpen the suggestion and pros/cons per row from the row's context; the
   collector only supplies a per-source default. Do not add rows from memory — an item the
   collector did not list is either answered, excluded, or a missing source (file that gap).

3. A line `UNREADABLE (not "none"): <source>` means that source could not be read. Say so;
   never report it as "nothing pending".

## Sources (what the collector reads)

| Source | Counts as a decision when |
|---|---|
| open PRs | body says "decide whether", "surface expansion", "expands the (public) surface", "disabled feature", "feature (is) disabled" or "judg(e)ment call" |
| board cards | a Blocked card whose "Blocked by" field or body line holds `decision:` (read-only: judged with `roadmap_unblock.sh`'s helpers, never its mutating reconcile) |
| Projects workflows | reported OFF; the API cannot enable them |
| origin branches | `branch_prune.sh` dry-run reports `REPORT-REMOTE`, run in every board repo's own checkout (cwd when its origin matches, else `$KANBAN_CHECKOUT_ROOT`/`~/github`/`<repo>`); a repo with no checkout prints `UNREADABLE ... (no local checkout)` |
| issues | labelled `hitl`, or `state:blocked` with a `decision:` blocker |

## Standing exclusions

Read from a data file, never hardcoded: `~/.claude/tasks/owner-decisions-exclusions.txt`
(override with `OWNER_DECISIONS_EXCLUDE_FILE`). One entry per line:

```
#1046                    # blocked until owner says, never ask
owner/repo#7             # one repo only
branch:feat/old          # that branch name in any repo
branch:owner/repo:feat/old   # one repo only
workflow:guilhermegor/13/Auto-add to project
```

`#N` matches that number in any repo; text after ` # ` is the reason. A line starting `# ` is a
comment. When the owner says "never ask about X" or memory records a "blocked until owner says"
item, add it here in the same turn — an excluded item is never listed, never re-asked.

## Never a decision

Merge, release, dispatch, rebase, rerun CI and thread resolution are routine loop actions
(`s:dev-loop`). A merged PR is never a row. If an item reads like one of these, it is not
listed; do not add it by hand.
