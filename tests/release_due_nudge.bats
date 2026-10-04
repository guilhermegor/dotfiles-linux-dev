#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/release_due_nudge.sh
#
# Strategy: the hook is a PostToolUse stdin->stdout filter. Every test feeds a payload and asserts
# on the emitted additionalContext (RELEASE DUE / NO RELEASE NEEDED / nothing).
#
# The repo under test is a REAL git repo with a real "origin" remote (a second bare-ish clone dir),
# because the fix under test (dotfiles-linux-dev#156) is precisely about fetching the true remote ref
# instead of trusting a possibly-stale local one — that can't be faked with a mock.
#
# `gh` is faked: `gh pr view [<number>] --json state,baseRefName` reads its answer from
# $GH_PR_VIEW_JSON (set per test) so we control the "MERGED"/base-branch ground truth without
# hitting the network.
#
# Run locally: bats tests/release_due_nudge.bats

setup() {
    HOOK="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/release_due_nudge.sh"

    ORIGIN="$(mktemp -d)"
    git init -q --bare -b main "$ORIGIN"

    TEST_TMP="$(mktemp -d)"
    git clone -q "$ORIGIN" "$TEST_TMP"
    cd "$TEST_TMP"
    git config user.email t@t && git config user.name t

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
    git push -q origin main --tags

    FAKE_BIN="$(mktemp -d)"
    cat > "$FAKE_BIN/gh" <<'EOF'
#!/bin/bash
if [[ "$1" == "pr" && "$2" == "view" ]]; then
    cat "$GH_PR_VIEW_JSON"
    exit 0
fi
exit 1
EOF
    chmod +x "$FAKE_BIN/gh"
    PATH="$FAKE_BIN:$PATH"
    export PATH
}

teardown() {
    rm -rf "$TEST_TMP" "$ORIGIN" "$FAKE_BIN"
}

payload() {
    jq -nc --arg cmd "$1" '{tool_name: "Bash", tool_input: {command: $cmd}}'
}

run_hook() {
    payload "$1" | "$HOOK"
}

# Push a shipped-path change directly to origin (bypassing the local clone), so local main stays
# on the tag while origin/main moves — the "stale local main" scenario.
push_shipped_change_to_origin() {
    local msg="$1"
    local worker
    worker="$(mktemp -d)"
    git clone -q "$ORIGIN" "$worker"
    (cd "$worker" && git config user.email t@t && git config user.name t \
        && mkdir -p src && echo "x" >> src/lib.py && git add src/lib.py \
        && git commit -q -m "$msg" && git push -q origin main)
    rm -rf "$worker"
}

push_docs_only_change_to_origin() {
    local worker
    worker="$(mktemp -d)"
    git clone -q "$ORIGIN" "$worker"
    (cd "$worker" && git config user.email t@t && git config user.name t \
        && mkdir -p docs && echo "x" >> docs/readme.md && git add docs \
        && git commit -q -m "docs: update readme" && git push -q origin main)
    rm -rf "$worker"
}

# Edits a tracked src/*.py file with the given content and pushes it directly to origin (bypassing
# the local clone, same "stale local main" fixture shape as the other push_* helpers).
push_py_edit_to_origin() {
    local msg="$1" content="$2"
    local worker
    worker="$(mktemp -d)"
    git clone -q "$ORIGIN" "$worker"
    (cd "$worker" && git config user.email t@t && git config user.name t \
        && mkdir -p src && printf '%s' "$content" > src/lib.py && git add src/lib.py \
        && git commit -q -m "$msg" && git push -q origin main)
    rm -rf "$worker"
}

# A non-.py file under a shipped path, changed and pushed directly to origin — the fallback path
# the AST check cannot cover (dotfiles-linux-dev#100: non-.py must always be treated as a real change).
push_non_py_shipped_change_to_origin() {
    local worker
    worker="$(mktemp -d)"
    git clone -q "$ORIGIN" "$worker"
    (cd "$worker" && git config user.email t@t && git config user.name t \
        && mkdir -p src && echo "x" >> src/config.yaml && git add src/config.yaml \
        && git commit -q -m "fix: bump config value" && git push -q origin main)
    rm -rf "$worker"
}

merged_json() {
    jq -nc --arg base "$1" '{state: "MERGED", baseRefName: $base}'
}

# --- the core regression: gh pr merge must be detected, in its real forms --------------------

@test "RELEASE DUE: gh pr merge <number> --squash, shipped path changed on origin/main" {
    push_shipped_change_to_origin "feat: add thing"
    GH_PR_VIEW_JSON="$(mktemp)"; merged_json main > "$GH_PR_VIEW_JSON"; export GH_PR_VIEW_JSON

    run run_hook "gh pr merge 42 --squash"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RELEASE DUE"* ]]
}

@test "RELEASE DUE: gh pr merge --merge (no number), shipped path changed" {
    push_shipped_change_to_origin "fix: patch thing"
    GH_PR_VIEW_JSON="$(mktemp)"; merged_json main > "$GH_PR_VIEW_JSON"; export GH_PR_VIEW_JSON

    run run_hook "gh pr merge --merge"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RELEASE DUE"* ]]
}

@test "RELEASE DUE: gh pr merge <number> --rebase --repo owner/name" {
    push_shipped_change_to_origin "feat: add other thing"
    GH_PR_VIEW_JSON="$(mktemp)"; merged_json main > "$GH_PR_VIEW_JSON"; export GH_PR_VIEW_JSON

    run run_hook "gh pr merge 7 --rebase --repo guilhermegor/dotfiles-dev"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RELEASE DUE"* ]]
}

@test "RELEASE DUE: rtk-prefixed gh pr merge" {
    push_shipped_change_to_origin "feat: add rtk thing"
    GH_PR_VIEW_JSON="$(mktemp)"; merged_json main > "$GH_PR_VIEW_JSON"; export GH_PR_VIEW_JSON

    run run_hook "rtk gh pr merge 9 --squash"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RELEASE DUE"* ]]
}

# --- the fix's specific claim: a stale LOCAL main does not hide the release ---------------------

@test "regression guard: local origin/main is stale before the hook runs, yet it still nudges" {
    push_shipped_change_to_origin "feat: shipped while local main was stale"
    GH_PR_VIEW_JSON="$(mktemp)"; merged_json main > "$GH_PR_VIEW_JSON"; export GH_PR_VIEW_JSON

    # Sanity on the fixture: nobody has fetched in TEST_TMP since the clone, so the LOCAL
    # remote-tracking ref genuinely does not have the commit yet. If the hook's own `git fetch`
    # were removed, this diff would come back empty and the hook would wrongly say NO RELEASE
    # NEEDED instead of RELEASE DUE — that's the exact bug dotfiles-linux-dev#156 reports.
    stale_diff="$(git diff --name-only v1.0.0..origin/main -- src/)"
    [ -z "$stale_diff" ]

    run run_hook "gh pr merge 55 --squash"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RELEASE DUE"* ]]
}

# --- must NOT nudge on cases that only look like a release --------------------------------------

@test "NO RELEASE NEEDED: merged PR only touched docs/" {
    push_docs_only_change_to_origin
    GH_PR_VIEW_JSON="$(mktemp)"; merged_json main > "$GH_PR_VIEW_JSON"; export GH_PR_VIEW_JSON

    run run_hook "gh pr merge 3 --squash"
    [ "$status" -eq 0 ]
    [[ "$output" == *"NO RELEASE NEEDED"* ]]
}

@test "silent: PR merged into a non-release branch" {
    push_shipped_change_to_origin "feat: shipped on a dev branch"
    GH_PR_VIEW_JSON="$(mktemp)"; merged_json develop > "$GH_PR_VIEW_JSON"; export GH_PR_VIEW_JSON

    run run_hook "gh pr merge 3 --squash"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "silent: gh reports the PR as not actually merged" {
    push_shipped_change_to_origin "feat: not really merged"
    GH_PR_VIEW_JSON="$(mktemp)"
    jq -nc '{state: "OPEN", baseRefName: "main"}' > "$GH_PR_VIEW_JSON"
    export GH_PR_VIEW_JSON

    run run_hook "gh pr merge 3 --squash"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "silent: not a gh pr merge command at all" {
    run run_hook "gh pr view 3"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "ignores non-Bash tools" {
    run bash -c "jq -nc '{tool_name: \"Read\", tool_input: {command: \"gh pr merge 3\"}}' | '$HOOK'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- regression: the existing local-sync path still works ---------------------------------------

@test "RELEASE DUE still fires on a plain git pull while on main" {
    echo "x" >> src/lib.py
    git add src/lib.py
    git commit -q -m "feat: via local sync"

    run run_hook "git pull"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RELEASE DUE"* ]]
}

# --- dotfiles-linux-dev#99: bump type must come from shipped-path commits only, not the whole log -----

@test "bump is patch: feat touches only .github/, fix touches src/ (not vacuous vs current impl)" {
    mkdir -p .github
    echo "x" >> .github/workflow.yml
    git add .github
    git commit -q -m "feat(ci): weekly drift detector"

    echo "x" >> src/lib.py
    git add src/lib.py
    git commit -q -m "fix(us): probe for the cookie banner"

    run run_hook "git pull"
    [ "$status" -eq 0 ]
    # Proves non-vacuous: the unfixed highest_signal() scans ALL commits since the tag and would
    # see the feat(ci) subject line first, proposing 1.1.0 (feat) instead of the correct 1.0.1 (fix)
    # — this assertion fails against the pre-fix implementation.
    [[ "$output" == *"RELEASE DUE: 1.0.1 (fix)"* ]]
    [[ "$output" != *"(feat)"* ]]
}

@test "bump is minor: feat touches src/ directly" {
    echo "x" >> src/lib.py
    git add src/lib.py
    git commit -q -m "feat: new capability shipped in the package"

    run run_hook "git pull"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RELEASE DUE: 1.1.0 (feat)"* ]]
}

@test "NO RELEASE NEEDED: feat(ci) outside shipped paths alongside chore/docs" {
    mkdir -p .github docs
    echo "x" >> .github/workflow.yml
    git add .github
    git commit -q -m "feat(ci): weekly drift detector"

    echo "x" >> docs/readme.md
    git add docs
    git commit -q -m "docs: update readme"

    run run_hook "git pull"
    [ "$status" -eq 0 ]
    [[ "$output" == *"NO RELEASE NEEDED"* ]]
}

# --- dotfiles-linux-dev#100: shipped diff non-empty is not sufficient — AST-identical means no release --

@test "NO RELEASE NEEDED (comment-only): edit only a comment inside tracked .py path" {
    push_py_edit_to_origin "docs: reword comment" \
        $'def add(a, b):\n    # add two ints together, nothing else\n    return a + b\n\n\nGREETING = "hello"\n'
    GH_PR_VIEW_JSON="$(mktemp)"; merged_json main > "$GH_PR_VIEW_JSON"; export GH_PR_VIEW_JSON

    run run_hook "gh pr merge 11 --squash"
    [ "$status" -eq 0 ]
    [[ "$output" == *"NO RELEASE NEEDED"* ]]
    [[ "$output" == *"comment-only"* ]]
    # Non-vacuity: the pre-fix implementation has no semantic_diff_empty check, so a non-empty byte
    # diff on a shipped .py path always fired RELEASE DUE — this assertion fails against that.
    [[ "$output" != *"RELEASE DUE"* ]]
}

@test "RELEASE DUE: a one-character change in a string constant is still a real change" {
    push_py_edit_to_origin "fix: correct greeting" \
        $'def add(a, b):\n    # add two ints together\n    return a + b\n\n\nGREETING = "hallo"\n'
    GH_PR_VIEW_JSON="$(mktemp)"; merged_json main > "$GH_PR_VIEW_JSON"; export GH_PR_VIEW_JSON

    run run_hook "gh pr merge 12 --squash"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RELEASE DUE"* ]]
}

@test "RELEASE DUE: non-.py shipped file change is always treated as a real change" {
    push_non_py_shipped_change_to_origin
    GH_PR_VIEW_JSON="$(mktemp)"; merged_json main > "$GH_PR_VIEW_JSON"; export GH_PR_VIEW_JSON

    run run_hook "gh pr merge 13 --squash"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RELEASE DUE"* ]]
}

@test "silent: fresh repo with no tags at all" {
    FRESH="$(mktemp -d)"
    (cd "$FRESH" && git init -q -b main . && git config user.email t@t && git config user.name t \
        && mkdir -p .claude src && printf 'src/\n' > .claude/release.conf \
        && git add .claude src && git commit -q -m "chore: init")

    run bash -c "cd '$FRESH' && jq -nc '{tool_name: \"Bash\", tool_input: {command: \"git pull\"}}' | '$HOOK'"
    rm -rf "$FRESH"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
