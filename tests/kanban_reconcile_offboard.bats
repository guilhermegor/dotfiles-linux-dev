#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/kanban_reconcile_offboard.sh (dotfiles-linux-dev#1021)
# GitHub is stubbed by a fake `gh` first on PATH; every call is logged to $GH_LOG.

setup() {
    LIB_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/lib"
    TEST_TMP="$(mktemp -d)"
    FAKE_BIN="$TEST_TMP/bin"
    mkdir -p "$FAKE_BIN"
    PATH="$FAKE_BIN:$PATH"
    export GH_LOG="$TEST_TMP/gh.log"
    : > "$GH_LOG"
    export CLAUDE_CONFIG_DIR="$TEST_TMP/claude-home"
    export GH_BUDGET_LATCH_FILE="$TEST_TMP/no-latch"
    cat > "$TEST_TMP/fields.json" <<'JSON'
{"fields":[{"name":"Status","id":"FIELD_1","options":[
    {"name":"Backlog","id":"OPT_BACKLOG"},
    {"name":"Ready","id":"OPT_READY"},
    {"name":"Blocked","id":"OPT_BLOCKED"},
    {"name":"Done","id":"OPT_DONE"}
]}]}
JSON
    echo '[]' > "$TEST_TMP/issues.json"
    echo '{"items":[]}' > "$TEST_TMP/items.json"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# issue NUMBER WORK_TYPE BODY — an open issue as the REST listing returns it.
issue() {
    jq -nc --argjson n "$1" --arg t "$2" --arg b "$3" \
        '{number: $n, state: "open", html_url: "https://github.com/owner/repo/issues/\($n)",
          body: $b, labels: [{name: "type:\($t)"}]}'
}

write_issues() { printf '%s\n' "$@" | jq -sc '.' > "$TEST_TMP/issues.json"; }

refute_gh() {
    run grep -q -- "$1" "$GH_LOG"
    [ "$status" -ne 0 ]
}

# blockers NUMBER STATE — native blocked_by of NUMBER holds one issue in STATE.
blockers() {
    jq -nc --arg s "$2" '[{state: $s, number: 99, repository: {full_name: "owner/repo"}}]' \
        > "$TEST_TMP/blockers-$1.json"
}

write_fake_gh() {
    cat > "$FAKE_BIN/gh" <<FAKE
#!/bin/bash
echo "\$*" >> "$GH_LOG"
case "\$1 \$2" in
    "project list") echo '{"projects":[{"title":"repo kanban","number":1,"id":"PVT_1"}]}' ;;
    "project item-list") cat "$TEST_TMP/items.json" ;;
    "project item-add")
        [ -f "$TEST_TMP/fail-item-add" ] && { echo "GraphQL: API rate limit exceeded" >&2; exit 1; }
        echo '{"id":"ITEM_NEW"}' ;;
    "project item-edit") echo ok ;;
    "api graphql")
        # the only board-fields read (#1089); the porcelain field-list is deliberately not stubbed
        [[ "\$*" == *"fields(first:30)"* ]] && { jq -c '{data:{repositoryOwner:{projectV2:{fields:{nodes:.fields}}}}}' "$TEST_TMP/fields.json"; exit 0; }
        [ -f "$TEST_TMP/fail-item-add" ] && { echo "API rate limit exceeded" >&2; exit 1; }
        echo '{}' ;;
    *)
        case "\$2" in
            repos/*/issues\?*) cat "$TEST_TMP/issues.json" ;;
            repos/*/dependencies/blocked_by*)
                n="\${2#repos/owner/repo/issues/}"; n="\${n%%/*}"
                cat "$TEST_TMP/blockers-\$n.json" 2>/dev/null || echo '[]' ;;
            *) exit 1 ;;
        esac ;;
esac
FAKE
    chmod +x "$FAKE_BIN/gh"
}

run_offboard() {
    run bash -c "source '$LIB_DIR/kanban_reconcile.sh'; source '$LIB_DIR/gh_budget.sh'; \
        source '$LIB_DIR/issue_spec_complete.sh'; source '$LIB_DIR/roadmap_unblock.sh'; \
        source '$LIB_DIR/kanban_reconcile_offboard.sh'; \
        reconcile_kanban_offboard owner repo .; echo \"rc=\$?\"; \
        echo \"STATUS=\$RECONCILE_OFFBOARD_STATUS\"; printf '%s\n' \"\$RECONCILE_OFFBOARD_REPORT\""
}

@test "an open issue missing from the board is added and placed in its work-type column" {
    write_issues "$(issue 7 research "x")"
    write_fake_gh
    run_offboard
    [[ "$output" == *"STATUS=ok"* ]]
    [[ "$output" == *"moved issue #7 onto the board in Backlog"* ]]
    grep -q 'project item-add 1 --owner owner --url https://github.com/owner/repo/issues/7' "$GH_LOG"
    grep -q -- '--id ITEM_NEW --field-id FIELD_1 --single-select-option-id OPT_BACKLOG' "$GH_LOG"
}

@test "an off-board issue with an open native blocker lands in Blocked" {
    write_issues "$(issue 8 task "x")"
    blockers 8 open
    write_fake_gh
    run_offboard
    [[ "$output" == *"moved issue #8 onto the board in Blocked"* ]]
    grep -q 'OPT_BLOCKED' "$GH_LOG"
}

@test "a closed native blocker does not block" {
    write_issues "$(issue 8 research "x")"
    blockers 8 closed
    write_fake_gh
    run_offboard
    [[ "$output" == *"in Backlog"* ]]
}

@test "an issue already on the board (even in Done) is not touched" {
    write_issues "$(issue 7 task "x")" "$(issue 9 task "x")"
    jq -nc '{items: [{id: "I7", status: "Done", content: {type: "Issue", number: 7, repository: "owner/repo"}}]}' \
        > "$TEST_TMP/items.json"
    write_fake_gh
    run_offboard
    [[ "$output" != *"#7"* ]]
    [[ "$output" == *"#9"* ]]
    refute_gh 'issues/7'
}

@test "a PR in the issue listing is never added" {
    jq -nc '[{number: 5, pull_request: {}, html_url: "u", labels: []}]' > "$TEST_TMP/issues.json"
    write_fake_gh
    run_offboard
    [[ "$output" == *"STATUS=ok"* ]]
    refute_gh 'item-add'
}

@test "latched: an active GraphQL budget latch reports UNKNOWN (latched) and calls nothing" {
    write_issues "$(issue 7 task "x")"
    write_fake_gh
    echo $(($(date +%s) + 600)) > "$GH_BUDGET_LATCH_FILE"
    run_offboard
    [[ "$output" == *"rc=1"* ]]
    [[ "$output" == *"UNKNOWN (latched)"* ]]
    [ ! -s "$GH_LOG" ]
}

@test "item-add refused by a rate limit writes the latch and reports UNKNOWN (throttled)" {
    write_issues "$(issue 7 research "x")"
    touch "$TEST_TMP/fail-item-add"
    write_fake_gh
    run_offboard
    [[ "$output" == *"rc=1"* ]]
    [[ "$output" == *"UNKNOWN (throttled)"* ]]
    [ -e "$GH_BUDGET_LATCH_FILE" ]
}

@test "a non-array items value is UNKNOWN and adds nothing" {
    write_issues "$(issue 7 task "x")"
    echo '{"items":null}' > "$TEST_TMP/items.json"
    write_fake_gh
    run_offboard
    [[ "$output" == *"rc=1"* ]]
    [[ "$output" == *"could not parse project items"* ]]
    refute_gh 'item-add'
}
