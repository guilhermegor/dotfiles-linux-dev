#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/pr_template_guard.sh
#
# Strategy:
#   - The hook is a stdin->exit-code filter: it reads a PreToolUse JSON payload and exits 0 (allow)
#     or 2 (block), speaking only through stderr.
#   - find_template() resolves the template via `git rev-parse --show-toplevel`, so every test runs
#     inside a throwaway git repo that ships a known .github/PULL_REQUEST_TEMPLATE.md. That gives us
#     deterministic section headers (## Description / ## Testing) to satisfy or withhold.
#   - `payload <command>` builds the JSON the harness would send.
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    GUARD="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/pr_template_guard.sh"
    REPO="$(mktemp -d)"
    cd "$REPO"
    git init -q .
    mkdir -p .github
    printf '## Description\n\n## Testing\n' > .github/PULL_REQUEST_TEMPLATE.md
    export -f payload   # make it visible to the `bash -c` subshells that `run` spawns
}

teardown() {
    rm -rf "$REPO"
}

payload() {
    jq -nc --arg cmd "$1" '{tool_name: "Bash", tool_input: {command: $cmd}}'
}

# --- body-file resolution: the #78 fix ---------------------------------------------------------

@test "fails loud when --body-file points to a missing path" {
    run bash -c "payload 'gh pr create --title x --body-file $REPO/nope.md' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"could not be read"* ]]
}

@test "does not false-pass when the missing body-file path is named in the title" {
    # The header texts appear in the command (via --title), which the old fallback would have
    # scanned and passed. An unresolved body-file must fail loud regardless.
    run bash -c "payload 'gh pr create --title \"Description and Testing\" --body-file $REPO/nope.md' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"could not be read"* ]]
}

@test "fails loud and names the cause for an unexpanded shell variable in --body-file" {
    # PreToolUse sees the command before expansion, so $VAR arrives literal and unreadable.
    run bash -c "payload 'gh pr create --title x --body-file \$SP/body.md' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"unexpanded shell variable"* ]]
}

@test "fails loud and names the cause for a literal --body-file outside the project dir (#109)" {
    # A literal, absolute path that is genuinely outside the repo root this hook resolves
    # (dotfiles-dev#109): the old message said "check the path exists and is readable", which
    # is false and sends the author chasing a typo that isn't there. Must name the real cause.
    run bash -c "payload 'gh pr create --title x --body-file /tmp/outside-repo-109/body.md' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"outside the project directory"* ]]
    [[ "$output" != *"unexpanded shell variable"* ]]
}

@test "recommends the git-ignored root-level scratch path, not .git/ (dotfiles-dev#441)" {
    # .git/ is a plain FILE (not a directory) inside a git worktree, so the old advice ("move
    # it into $root/.git/") failed outright there and left orphaned bodies with no lifecycle.
    run bash -c "payload 'gh pr create --title x --body-file /tmp/outside-repo-441/body.md' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *".git-pr-<slug>.md"* ]]
    [[ "$output" != *"e.g. $REPO/.git/"* ]]
}

@test "still names the create-and-consume/typo cause for a literal path inside the repo (#78)" {
    # A literal, absolute path INSIDE the repo root that simply does not exist yet must keep the
    # #78 behaviour (fail loud) without being misdiagnosed as "outside the project directory".
    run bash -c "payload 'gh pr create --title x --body-file $REPO/never-written.md' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"could not be read"* ]]
    [[ "$output" != *"outside the project directory"* ]]
    [[ "$output" != *"unexpanded shell variable"* ]]
}

@test "passes a readable compliant --body-file" {
    printf '## Description\nx\n## Testing\ny\n' > "$REPO/body.md"
    run bash -c "payload 'gh pr create --title x --body-file $REPO/body.md' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "blocks a readable non-compliant --body-file (missing sections)" {
    printf 'just some text, no headers\n' > "$REPO/body.md"
    run bash -c "payload 'gh pr create --title x --body-file $REPO/body.md' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Missing required sections"* ]]
}

# --- inline --body: scanning the command string is still correct -------------------------------

@test "passes an inline --body that has every section" {
    run bash -c "payload 'gh pr create --title x --body \"## Description\\nx\\n## Testing\\ny\"' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "blocks an inline --body missing sections" {
    run bash -c "payload 'gh pr create --title x --body \"nothing useful\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Missing required sections"* ]]
}

# --- pass-through: not our concern -------------------------------------------------------------

@test "ignores non-gh commands" {
    run bash -c "payload 'echo gh pr create --body-file $REPO/nope.md' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "ignores a gh pr edit with no body flag (title-only)" {
    run bash -c "payload 'gh pr edit 5 --title x' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "ignores gh issue create even with a body flag (dotfiles-dev#154 defect 1)" {
    # An issue has no PR-template obligation; the anchored 'gh pr create|edit' match must not
    # widen to any gh create/edit carrying a body.
    run bash -c "payload 'gh issue create --repo guilhermegor/dotfiles-dev --title x --body \"nothing useful\"' | '$GUARD'"
    [ "$status" -eq 0 ]
}

# --- --repo resolution: dotfiles-dev#154 defect 2 -----------------------------------------------
#
# These override HOME to a throwaway directory so ~/github/<name> resolves to a fixture repo
# instead of the real checkout tree, keeping the tests hermetic.

@test "judges a gh pr create --repo TARGET against TARGET's template, not the session cwd's" {
    local fake_home target
    fake_home="$(mktemp -d)"
    target="$fake_home/github/other-repo"
    mkdir -p "$target/.github"
    git init -q "$target"
    printf '## Sign-off\n' > "$target/.github/PULL_REQUEST_TEMPLATE.md"

    # $REPO (session cwd) requires Description/Testing; a body satisfying ONLY the target
    # repo's Sign-off section must still pass — proving the target's template was used.
    run env HOME="$fake_home" bash -c "payload 'gh pr create --repo someowner/other-repo --title x --body \"## Sign-off\"' | '$GUARD'"
    [ "$status" -eq 0 ]
    rm -rf "$fake_home"
}

@test "blocks against the --repo TARGET's sections even when cwd's template would pass" {
    local fake_home target
    fake_home="$(mktemp -d)"
    target="$fake_home/github/other-repo"
    mkdir -p "$target/.github"
    git init -q "$target"
    printf '## Sign-off\n' > "$target/.github/PULL_REQUEST_TEMPLATE.md"

    # This body satisfies $REPO's own Description/Testing template but NOT the target's
    # Sign-off — must block, proving the cwd's template was not the one enforced.
    run env HOME="$fake_home" bash -c "payload 'gh pr create --repo someowner/other-repo --title x --body \"## Description\\n## Testing\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Sign-off"* ]]
    rm -rf "$fake_home"
}

@test "reports unresolvable (not non-compliant) when --repo has no local checkout" {
    local fake_home
    fake_home="$(mktemp -d)"
    run env HOME="$fake_home" bash -c "payload 'gh pr create --repo someowner/ghost-repo --title x --body \"whatever\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"could not"* ]]
    [[ "$output" != *"Missing required sections"* ]]
    rm -rf "$fake_home"
}

# --- command matching is real argv, not a start-anchored regex (CodeRabbit review, PR #371) ----

@test "catches a bad body-file chained after && (was a bypass)" {
    run bash -c "payload 'cd /tmp && gh pr create --title x --body-file $REPO/nope.md' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"could not be read"* ]]
}

@test "catches a bad body-file chained after ; (was a bypass)" {
    run bash -c "payload 'true; gh pr create --title x --body-file $REPO/nope.md' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"could not be read"* ]]
}

@test "catches a bad body-file chained after | (was a bypass)" {
    run bash -c "payload 'echo x | gh pr create --title x --body-file $REPO/nope.md' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"could not be read"* ]]
}

@test "a gh pr create mentioned only inside a heredoc body is not executed, not matched" {
    local cmd
    cmd="cat <<'EOF'
gh pr create --title fake --body-file $REPO/nope.md
EOF"
    run bash -c 'payload "$1" | "$2"' _ "$cmd" "$GUARD"
    [ "$status" -eq 0 ]
}

@test "an unparseable command (unbalanced quote) fails open" {
    run bash -c "payload 'gh pr create --title x --body \"unterminated' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "resolves the REAL --repo even when --title contains decoy --repo text" {
    local fake_home target
    fake_home="$(mktemp -d)"
    target="$fake_home/github/other-repo"
    mkdir -p "$target/.github"
    git init -q "$target"
    printf '## Sign-off\n' > "$target/.github/PULL_REQUEST_TEMPLATE.md"

    # The --title value contains "--repo someowner/decoy-repo", which the old regex-scraping
    # extract_target_repo took as the FIRST --repo match; the REAL --repo (after --title) must
    # win, resolving to `other-repo`'s Sign-off template rather than a nonexistent decoy repo.
    run env HOME="$fake_home" bash -c "payload 'gh pr create --title \"see --repo someowner/decoy-repo\" --repo someowner/other-repo --body \"## Sign-off\"' | '$GUARD'"
    [ "$status" -eq 0 ]
    rm -rf "$fake_home"
}

@test "passes when the resolved --repo target has no PR template of its own" {
    local fake_home target
    fake_home="$(mktemp -d)"
    target="$fake_home/github/no-template-repo"
    mkdir -p "$target"
    git init -q "$target"
    run env HOME="$fake_home" bash -c "payload 'gh pr create --repo someowner/no-template-repo --title x --body \"whatever\"' | '$GUARD'"
    [ "$status" -eq 0 ]
    rm -rf "$fake_home"
}

# --- pflag also accepts attached short flags: `-bX` and `-b=X` (dotfiles-dev#604) --------------
#
# scan_flags() used to read short flags only in the separated form, so `gh pr create -b"…"` or
# `-F<path>` was never seen and the guard passed it unread (fail-open).

@test "blocks an attached -b<body> missing sections" {
    run bash -c "payload 'gh pr create --title x -b\"nothing useful\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Missing required sections"* ]]
}

@test "blocks an -b=<body> missing sections" {
    run bash -c "payload 'gh pr create --title x -b=\"nothing useful\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Missing required sections"* ]]
}

@test "passes an attached -b<body> that has every section" {
    run bash -c "payload 'gh pr create --title x -b\"## Description\\nx\\n## Testing\\ny\"' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "fails loud on an attached -F<missing path>" {
    run bash -c "payload 'gh pr create --title x -F$REPO/nope.md' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"could not be read"* ]]
}

@test "fails loud on an -F=<missing path>" {
    run bash -c "payload 'gh pr create --title x -F=$REPO/nope.md' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"could not be read"* ]]
}

@test "blocks a readable non-compliant attached -F<path>" {
    printf 'just some text, no headers\n' > "$REPO/body.md"
    run bash -c "payload 'gh pr create --title x -F$REPO/body.md' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Missing required sections"* ]]
}

@test "passes a readable compliant -F=<path>" {
    printf '## Description\nx\n## Testing\ny\n' > "$REPO/body.md"
    run bash -c "payload 'gh pr create --title x -F=$REPO/body.md' | '$GUARD'"
    [ "$status" -eq 0 ]
}

@test "judges an attached -R<TARGET> against TARGET's template, not the session cwd's" {
    local fake_home target
    fake_home="$(mktemp -d)"
    target="$fake_home/github/other-repo"
    mkdir -p "$target/.github"
    git init -q "$target"
    printf '## Sign-off\n' > "$target/.github/PULL_REQUEST_TEMPLATE.md"

    # $REPO's own template is satisfied by this body; only the target's Sign-off is not.
    run env HOME="$fake_home" bash -c "payload 'gh pr create -Rsomeowner/other-repo --title x --body \"## Description\\n## Testing\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Sign-off"* ]]
    rm -rf "$fake_home"
}

@test "judges an -R=<TARGET> against TARGET's template, not the session cwd's" {
    local fake_home target
    fake_home="$(mktemp -d)"
    target="$fake_home/github/other-repo"
    mkdir -p "$target/.github"
    git init -q "$target"
    printf '## Sign-off\n' > "$target/.github/PULL_REQUEST_TEMPLATE.md"

    run env HOME="$fake_home" bash -c "payload 'gh pr create -R=someowner/other-repo --title x --body \"## Description\\n## Testing\"' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Sign-off"* ]]
    rm -rf "$fake_home"
}

@test "a separated -b value that looks like an attached flag is taken whole (pflag #594)" {
    # `-b -Fx` is body "-Fx", not a body-file: the separated value is consumed first.
    run bash -c "payload 'gh pr create --title x -b -F$REPO/nope.md' | '$GUARD'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Missing required sections"* ]]
    [[ "$output" != *"could not be read"* ]]
}
