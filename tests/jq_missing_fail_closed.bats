#!/usr/bin/env bats
#
# Every BLOCKING PreToolUse guard must fail CLOSED (exit 2, stderr naming jq) when jq is missing
# from PATH, instead of `command -v jq || exit 0` waving every call through
# (dotfiles-linux-dev#1162). Advisory hooks keep exit 0 and are not covered here.
#
# PATH is a directory of symlinks to bash + common coreutils, deliberately without jq.

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
    run env PATH="$NOJQ" "$NOJQ/bash" -c 'echo "{}" | "$NOJQ/bash" "$1"' _ "$HOOKS/$1"
}

assert_closed() {
    [ "$status" -eq 2 ]
    [[ "$output" == *"jq not found"* ]]
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

@test "#1160 pr_merge_threads_guard blocks when lib/gh_budget.sh is missing" {
    local d
    d="$(mktemp -d)"
    cp "$HOOKS/pr_merge_threads_guard.sh" "$d/"
    run bash -c 'echo "{}" | bash "$1"' _ "$d/pr_merge_threads_guard.sh"
    rm -rf "$d"
    [ "$status" -eq 2 ]
    [[ "$output" == *gh_budget.sh* ]]
}
