#!/usr/bin/env bats
#
# Every BLOCKING PreToolUse guard must fail CLOSED (exit 2, stderr naming jq) when jq is missing
# from PATH, instead of `command -v jq || exit 0` waving every call through
# (dotfiles-linux-dev#1162). Advisory hooks keep exit 0 and are not covered here.
#
# PATH is a directory of symlinks to bash + common coreutils, deliberately without jq.

bats_require_minimum_version 1.5.0

HOOKS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks"

setup_file() {
    NOJQ="$(mktemp -d)"
    local t p
    for t in bash dirname cat sed grep git tr head tail cut sort env mktemp rm basename readlink; do
        p="$(command -v "$t")" && ln -s "$p" "$NOJQ/$t"
    done
    export NOJQ
}

teardown_file() {
    rm -rf "$NOJQ"
}

run_nojq() {
    run --separate-stderr env PATH="$NOJQ" "$NOJQ/bash" -c 'echo "{}" | "$NOJQ/bash" "$1"' _ "$HOOKS/$1"
}

assert_closed() {
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"jq not found"* ]]
}

@test "#1162 branch_requires_issue_guard blocks without jq"      { run_nojq branch_requires_issue_guard.sh; assert_closed; }
@test "#1162 claude_artifact_source_guard blocks without jq"     { run_nojq claude_artifact_source_guard.sh; assert_closed; }
@test "#1162 commit_secret_guard blocks without jq"              { run_nojq commit_secret_guard.sh; assert_closed; }
@test "#1162 commit_title_length_guard blocks without jq"        { run_nojq commit_title_length_guard.sh; assert_closed; }
@test "#1162 destructive_command_guard blocks without jq"        { run_nojq destructive_command_guard.sh; assert_closed; }
@test "#1162 issue_template_guard blocks without jq"             { run_nojq issue_template_guard.sh; assert_closed; }
@test "#1162 pr_merge_threads_guard blocks without jq"           { run_nojq pr_merge_threads_guard.sh; assert_closed; }
@test "#1162 pr_template_guard blocks without jq"                { run_nojq pr_template_guard.sh; assert_closed; }
@test "#1162 primary_checkout_subagent_guard blocks without jq"  { run_nojq primary_checkout_subagent_guard.sh; assert_closed; }

# #1164: the remaining blocking guards.
@test "#1164 protected_branch_guard blocks without jq"          { run_nojq protected_branch_guard.sh; assert_closed; }
@test "#1164 gate_bypass_guard blocks without jq"               { run_nojq gate_bypass_guard.sh; assert_closed; }
@test "#1164 stale_local_ref_guard blocks without jq"           { run_nojq stale_local_ref_guard.sh; assert_closed; }
@test "#1164 dispatch_free_surface_guard blocks without jq"     { run_nojq dispatch_free_surface_guard.sh; assert_closed; }
@test "#1164 release_dispatch_guard blocks without jq"          { run_nojq release_dispatch_guard.sh; assert_closed; }
@test "#1164 review_fanout_guard blocks without jq"             { run_nojq review_fanout_guard.sh; assert_closed; }
@test "#1164 round_dispatch_guard blocks without jq"            { run_nojq round_dispatch_guard.sh; assert_closed; }
@test "#1164 gh_prose_language_guard blocks without jq"         { run_nojq gh_prose_language_guard.sh; assert_closed; }

# Meta-test: a hook carrying `command -v jq ... || exit 0` fails OPEN. That is only acceptable
# for a hook that cannot refuse, so each one must be listed here with its reason.
ADVISORY_FAIL_OPEN=(
    "commit_body_wrap.sh:rewriter; reflows the message in place"
    "agent_branch_push_guard.sh:PostToolUse pusher, never blocks"
    "memory_index_drift.sh:drift notice only"
    "lesson_capture_checkpoint.sh:capture reminder only"
    "pr_self_assign.sh:assigns the PR, never refuses"
    "subagent_stop_sweep.sh:sweep/logger, cannot refuse"
    "kanban_lifecycle.sh:board bookkeeping, cannot refuse"
    "release_due_nudge.sh:nudge only"
    "quota_gap_rescue.sh:rescue notice only"
    "push_pr_head_guard.sh:PostToolUse, push already ran; exit 2 is a notice, not a refusal"
    "uncommitted_worktree_guard.sh:Stop hook; stop_hook_active unreadable without jq, exit 2 would loop"
    "open_review_threads_nudge.sh:Stop hook; same stop_hook_active loop risk without jq"
)

@test "#1164 fail-open jq check only in advisory-allowlisted hooks" {
    local f name bad=""
    for f in "$HOOKS"/*.sh; do
        name="$(basename "$f")"
        grep -Eq 'command -v jq[^|]*\|\| *exit 0' "$f" || continue
        printf '%s\n' "${ADVISORY_FAIL_OPEN[@]}" | grep -q "^$name:" || bad="$bad $name"
    done
    [ -z "$bad" ] || { echo "fail-open on missing jq, not allowlisted:$bad" >&2; return 1; }
}

@test "#1160 pr_merge_threads_guard blocks when lib/gh_budget.sh is missing" {
    local d
    d="$(mktemp -d)"
    cp "$HOOKS/pr_merge_threads_guard.sh" "$d/"
    run bash -c 'echo "{}" | bash "$1"' _ "$d/pr_merge_threads_guard.sh"
    rm -rf "$d"
    [ "$status" -eq 2 ]
    [[ "$output" == *gh_budget.sh* ]]
}
