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
@test "#1164 release_dispatch_guard blocks without jq"          { run_nojq release_dispatch_guard.sh; assert_closed; }
@test "#1164 gh_prose_language_guard blocks without jq"         { run_nojq gh_prose_language_guard.sh; assert_closed; }

# Stop hooks cannot fail closed without jq (stop_hook_active, their loop-break, is read through jq, so
# exit 2 would refuse every stop forever, #1164). They announce once per session instead (#1169):
# exit 1 surfaces stderr without blocking, every later stop exits 0. The once-per-session marker is
# keyed on session_id read with sed (no jq), falling back to the parent PID.
run_nojq_stop() {
    run --separate-stderr env PATH="$NOJQ" TMPDIR="$BATS_TEST_TMPDIR" "$NOJQ/bash" -c \
        'echo "{\"session_id\":\"s-$2\"}" | "$NOJQ/bash" "$1"' _ "$HOOKS/$1" "${2:-1}"
}

assert_announced() {
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"${1%.sh}"* ]]
    [[ "$stderr" == *"jq"* ]]
    [[ "$stderr" == *"apt install jq"* ]]
}

assert_quiet() {
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
}

stop_hook_announces_once() {
    run_nojq_stop "$1"; assert_announced "$1"
    run_nojq_stop "$1"; assert_quiet
    run_nojq_stop "$1" 2; assert_announced "$1"
}

@test "#1169 dispatch_free_surface_guard announces once without jq" { stop_hook_announces_once dispatch_free_surface_guard.sh; }
@test "#1169 review_fanout_guard announces once without jq"         { stop_hook_announces_once review_fanout_guard.sh; }
@test "#1169 round_dispatch_guard announces once without jq"        { stop_hook_announces_once round_dispatch_guard.sh; }
@test "#1169 uncommitted_worktree_guard announces once without jq"  { stop_hook_announces_once uncommitted_worktree_guard.sh; }
@test "#1169 open_review_threads_nudge announces once without jq"   { stop_hook_announces_once open_review_threads_nudge.sh; }

@test "#1169 unreadable session_id still announces and never blocks" {
    run --separate-stderr env PATH="$NOJQ" TMPDIR="$BATS_TEST_TMPDIR" "$NOJQ/bash" -c \
        'echo "{}" | "$NOJQ/bash" "$1"' _ "$HOOKS/uncommitted_worktree_guard.sh"
    [ "$status" -eq 1 ]
}

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
    # The five Stop hooks left this list in #1169: they announce once, never silently fail open.
    "push_pr_head_guard.sh:PostToolUse, push already ran; exit 2 is a notice, not a refusal"
)

# A jq-presence probe (command -v / hash / type / which) whose failure branch is `exit`/`return`
# with no non-zero code (bare, or 0), as `|| exit 0` or `then exit 0`. A fail-closed line has
# `|| { ...; exit 2; }` and an `exit 1` is explicit, so neither matches.
FAIL_OPEN_JQ='(command -v|hash|type|which) jq[^#]*(\|\||then) *(exit|return)( 0)?[ ;]*(;|fi|$)'

# Hooks that fail open on a missing jq, as bare file names, from hooks/ and hooks/lib/.
fail_open_hooks() {
    local f
    for f in "$HOOKS"/*.sh "$HOOKS"/lib/*.sh; do
        if grep -Eq "$FAIL_OPEN_JQ" "$f"; then printf '%s\n' "${f#"$HOOKS"/}"; fi
    done
}

# Scope: guarantees every jq-presence probe in hooks/ and hooks/lib/ is either fail-closed or
# allowlisted. A hook with no probe at all (it just pipes through jq) is not covered here.
@test "#1164 every fail-open jq probe is on the advisory allowlist" {
    local name entry listed bad=""
    while IFS= read -r name; do
        listed=""
        for entry in "${ADVISORY_FAIL_OPEN[@]}"; do
            [[ "$entry" == "$name:"* ]] && listed=1
        done
        [ -n "$listed" ] || bad="$bad $name"
    done < <(fail_open_hooks)
    [ -z "$bad" ] || { echo "fail-open on missing jq, not allowlisted:$bad" >&2; return 1; }
}

@test "#1164 every allowlisted hook still exists and still fails open" {
    local entry name stale=""
    local open
    open="$(fail_open_hooks)"
    for entry in "${ADVISORY_FAIL_OPEN[@]}"; do
        name="${entry%%:*}"
        printf '%s\n' "$open" | grep -qxF "$name" || stale="$stale $name"
    done
    [ -z "$stale" ] || { echo "allowlisted but missing or no longer fail-open:$stale" >&2; return 1; }
}

# Copy one hook to a temp dir WITHOUT its lib/ and run it on an empty payload.
run_without_lib() {
    local d
    d="$(mktemp -d)"
    cp "$HOOKS/$1" "$d/"
    run --separate-stderr bash -c 'echo "{}" | bash "$1"' _ "$d/$1"
    rm -rf "$d"
}

@test "#1160 pr_merge_threads_guard blocks when lib/gh_budget.sh is missing" {
    run_without_lib pr_merge_threads_guard.sh
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"BLOCKED: cannot source lib/gh_budget.sh"* ]]
}

@test "#1160 pr_template_guard blocks when lib/gh_body_guard_common.sh is missing" {
    run_without_lib pr_template_guard.sh
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"BLOCKED: cannot source lib/gh_body_guard_common.sh"* ]]
}

@test "#1160 issue_template_guard blocks when lib/gh_body_guard_common.sh is missing" {
    run_without_lib issue_template_guard.sh
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"BLOCKED: cannot source lib/gh_body_guard_common.sh"* ]]
}

# commit_body_wrap is a REWRITER, never a gate: without jq or its matcher lib it must let the
# commit through unwrapped (exit 0), never block every commit.
@test "#1162 commit_body_wrap stays fail-open without jq" {
    run_nojq commit_body_wrap.sh
    [ "$status" -eq 0 ]
}

@test "#1160 commit_body_wrap stays fail-open without its matcher lib" {
    run_without_lib commit_body_wrap.sh
    [ "$status" -eq 0 ]
}
