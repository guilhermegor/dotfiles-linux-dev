#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/commit_command_matcher.sh
#
# Direct tests of command_has_git_commit(), the matcher shared by
# commit_title_length_guard.sh, commit_body_wrap.sh and commit_secret_guard.sh
# (dotfiles-linux-dev#324). Per-hook end-to-end coverage lives in each hook's own
# .bats file; this file pins the matcher's own contract so all three hooks
# inherit it correctly.
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    MATCHER="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/lib/commit_command_matcher.sh"
}

# --- issue #324 table: the four invocation shapes -----------------------------------------------

@test "MATCH: bare git commit" {
    run bash -c "source '$MATCHER' && command_has_git_commit 'git commit -m x'"
    [ "$status" -eq 0 ]
}

@test "MATCH: rtk git commit" {
    run bash -c "source '$MATCHER' && command_has_git_commit 'rtk git commit -m x'"
    [ "$status" -eq 0 ]
}

@test "MATCH (was MISS pre-#324): rtk proxy git commit" {
    run bash -c "source '$MATCHER' && command_has_git_commit 'rtk proxy git commit -m x'"
    [ "$status" -eq 0 ]
}

@test "MATCH (was MISS pre-#324): git add -A && rtk proxy git commit" {
    run bash -c "source '$MATCHER' && command_has_git_commit 'git add -A && rtk proxy git commit -m x'"
    [ "$status" -eq 0 ]
}

# --- additional chain operators the fix must also cover --------------------------------------

@test "MATCH: chained after ; " {
    run bash -c "source '$MATCHER' && command_has_git_commit 'git add -A; git commit -m x'"
    [ "$status" -eq 0 ]
}

@test "MATCH: chained after ||" {
    run bash -c "source '$MATCHER' && command_has_git_commit 'git add -A || git commit -m x'"
    [ "$status" -eq 0 ]
}

@test "MATCH: chained after a single pipe" {
    run bash -c "source '$MATCHER' && command_has_git_commit 'echo x | xargs -I{} git commit -m {}'"
    [ "$status" -eq 1 ]  # 'xargs -I{} git commit' — segment starts with xargs, not git/rtk: correctly no match
}

# --- the house-style spellings: absolute path + global flags ------------------------------------
#
# Not hypothetical. The global CLAUDE.md and the dev-loop skill both mandate `/usr/bin/git` where
# the rtk proxy must be bypassed, and discourage `cd <dir> &&` in favour of `git -C <dir>`. Their
# composition below is the exact form this repo's commits are written with — and it was a MISS
# against the first #324 fix, measured while landing that fix.

@test "MATCH (was MISS): absolute path /usr/bin/git commit" {
    run bash -c "source '$MATCHER' && command_has_git_commit '/usr/bin/git commit -m x'"
    [ "$status" -eq 0 ]
}

@test "MATCH (was MISS): global flag between binary and subcommand -- git -C <dir> commit" {
    run bash -c "source '$MATCHER' && command_has_git_commit 'git -C /some/path commit -m x'"
    [ "$status" -eq 0 ]
}

@test "MATCH (was MISS): the composed house form -- /usr/bin/git -C <dir> commit -F <file>" {
    run bash -c "source '$MATCHER' && command_has_git_commit '/usr/bin/git -C /some/path commit -F /tmp/msg'"
    [ "$status" -eq 0 ]
}

@test "MATCH: a valueless global flag -- git --no-pager commit" {
    run bash -c "source '$MATCHER' && command_has_git_commit 'git --no-pager commit -m x'"
    [ "$status" -eq 0 ]
}

@test "MATCH: an inline-value global flag -- git --git-dir=/some/.git commit" {
    run bash -c "source '$MATCHER' && command_has_git_commit 'git --git-dir=/some/.git commit -m x'"
    [ "$status" -eq 0 ]
}

@test "NO MATCH: a global flag's VALUE is skipped, not read as the subcommand" {
    # `-C commit` names a DIRECTORY called commit and then runs `status`. Reading the flag's
    # value as the subcommand would make this a false positive.
    run bash -c "source '$MATCHER' && command_has_git_commit 'git -C commit status'"
    [ "$status" -eq 1 ]
}

# --- false positive: a mere mention must NOT match ---------------------------------------------

@test "NO MATCH: git commit merely mentioned inside an argument" {
    run bash -c "source '$MATCHER' && command_has_git_commit 'gh pr create --body \"run git commit first\"'"
    [ "$status" -eq 1 ]
}

@test "NO MATCH: unrelated command" {
    run bash -c "source '$MATCHER' && command_has_git_commit 'git status'"
    [ "$status" -eq 1 ]
}

@test "NO MATCH: git commit-graph (word-boundary: commit is a distinct token, not a prefix match)" {
    run bash -c "source '$MATCHER' && command_has_git_commit 'git commit-graph write'"
    [ "$status" -eq 1 ]
}

# --- source-only guard -----------------------------------------------------------------------

@test "refuses direct execution (must be sourced)" {
    run bash "$MATCHER"
    [ "$status" -eq 1 ]
    [[ "$output" == *"meant to be sourced"* ]]
}

# --- quoted -C paths (CodeRabbit, PR #325) ------------------------------------------------------
#
# `read -ra` ignores quotes, so `git -C '/tmp/repo with spaces' commit` tokenised as six words and
# the matcher read `with` as the subcommand -> MISS -> the secret guard exited before scanning.

@test "MATCH: single-quoted -C path containing spaces" {
    run bash -c "source '$MATCHER' && command_has_git_commit \"git -C '/tmp/repo with spaces' commit -m x\""
    [ "$status" -eq 0 ]
}

@test "MATCH: double-quoted -C path containing spaces" {
    run bash -c "source '$MATCHER' && command_has_git_commit 'git -C \"/tmp/repo with spaces\" commit -m x'"
    [ "$status" -eq 0 ]
}

# --- COMMIT_COMMAND_GIT_DIR: the effective directory a caller must honour ------------------------

@test "exports the -C directory so callers scan the repo the commit targets" {
    run bash -c "source '$MATCHER' && command_has_git_commit 'git -C /tmp/other commit -m x' && printf '%s' \"\$COMMIT_COMMAND_GIT_DIR\""
    [ "$status" -eq 0 ]
    [ "$output" = "/tmp/other" ]
}

@test "exports the -C directory with spaces intact" {
    run bash -c "source '$MATCHER' && command_has_git_commit \"git -C '/tmp/repo with spaces' commit -m x\" && printf '%s' \"\$COMMIT_COMMAND_GIT_DIR\""
    [ "$status" -eq 0 ]
    [ "$output" = "/tmp/repo with spaces" ]
}

@test "leaves the directory empty for an ordinary same-directory commit" {
    run bash -c "source '$MATCHER' && command_has_git_commit 'git commit -m x' && printf '[%s]' \"\$COMMIT_COMMAND_GIT_DIR\""
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

@test "does not evaluate command substitution while tokenizing" {
    # The matcher must never execute what it inspects. If \$(...) were evaluated, the marker file
    # would exist. Reading it must stay pure text processing.
    marker="$BATS_TEST_TMPDIR/pwned"
    run bash -c "source '$MATCHER' && command_has_git_commit 'git -C \$(touch $marker) commit -m x' || true"
    [ ! -e "$marker" ]
}
