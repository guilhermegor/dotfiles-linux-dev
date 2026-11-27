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
