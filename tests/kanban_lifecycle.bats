#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/kanban_lifecycle.sh
#
# Strategy (same shape as protected_branch_guard.bats):
#   - The hook is a PostToolUse stdin->stdout filter that reads a JSON payload and, on a lifecycle
#     verb, shells out to `gh` to resolve owner/repo, issue state, and the board. Every `gh` call is
#     replaced by a fake `gh` script placed first on PATH so tests never touch the network.
#   - `payload <cmd>` builds the harness JSON; `run_hook <cmd>` pipes it through the hook so the
#     pipe's stdout/exit status IS the hook's.
#
# This pins issue #131: a branch/PR that references an issue whose real state is already CLOSED
# must NOT move that issue's card — Done is native and already fired; moving it again drags the
# card backwards (Done -> In review / In progress) with nothing to correct it afterwards.
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    HOOK="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/kanban_lifecycle.sh"
    TEST_TMP="$(mktemp -d)"
    cd "$TEST_TMP" || exit 1
    git init -q -b main .
    git config user.email t@t && git config user.name t
    git commit -q --allow-empty -m init
    git checkout -q -b feat/131-fix

    FAKE_BIN="$TEST_TMP/bin"
    mkdir -p "$FAKE_BIN"
    PATH="$FAKE_BIN:$PATH"

    # Isolate the hook's board-id cache from the real ~/.claude/kanban-boards — otherwise a stale
    # real cache (present on a dev machine) short-circuits board_config() and the test would pass
    # for reasons unrelated to the fake `gh` responses above.
    export CLAUDE_CONFIG_DIR="$TEST_TMP/claude-home"
}

teardown() {
    rm -rf "$TEST_TMP"
}

payload() {
    jq -nc --arg cmd "$1" '{tool_name: "Bash", tool_input: {command: $cmd}}'
}

# Pipe the payload through the hook; the pipe's status/stdout are the hook's.
run_hook() {
    payload "$1" | "$HOOK"
}

# Fake `gh` covering every subcommand the hook calls: repo view, issue view (state), project
# list/field-list/item-list/item-edit. `$1/$issue_state` controls what `gh issue view` reports.
write_fake_gh() {
    local issue_state="$1"
    cat > "$FAKE_BIN/gh" <<EOF
#!/bin/bash
case "\$1 \$2" in
    "repo view")
        # emulate --json owner,name -q '.owner.login + " " + .name'
        echo "guilhermegor dotfiles-dev"
        ;;
    "issue view")
        # emulate --json state -q .state
        echo "$issue_state"
        ;;
    "project list")
        echo '{"projects":[{"title":"dotfiles-dev kanban","number":1,"id":"PVT_1"}]}'
        ;;
    "project field-list")
        echo '{"fields":[{"name":"Status","id":"FIELD_1","options":[
            {"name":"In progress","id":"OPT_PROGRESS"},
            {"name":"In review","id":"OPT_REVIEW"},
            {"name":"Done","id":"OPT_DONE"}
        ]}]}'
        ;;
    "project item-list")
        echo '{"items":[{"id":"ITEM_1","content":{"type":"Issue","number":131}}]}'
        ;;
    "project item-edit")
        echo '{"id":"ITEM_1"}'
        ;;
    *)
        exit 1
        ;;
esac
EOF
    chmod +x "$FAKE_BIN/gh"
}

write_fake_jq_passthrough() {
    # jq is real (not faked) — only gh is faked. Nothing to do; kept as documentation anchor.
    :
}

# --- regression: an OPEN issue still moves forward as before ------------------------------------

@test "moves the card forward when the issue is OPEN (checkout -b)" {
    write_fake_gh "OPEN"
    run run_hook "git checkout -b feat/131-fix"
    [ "$status" -eq 0 ]
    [[ "$output" == *"moved issue"* ]]
    [[ "$output" == *"In progress"* ]]
}

@test "moves the card forward when the issue is OPEN (gh pr create)" {
    write_fake_gh "OPEN"
    run run_hook "gh pr create --title x --body y"
    [ "$status" -eq 0 ]
    [[ "$output" == *"moved issue"* ]]
    [[ "$output" == *"In review"* ]]
}

# --- #131: a CLOSED issue's card must never move -------------------------------------------------

@test "does NOT move the card when the referenced issue is CLOSED (checkout -b)" {
    write_fake_gh "CLOSED"
    run run_hook "git checkout -b feat/131-fix"
    [ "$status" -eq 0 ]
    [[ "$output" != *"moved issue"* ]]
}

@test "does NOT move the card when the referenced issue is CLOSED (gh pr create)" {
    write_fake_gh "CLOSED"
    run run_hook "gh pr create --title x --body y"
    [ "$status" -eq 0 ]
    [[ "$output" != *"moved issue"* ]]
}

# --- fail-open: an unresolved state (gh error) behaves like today (never blocks) ----------------

@test "fails open and still moves the card when issue state cannot be resolved" {
    cat > "$FAKE_BIN/gh" <<'EOF'
#!/bin/bash
case "$1 $2" in
    "repo view")
        echo "guilhermegor dotfiles-dev"
        ;;
    "issue view")
        exit 1     # network error, auth error, etc. -> empty state
        ;;
    "project list")
        echo '{"projects":[{"title":"dotfiles-dev kanban","number":1,"id":"PVT_1"}]}'
        ;;
    "project field-list")
        echo '{"fields":[{"name":"Status","id":"FIELD_1","options":[
            {"name":"In progress","id":"OPT_PROGRESS"},
            {"name":"In review","id":"OPT_REVIEW"},
            {"name":"Done","id":"OPT_DONE"}
        ]}]}'
        ;;
    "project item-list")
        echo '{"items":[{"id":"ITEM_1","content":{"type":"Issue","number":131}}]}'
        ;;
    "project item-edit")
        echo '{"id":"ITEM_1"}'
        ;;
    *)
        exit 1
        ;;
esac
EOF
    chmod +x "$FAKE_BIN/gh"
    run run_hook "git checkout -b feat/131-fix"
    [ "$status" -eq 0 ]
    [[ "$output" == *"moved issue"* ]]
    [[ "$output" == *"In progress"* ]]
}

# --- #591: `gh pr create --head <b>` moves <b>'s card, never HEAD's -----------------------------
# HEAD is feat/131-fix (setup); the board holds cards for #131 and #564, so a wrong pick is visible
# in the announced issue number rather than as a silent no-op.

write_fake_gh_two_cards() {
    write_fake_gh "OPEN"
    sed -i 's|"items":\[{"id":"ITEM_1","content":{"type":"Issue","number":131}}\]|"items":[{"id":"ITEM_1","content":{"type":"Issue","number":131}},{"id":"ITEM_2","content":{"type":"Issue","number":564}}]|' \
        "$FAKE_BIN/gh"
}

@test "gh pr create --head <b> moves the card of <b>, not HEAD's" {
    write_fake_gh_two_cards
    run run_hook "gh pr create --head fix/564-other --title x --body y"
    [ "$status" -eq 0 ]
    [[ "$output" == *"issue #564"* ]]
}

@test "gh pr create --head=<b> moves the card of <b>" {
    write_fake_gh_two_cards
    run run_hook "gh pr create --head=fix/564-other --title x"
    [ "$status" -eq 0 ]
    [[ "$output" == *"issue #564"* ]]
}

@test "gh pr create -H <b> moves the card of <b>" {
    write_fake_gh_two_cards
    run run_hook "gh pr create -H fix/564-other --title x"
    [ "$status" -eq 0 ]
    [[ "$output" == *"issue #564"* ]]
}

@test "gh pr create --head owner:<b> strips the owner prefix" {
    write_fake_gh_two_cards
    run run_hook "gh pr create --head guilhermegor:fix/564-other --title x"
    [ "$status" -eq 0 ]
    [[ "$output" == *"issue #564"* ]]
}

@test "gh pr create --head with no issue number moves nothing (no fallback to HEAD)" {
    write_fake_gh_two_cards
    run run_hook "gh pr create --head chore/no-number --title x"
    [ "$status" -eq 0 ]
    [[ "$output" != *"moved issue"* ]]
}

@test "gh pr create without --head still uses HEAD's issue" {
    write_fake_gh_two_cards
    run run_hook "gh pr create --title x --body y"
    [ "$status" -eq 0 ]
    [[ "$output" == *"issue #131"* ]]
}

# --- #594 review: `--head` text inside a quoted argument is data, not the flag ------------------

@test "gh pr create with '--head <b>' inside --body still uses HEAD's issue" {
    write_fake_gh_two_cards
    run run_hook "gh pr create --title x --body 'mention --head fix/564-other'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"issue #131"* ]]
}

@test "gh pr create with '-H <b>' inside --title still uses HEAD's issue" {
    write_fake_gh_two_cards
    run run_hook "gh pr create --title \"see -H fix/564-other\" --body y"
    [ "$status" -eq 0 ]
    [[ "$output" == *"issue #131"* ]]
}

@test "gh pr create --head quoted is still honoured" {
    write_fake_gh_two_cards
    run run_hook "gh pr create --head 'fix/564-other' --title x"
    [ "$status" -eq 0 ]
    [[ "$output" == *"issue #564"* ]]
}

@test "gh pr create with an unbalanced quote moves nothing (fail open)" {
    write_fake_gh_two_cards
    run run_hook "gh pr create --title 'x --head fix/564-other"
    [ "$status" -eq 0 ]
    [[ "$output" != *"moved issue"* ]]
}

# --- #594 re-review: pflag also accepts `-H=<b>` and `-H<b>` (spf13/pflag parseSingleShortArg) ---

@test "gh pr create -H=<b> moves the card of <b>" {
    write_fake_gh_two_cards
    run run_hook "gh pr create -H=fix/564-other --title x"
    [ "$status" -eq 0 ]
    [[ "$output" == *"issue #564"* ]]
}

@test "gh pr create -H<b> (attached) moves the card of <b>" {
    write_fake_gh_two_cards
    run run_hook "gh pr create -Hfix/564-other --title x"
    [ "$status" -eq 0 ]
    [[ "$output" == *"issue #564"* ]]
}
