#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/pr_body_orphan_check.sh (dotfiles-linux-dev#441).
#
# Strategy: a throwaway git repo with `.git-pr-*.md` scratch files, and a stubbed `gh` shell
# function (matching the pattern in tests/free_surface.bats / tests/review_thread_gate.bats)
# so the suite never touches the network. The script is invoked as a subprocess via `run`, so
# the stub must be exported for the child bash process to see it.

setup() {
    SCRIPT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/pr_body_orphan_check.sh"
    REPO="$(mktemp -d)"
    git init -q "$REPO"
    # An origin remote is now a PRECONDITION, not decoration: the script derives the repo to
    # query from $root's own remote so it cannot ask one checkout about another's PRs. A repo
    # without one is genuinely unscannable and reports UNKNOWN (asserted below).
    git -C "$REPO" remote add origin https://github.com/example/repo.git
}

teardown() {
    rm -rf "$REPO"
}

@test "no .git-pr-*.md files: reports nothing found, exits 0" {
    run "$SCRIPT" "$REPO"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No .git-pr-*.md scratch files found"* ]]
}

@test "gh unavailable: every file is UNKNOWN, never orphaned" {
    printf '## Summary\nx\n' > "$REPO/.git-pr-a.md"
    # Shadow the `command` builtin so `command -v gh` reports absent, without touching PATH
    # (this machine has a real gh — hiding it via PATH would risk a live network call if the
    # shadow leaked). `builtin command` bypasses the shadow for every other lookup.
    command() {
        [[ "$1" == "-v" && "$2" == "gh" ]] && return 1
        builtin command "$@"
    }
    export -f command
    run "$SCRIPT" "$REPO"
    [ "$status" -eq 0 ]
    [[ "$output" == *"UNKNOWN"* ]]
    [[ "$output" == *".git-pr-a.md"* ]]
    [[ "$output" != *"NO MATCHING PR FOUND"* ]]
}

gh_fail() { return 1; }

@test "gh call fails (rate limit / network): fails CLOSED to UNKNOWN, not orphaned" {
    printf '## Summary\nx\n' > "$REPO/.git-pr-b.md"
    gh() { gh_fail; }
    export -f gh gh_fail
    run "$SCRIPT" "$REPO"
    [ "$status" -eq 0 ]
    [[ "$output" == *"UNKNOWN"* ]]
    [[ "$output" != *"NO MATCHING PR FOUND"* ]]
}

@test "content matches an existing PR body: MATCHED" {
    printf '## Summary\nfixes the thing\n' > "$REPO/.git-pr-c.md"
    gh() { printf '[{"body":"## Summary\\nfixes the thing\\n"}]'; }
    export -f gh
    run "$SCRIPT" "$REPO"
    [ "$status" -eq 0 ]
    [[ "$output" == *"MATCHED"* ]]
    [[ "$output" == *".git-pr-c.md"* ]]
    [[ "$output" != *"NO MATCHING PR FOUND"* ]]
}

@test "content matches no PR body: reported as no matching PR, never deleted" {
    printf '## Summary\nnever opened\n' > "$REPO/.git-pr-d.md"
    gh() { printf '[{"body":"## Summary\\nsomething else entirely\\n"}]'; }
    export -f gh
    run "$SCRIPT" "$REPO"
    [ "$status" -eq 0 ]
    [[ "$output" == *"NO MATCHING PR FOUND"* ]]
    [[ "$output" == *".git-pr-d.md"* ]]
    [ -f "$REPO/.git-pr-d.md" ]
}

@test "no origin remote: cannot resolve the repo, so UNKNOWN — never orphaned" {
    printf '## Summary\nx\n' > "$REPO/.git-pr-e.md"
    git -C "$REPO" remote remove origin
    gh() { printf '[{"body":"## Summary\\nsomething else\\n"}]'; }
    export -f gh
    run "$SCRIPT" "$REPO"
    [ "$status" -eq 0 ]
    [[ "$output" == *"UNKNOWN"* ]]
    [[ "$output" != *"NO MATCHING PR FOUND"* ]]
}

@test "PR history saturates the ceiling: UNKNOWN, never a false orphan" {
    printf '## Summary\nnever opened\n' > "$REPO/.git-pr-f.md"
    # One MORE body than the ceiling — the script asks for ceiling+1 precisely so a saturated
    # page is detectable. Without the check this file reads as an orphan because the PR that
    # owns it fell off the end of the page.
    export PR_BODY_SCAN_CEILING=2
    gh() { printf '[{"body":"a"},{"body":"b"},{"body":"c"}]'; }
    export -f gh
    run "$SCRIPT" "$REPO"
    [ "$status" -eq 0 ]
    [[ "$output" == *"UNKNOWN"* ]]
    [[ "$output" != *"NO MATCHING PR FOUND"* ]]
}

@test "queries the repo from \$root's remote, not the caller's cwd" {
    printf '## Summary\nx\n' > "$REPO/.git-pr-g.md"
    # REPO must be exported: the stub runs in the script's own subprocess, where an
    # unexported REPO expands to empty and the redirect lands outside the temp dir.
    export REPO
    gh() { printf '%s\n' "$@" > "$REPO/gh-args"; printf '[{"body":"x"}]'; }
    export -f gh
    run "$SCRIPT" "$REPO"
    [ "$status" -eq 0 ]
    grep -q -- '--repo' "$REPO/gh-args"
    grep -q 'example/repo' "$REPO/gh-args"
}
