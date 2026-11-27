#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/branch_requires_issue_guard.sh
#
# Strategy:
#   - Pure stdin->exit-code filter: feed a PreToolUse JSON payload, assert 0 (allow) / 2 (block).
#   - The guard extracts a new-branch name from the command, then asks the tracker. To keep the
#     BLOCK path deterministic and offline, tests that need a tracker export
#     CLAUDE_ISSUE_TRACKER=github (the env override): a branch with NO issue number then hits
#     `block_no_ref` BEFORE any `gh` call. Tests where no branch is extracted exit 0 before the
#     tracker is ever consulted, so they need no setup.
#
# These tests pin the same-class false-positive from issue #54: the branch-name regex used to run
# greedily over the WHOLE command string, so an unrelated `-c` in a chained/piped command
# (`grep -c 'labels:'`) and a `git switch -c` mentioned inside a heredoc body were mistaken for a
# real branch creation.
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    GUARD="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/branch_requires_issue_guard.sh"
    TEST_TMP="$(mktemp -d)"
    cd "$TEST_TMP"
}

teardown() {
    rm -rf "$TEST_TMP"
}

payload() {
    jq -nc --arg cmd "$1" '{tool_name: "Bash", tool_input: {command: $cmd}}'
}

run_guard() {
    payload "$1" | "$GUARD"
}

# --- Defect (same class as #54): the regex must not cross command boundaries -------------------

@test "allows git switch chained with an unrelated grep -c 'labels:'" {
    export CLAUDE_ISSUE_TRACKER=github
    run run_guard "git switch main && grep -c 'labels:' foo"
    [ "$status" -eq 0 ]
}

@test "allows a git switch -c mentioned inside a heredoc body" {
    export CLAUDE_ISSUE_TRACKER=github
    cmd="$(cat <<'CMD'
gh issue create --title x --body "$(cat <<'EOF'
   git switch -c feat/example-branch
EOF
)"
CMD
)"
    run run_guard "$cmd"
    [ "$status" -eq 0 ]
}

# --- regression: real branch creations are still caught ----------------------------------------

@test "blocks a real git checkout -b with no issue ref" {
    export CLAUDE_ISSUE_TRACKER=github
    run run_guard "git checkout -b scratch/poke-at-it"
    [ "$status" -eq 2 ]
}

@test "blocks git checkout -b after a quoted '<<FAKE' that is not a heredoc (#1154)" {
    export CLAUDE_ISSUE_TRACKER=github
    run run_guard "printf '%s\n' '<<FAKE'
git checkout -b scratch/poke-at-it"
    [ "$status" -eq 2 ]
}

@test "blocks git switch -c after a quoted '<<FAKE' that is not a heredoc (#1154)" {
    export CLAUDE_ISSUE_TRACKER=github
    run run_guard "printf '%s\n' '<<FAKE'
git switch -c wip"
    [ "$status" -eq 2 ]
}

@test "blocks a real git switch -c with no issue ref" {
    export CLAUDE_ISSUE_TRACKER=github
    run run_guard "git switch -c wip"
    [ "$status" -eq 2 ]
}

@test "still extracts a real creation that FOLLOWS another command" {
    export CLAUDE_ISSUE_TRACKER=github
    run run_guard "git checkout main && git checkout -b feat/no-number"
    [ "$status" -eq 2 ]
}

@test "still catches a real creation with an intervening flag" {
    export CLAUDE_ISSUE_TRACKER=github
    run run_guard "git checkout -q -b feat/no-number"
    [ "$status" -eq 2 ]
}

# --- regression: non-creations and the escape hatch --------------------------------------------

@test "ignores git status" {
    run run_guard "git status"
    [ "$status" -eq 0 ]
}

@test "ignores git -c config on a commit (not a checkout/switch)" {
    export CLAUDE_ISSUE_TRACKER=github
    run run_guard "git -c user.name=x commit -m y"
    [ "$status" -eq 0 ]
}

@test "honors the escape hatch" {
    export CLAUDE_ISSUE_TRACKER=github
    run run_guard "ALLOW_UNTRACKED_BRANCH=1 git checkout -b scratch/anything"
    [ "$status" -eq 0 ]
}

@test "ignores non-Bash tools" {
    run bash -c "jq -nc '{tool_name: \"Read\", tool_input: {command: \"git checkout -b feat/x\"}}' | '$GUARD'"
    [ "$status" -eq 0 ]
}

# --- #77: a foreign tracker id must fail OPEN, not false-block on a phantom GitHub issue --------
# These are the crux tests. Under github tracking, a branch whose leading slug token is a Linear /
# Jira id (hm-848, ABC-12) previously had its digits (848, 12) read as a GitHub issue number and
# was BLOCKED as a phantom. It must now exit 0 — WITHOUT ever calling `gh` (the check runs before
# ref extraction), so the test is deterministic and offline.

@test "allows a Linear id branch (lowercase key) under github tracking" {
    export CLAUDE_ISSUE_TRACKER=github
    run run_guard "git checkout -b feature/hm-848-fix-thing"
    [ "$status" -eq 0 ]
}

@test "allows a Jira id branch (uppercase key) under github tracking" {
    export CLAUDE_ISSUE_TRACKER=github
    run run_guard "git switch -c ABC-12-payment-bug"
    [ "$status" -eq 0 ]
}

@test "allows a bare Linear id branch with no trailing description" {
    export CLAUDE_ISSUE_TRACKER=github
    run run_guard "git checkout -b feat/dit-456"
    [ "$status" -eq 0 ]
}

# The foreign-id allow is deliberately narrow: the fail-open fires only for a LEADING
# <letters>-<digits> slug token. The negative side is already locked by the no-ref BLOCK tests
# above (scratch/poke-at-it, feat/no-number, wip) — a multi-token non-foreign slug still exits 2,
# so it was NOT misread as foreign (that path exits 0). The gh-dependent "absent GitHub issue
# still blocks" path needs a live repo context, which this offline suite deliberately avoids —
# the same limitation the sibling guard suites accept.
