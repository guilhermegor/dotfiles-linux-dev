#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/release_dispatch_guard.sh
#
# Strategy: the hook is a PreToolUse stdin -> stdout/stderr filter. A block is exit 2 + stderr text;
# an allow (with or without an advisory note) is exit 0. Every test feeds a payload for
# `gh workflow run release-pypi.yaml -f version=X.Y.Z` and asserts on exit status + output.
#
# dotfiles-linux-dev#100: the guard's binding check ("shipped diff since the last tag is empty") is
# correct in one direction only — non-empty proves files were TOUCHED, never that the artifact
# CHANGED. The comment-only tests below cover the false-negative this issue closes: a non-empty
# byte diff that is AST-identical must still block, same as a truly empty diff.
#
# Run locally: bats tests/release_dispatch_guard.bats

setup() {
    HOOK="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/release_dispatch_guard.sh"

    TEST_TMP="$(mktemp -d)"
    cd "$TEST_TMP" || exit 1
    git init -q -b main .
    git config user.email t@t
    git config user.name t

    mkdir -p .claude src
    printf 'src/\n' > .claude/release.conf
    cat > src/lib.py <<'PY'
def add(a, b):
    # add two ints together
    return a + b


GREETING = "hello"
PY
    git add .claude src
    git commit -q -m "chore: init"
    git tag v1.0.0
}

teardown() {
    rm -rf "$TEST_TMP"
}

payload() {
    jq -nc --arg cmd "$1" '{tool_name: "Bash", tool_input: {command: $cmd}}'
}

run_hook() {
    payload "$1" | "$HOOK"
}

commit_py() {
    local msg="$1" content="$2"
    printf '%s' "$content" > src/lib.py
    git add src/lib.py
    git commit -q -m "$msg"
}

# --- the base case: no shipped-path change since the tag -> BLOCK -------------------------------

@test "BLOCKED: no shipped change since last tag" {
    run run_hook "gh workflow run release-pypi.yaml -f version=1.0.1"
    [ "$status" -eq 2 ]
    [[ "$output" == *"BLOCKED"* ]]
    [[ "$output" == *"no shipped-artifact change"* ]]
}

# --- dotfiles-linux-dev#100: shipped diff non-empty is not sufficient — AST-identical must still BLOCK --

@test "BLOCKED (comment-only): edit only a comment inside tracked .py path" {
    commit_py "docs: reword comment" \
        $'def add(a, b):\n    # add two ints together, nothing else\n    return a + b\n\n\nGREETING = "hello"\n'

    run run_hook "gh workflow run release-pypi.yaml -f version=1.0.1"
    # Non-vacuity: the pre-fix guard only checked shipped_diff_empty (the raw byte diff), which is
    # non-empty here — it would ALLOW (exit 0) instead of blocking. This assertion fails there.
    [ "$status" -eq 2 ]
    [[ "$output" == *"BLOCKED"* ]]
    [[ "$output" == *"comment-only"* ]]
}

@test "ALLOWED: a one-character change in a string constant is still a real change" {
    commit_py "fix: correct greeting" \
        $'def add(a, b):\n    # add two ints together\n    return a + b\n\n\nGREETING = "hallo"\n'

    run run_hook "gh workflow run release-pypi.yaml -f version=1.0.1"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "ALLOWED: non-.py shipped file change is always treated as a real change" {
    echo "x" >> src/config.yaml
    git add src/config.yaml
    git commit -q -m "fix: bump config value"

    run run_hook "gh workflow run release-pypi.yaml -f version=1.0.1"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- regression: dispatch matching, non-Bash tools, no-tags fail-open ----------------------------

@test "ignores non-Bash tools" {
    run bash -c "jq -nc '{tool_name: \"Read\", tool_input: {command: \"gh workflow run release-pypi.yaml -f version=1.0.1\"}}' | '$HOOK'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "silent: not a release-pypi workflow dispatch" {
    run run_hook "gh workflow run ci.yaml"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "silent: fresh repo with no tags at all" {
    FRESH="$(mktemp -d)"
    (cd "$FRESH" && git init -q -b main . && git config user.email t@t && git config user.name t \
        && mkdir -p .claude src && printf 'src/\n' > .claude/release.conf \
        && git add .claude src && git commit -q -m "chore: init")

    run bash -c "cd '$FRESH' && jq -nc '{tool_name: \"Bash\", tool_input: {command: \"gh workflow run release-pypi.yaml -f version=0.1.0\"}}' | '$HOOK'"
    rm -rf "$FRESH"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- dotfiles-linux-dev#836: judge origin/<base>, never the checkout's local HEAD ---------------

# Wire the fixture repo to a bare origin (main + tags pushed) and set $OTHER to a second clone, so
# a test can land a commit on the remote that the fixture repo has not fetched.
with_origin() {
    ORIGIN="$(mktemp -d)"
    git init -q --bare -b main "$ORIGIN"
    git remote add origin "$ORIGIN"
    git push -q origin main --tags
    OTHER="$(mktemp -d)"
    git clone -q "$ORIGIN" "$OTHER"
    git -C "$OTHER" config user.email t@t
    git -C "$OTHER" config user.name t
}

@test "ALLOWED: shipped change exists only on origin, local branch is behind" {
    with_origin
    printf 'GREETING = "hallo"\n' > "$OTHER/src/lib.py"
    git -C "$OTHER" commit -q -am "fix: change greeting"
    git -C "$OTHER" push -q origin main

    run run_hook "gh workflow run release-pypi.yaml -f version=1.0.1"
    rm -rf "$ORIGIN" "$OTHER"
    # Non-vacuity: the pre-fix guard diffed local HEAD (== v1.0.0 here), saw nothing and blocked.
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "BLOCKED: shipped change exists only in an unpushed local commit" {
    with_origin
    commit_py "fix: change greeting" $'GREETING = "hallo"\n'

    run run_hook "gh workflow run release-pypi.yaml -f version=1.0.1"
    rm -rf "$ORIGIN" "$OTHER"
    # Non-vacuity: the pre-fix guard diffed local HEAD, saw the unpushed change and allowed.
    [ "$status" -eq 2 ]
    [[ "$output" == *"no shipped-artifact change"* ]]
}

@test "offline: a failed fetch falls back to last-known origin/<base>, never local HEAD" {
    with_origin
    printf 'GREETING = "hallo"\n' > "$OTHER/src/lib.py"
    git -C "$OTHER" commit -q -am "fix: change greeting"
    git -C "$OTHER" push -q origin main
    git fetch -q origin                                   # last-known origin/main carries the change
    git remote set-url origin "$TEST_TMP/does-not-exist"  # now every fetch fails

    run run_hook "gh workflow run release-pypi.yaml -f version=1.0.1"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    # An unpushed local commit must not rescue a last-known origin that has no shipped change.
    git update-ref refs/remotes/origin/main "$(git rev-parse v1.0.0)"
    commit_py "fix: unpushed" $'GREETING = "hi"\n'
    run run_hook "gh workflow run release-pypi.yaml -f version=1.0.1"
    rm -rf "$ORIGIN" "$OTHER"
    [ "$status" -eq 2 ]
}

@test "advisory: pre-1.0 feat taking the minor axis is flagged (highest_signal reads the log)" {
    git tag -d v1.0.0 >/dev/null
    git tag v0.1.0
    commit_py "feat: change greeting" $'GREETING = "hallo"\n'

    run run_hook "gh workflow run release-pypi.yaml -f version=0.2.0"
    # Non-vacuity: the `"$ref"--format` typo made git log fail, so the signal was always "none".
    [ "$status" -eq 0 ]
    [[ "$output" == *"highest commit signal since the tag is feat"* ]]
}
