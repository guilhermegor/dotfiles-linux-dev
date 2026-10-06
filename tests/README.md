# tests/

Unit tests for the repo's bash helpers, written with
[bats-core](https://github.com/bats-core/bats-core).

## Run locally

```bash
sudo apt-get install -y bats   # one-time
bats tests/                    # run the whole suite
bats tests/shared_agents_md.bats   # one file
```

Or run the full CI workflow locally with `act` (see the `act` skill):

```bash
act -W .github/workflows/tests.yml
```

## What is covered

| File | Unit under test |
|------|-----------------|
| `destructive_command_guard.bats` | `ai_clients/claude/hooks/destructive_command_guard.sh` — pipe-to-shell / unscoped-delete / history-rewrite blocks |
| `protected_branch_guard.bats` | `ai_clients/claude/hooks/protected_branch_guard.sh` — refspec-aware push guard on protected branches (deletes of other refs allowed; heredoc bodies ignored) |
| `branch_requires_issue_guard.bats` | `ai_clients/claude/hooks/branch_requires_issue_guard.sh` — branch-creation → tracked-issue guard (per-segment match; no false positive from a chained `-c` or a heredoc body) |
| `settings_env_deny.bats` | `ai_clients/claude/settings.json` (`permissions.deny`) — enumerated `.env*` secret-suffix globs deny real secrets while leaving `.env.example`/`.env.sample`/`.env.template`/`.env.dist` readable |
| `settings_deny_list.bats` | `ai_clients/claude/settings.json` (`permissions.deny`) — the dotfiles-linux-dev#503 additions (secrets/credentials paths, key/p12/pfx, `~/.ssh`, `printenv:*`/`env`/`/proc/*/environ`) are present in the `<cmd>:*` convention form, the three refused entries (`Read(**/.env.*)`, `Bash(cat .env*)`, `Bash(echo $*)`) never land, and the `.env` enumeration keeps all eight suffix entries |
| `dispatch_free_surface_guard.bats` | `ai_clients/claude/hooks/dispatch_free_surface_guard.sh` — the DISPATCH `Stop` hook: blocks on a non-empty free surface with nothing of this session's own working it, reports a gate failure as UNREADABLE (never silent), and fails open on `stop_hook_active`, no repo, no `s:dev-loop` evidence, or a still-unresolved `Agent` dispatch |
| `round_dispatch_guard.bats` | `ai_clients/claude/hooks/round_dispatch_guard.sh` — the round-level DISPATCH `Stop` hook: blocks a round with dispatchable candidates and no agent started, passes when every candidate carries a named exclusion reason, announces itself as a no-op while the planner is missing, and treats an unreadable plan as UNREADABLE, never empty |
| `slot_classify.bats` | `ai_clients/claude/hooks/lib/slot_classify.py` — the review-slot classifier: an unrelated newest notice must not mask a running limit, the wrapper comment carrying no wait must not degrade its sibling's stated wait, and a forge 403 body or garbage is `UNKNOWN`, never free |

## Adding tests for another helper

Copy the `setup()` pattern, source the target file, stub its I/O boundaries, and
assert on `$status` / `$output` from `run`. Keep each `@test` to one behavior.
