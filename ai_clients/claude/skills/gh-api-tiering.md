---
name: s:gh-api-tiering
description: Use when a GitHub operation is about to be made (reads, comments, merges, labels, auto-merge, thread resolves, Projects v2 writes), when `gh` reports a GraphQL rate limit, or when the 403 latch is set and a step blocks progress.
effort: medium
argument-hint: [operation]
allowed-tools: Bash(gh api*), Bash(rtk gh api*), Read
---

> **Priority:** this project's `CLAUDE.md` and `rules/*.md` take precedence over the guidance below whenever they conflict — treat this skill as a fallback, not a mandate.

Pick the channel BEFORE the call, never after a refusal (dotfiles-linux-dev#1072). Order: **REST**, then
**GraphQL behind the budget latch**, then the **Chrome extension** as a session-level last resort.
REST draws on the core quota; GraphQL has its own budget plus a secondary limit that
`gh api rate_limit` cannot see, and every session, cron and subagent shares it.

## 1. Routing table

| Operation | Channel | How |
|---|---|---|
| Read PR, issue, comments, reviews, files, branches, check-runs | REST | `gh api repos/O/R/pulls/N`, `.../issues/N/comments`, `.../commits/SHA/check-runs` |
| Create or edit a PR or issue body, title, state | REST | `gh api repos/O/R/pulls -X POST`, `.../issues/N -X PATCH` |
| Comment, reply to a review comment | REST | `.../issues/N/comments`, `.../pulls/N/comments/ID/replies` |
| Labels, assignees, milestone | REST | `.../issues/N/labels` |
| Merge | REST | `PUT repos/O/R/pulls/N/merge` (`merge_green_pr.sh` for the guarded path) |
| Update a PR branch | REST | `PUT repos/O/R/pulls/N/update-branch` |
| Issue dependencies (blocked by) | REST | `.../issues/N/dependencies/blocked_by` |
| Issue state, comments, labels (hook reads) | REST | never `gh issue view` / `gh pr view`: those are GraphQL |
| Arm auto-merge | GraphQL only | `enablePullRequestAutoMerge` |
| Resolve a review thread | GraphQL only | `resolveReviewThread` (`resolve_review_thread.sh`) |
| Projects v2 item and field writes | GraphQL only | `updateProjectV2ItemFieldValue`, `addProjectV2ItemById` |
| Read `closingIssuesReferences`, `reviewThreads` (resolved state) | GraphQL only | no REST shape carries them |

GraphQL-only mutations go through `hooks/lib/gh_graphql_mutation.sh`'s `gh_graphql_mutation OP ...`:
it checks `gh_budget_poll_allowed` and the latch first. Under the latch it returns **75 (deferred)** and
prints one line, `DEFERRED <op>: <reason> - do it in the GitHub UI: <path>`. Treat 75 as "not done, not
failed": never retry in a loop, never route the same op through another GraphQL call. Hooks and
scripts stop there; they never open a browser.

### UI path per GraphQL-only operation

| Operation | GitHub web UI path |
|---|---|
| `enablePullRequestAutoMerge` | PR page > merge box > Enable auto-merge > pick method > Confirm |
| `resolveReviewThread` | PR page > Conversation or Files changed > the thread > Resolve conversation |
| `updateProjectV2ItemFieldValue` | Project board > the card > edit the field cell, or drag the card to the column |
| `addProjectV2ItemById` | Project board > + Add item > search and pick the issue or PR |

## 2. Chrome last resort (session level only)

Use it ONLY when all hold: the operation is in the GraphQL-only rows, the door returned 75, and the
step blocks progress (a merge waiting on auto-merge, a gate waiting on a resolve). Anything with a
REST route stays on REST, latched or not. A hook or subagent without the extension skips this and
reports the deferral line.

1. **Load once.** One `ToolSearch` selecting every Chrome tool you will need
   (`mcp__claude-in-chrome__tabs_context_mcp`, `tabs_create_mcp`, `tabs_close_mcp`, `navigate`,
   `read_page`, `find`, `computer`), never one call per tool.
2. **`tabs_context_mcp` first**, to see what the browser already has. Never touch a tab you did not open.
3. **Open a NEW tab** (`tabs_create_mcp`) and navigate to the exact PR or board URL.
4. **One action per step** along the UI path above, reading the page (`read_page`, `find`) before each
   click. Only the control the path names.
5. **Never a destructive control**: no Delete, Close PR/issue, Merge now, Force, Remove, Archive,
   Convert, or Settings. If the target control is not the one in the table, stop.
6. **Stop on any dialog** that the path did not predict (confirmation of something else, a permission
   or login prompt, a CAPTCHA, a "are you sure"). Do not answer it; report it.
7. **At most 2 retries** per action. Then stop and report; do not loop.
8. **Verify each action over REST**, never by the page's say-so: auto-merge armed
   (`gh api repos/O/R/pulls/N --jq .auto_merge`), merged (`.merged`), thread resolved (read the
   thread through the one GraphQL read when the budget is back, or the reply state over REST), card
   moved (once GraphQL answers). A page that looks right is not proof.
9. **Close the tab** you opened (`tabs_close_mcp`) when done or when stopping.

## 3. Do not

- Do not pick GraphQL for something REST covers because `gh pr view` is shorter.
- Do not re-probe a latched budget; the latch exists so one refusal is not repeated by every caller.
- Do not drive the browser from a hook, a cron or a subagent without the extension.
- Do not use the browser for reads, comments, labels, bodies or merges: those are REST.
