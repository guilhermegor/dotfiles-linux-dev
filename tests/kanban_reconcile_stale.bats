#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/kanban_reconcile_stale.sh (dotfiles-linux-dev#888)
#
# Same fixture shape as tests/kanban_reconcile_done.bats: a fake `gh` first on PATH answers the
# board reads and the REST listings from fixture files, logging every call to $GH_LOG. `git` is
# the real binary against a throwaway repo whose `origin` is itself.

setup() {
    LIB_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/lib"
    TEST_TMP="$(mktemp -d)"
    FAKE_BIN="$TEST_TMP/bin"
    mkdir -p "$FAKE_BIN"
    PATH="$FAKE_BIN:$PATH"
    export GH_LOG="$TEST_TMP/gh.log"
    : > "$GH_LOG"
    export CLAUDE_CONFIG_DIR="$TEST_TMP/claude-home"

    REPO_DIR="$TEST_TMP/repo"
    git init -q "$REPO_DIR"
    git -C "$REPO_DIR" config user.email t@t.example
    git -C "$REPO_DIR" config user.name t
    git -C "$REPO_DIR" commit -q --allow-empty -m init
    git -C "$REPO_DIR" remote add origin "$REPO_DIR"

    cat > "$TEST_TMP/fields.json" <<'JSON'
{"fields":[{"name":"Status","id":"FIELD_1","options":[
    {"name":"Ready","id":"OPT_READY"},
    {"name":"In progress","id":"OPT_PROGRESS"},
    {"name":"In review","id":"OPT_REVIEW"},
    {"name":"Done","id":"OPT_DONE"}
]}]}
JSON
    echo '[]' > "$TEST_TMP/prs-open.json"
    echo '[]' > "$TEST_TMP/prs-closed.json"
}

teardown() {
    rm -rf "$TEST_TMP"
}

item() {
    jq -nc --arg id "$1" --arg status "$2" --argjson number "$3" \
        '{id: $id, status: $status, content: {type: "Issue", number: $number, repository: "owner/repo"}}'
}

write_items() {
    printf '%s\n' "$@" | jq -sc '{items: .}' > "$TEST_TMP/items.json"
}

write_issues() {
    printf '%s\n' "$@" | jq -sc '.' > "$TEST_TMP/issues.json"
}

open_issue() {
    jq -nc --argjson n "$1" '{number: $n, state: "open", labels: []}'
}

# pr STATE MERGED_AT REF BODY -> appended to the open or closed fixture by STATE
pr() {
    local file="$TEST_TMP/prs-$1.json" merged="$2"
    jq -c --arg ref "$3" --arg body "${4:-}" --arg state "$1" --arg merged "$merged" \
        '. + [{state: $state, merged_at: (if $merged == "" then null else $merged end),
               head: {ref: $ref}, body: $body}]' "$file" > "$file.new"
    mv "$file.new" "$file"
}

# branch NAME DAYS_OLD — a remote branch whose tip is DAYS_OLD days old, fetched into origin/*.
branch() {
    local when
    when="$(($(date +%s) - $2 * 86400))"
    git -C "$REPO_DIR" checkout -q -b "$1"
    GIT_COMMITTER_DATE="@$when" GIT_AUTHOR_DATE="@$when" \
        git -C "$REPO_DIR" commit -q --allow-empty -m work
    git -C "$REPO_DIR" checkout -q -
    git -C "$REPO_DIR" fetch -q origin
}

write_fake_gh() {
    cat > "$FAKE_BIN/gh" <<EOF
#!/bin/bash
echo "\$*" >> "$GH_LOG"
case "\$1 \$2" in
    "project list") echo '{"projects":[{"title":"repo kanban","number":1,"id":"PVT_1"}]}' ;;
    "project field-list") cat "$TEST_TMP/fields.json" ;;
    "project item-list") cat "$TEST_TMP/items.json" ;;
    "project item-edit") [ -f "$TEST_TMP/fail-item-edit" ] && exit 1; echo ok ;;
    *)
        [ "\$1" = api ] || exit 1
        case "\$2" in
            repos/*/issues\?*) cat "$TEST_TMP/issues.json" ;;
            repos/*/pulls\?state=open*)
                [ -f "$TEST_TMP/fail-prs" ] && exit 1
                cat "$TEST_TMP/prs-open.json" ;;
            repos/*/pulls\?state=closed*)
                [ -f "$TEST_TMP/fail-prs" ] && exit 1
                cat "$TEST_TMP/prs-closed.json" ;;
            *) exit 1 ;;
        esac ;;
esac
EOF
    chmod +x "$FAKE_BIN/gh"
}

refute_gh() {
    run grep -q -- "$1" "$GH_LOG"
    [ "$status" -ne 0 ]
}

run_reconcile() {
    run bash -c "source '$LIB_DIR/kanban_reconcile.sh'; source '$LIB_DIR/dispatch_claims.sh'; \
        source '$LIB_DIR/kanban_reconcile_done.sh'; source '$LIB_DIR/kanban_reconcile_stale.sh'; \
        reconcile_kanban_stale owner repo '$REPO_DIR'; \
        echo \"rc=\$?\"; echo \"STATUS=\$RECONCILE_STALE_STATUS\"; \
        echo REPORT_START; printf '%s\n' \"\$RECONCILE_STALE_REPORT\"; echo REPORT_END"
}

# --- PR closed unmerged -> Ready -----------------------------------------------------------

@test "In review, PR closed unmerged, issue open: moved back to Ready" {
    write_issues "$(open_issue 42)"
    write_items "$(item ITEM_42 "In review" 42)"
    pr closed "" "fix/42-thing"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"STATUS=ok"* ]]
    [[ "$output" == *"moved issue #42 to Ready"* ]]
    grep -q -- '--id ITEM_42 --field-id FIELD_1 --single-select-option-id OPT_READY' "$GH_LOG"
}

@test "In review, PR closed unmerged but another PR is open: left alone" {
    write_issues "$(open_issue 42)"
    write_items "$(item ITEM_42 "In review" 42)"
    pr closed "" "fix/42-thing"
    pr open "" "fix/42-retry"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"STATUS=ok"* ]]
    refute_gh 'item-edit'
}

@test "In review, PR merged, issue still open: left alone" {
    write_issues "$(open_issue 42)"
    write_items "$(item ITEM_42 "In review" 42)"
    pr closed "2026-01-01T00:00:00Z" "fix/42-thing"
    write_fake_gh
    run_reconcile
    refute_gh 'item-edit'
}

@test "a Closes #N body matches even when the branch name does not" {
    write_issues "$(open_issue 42)"
    write_items "$(item ITEM_42 "In review" 42)"
    pr closed "" "weird-branch" "Closes #42"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"moved issue #42 to Ready"* ]]
}

@test "issue 4 is not matched by a PR for 42" {
    write_issues "$(open_issue 4)"
    write_items "$(item ITEM_4 "In review" 4)"
    pr closed "" "fix/42-thing" "Closes #42"
    write_fake_gh
    run_reconcile
    refute_gh 'item-edit'
}

# --- In progress, idle: report only --------------------------------------------------------

@test "In progress with an old branch is reported stale and never moved" {
    write_issues "$(open_issue 50)"
    write_items "$(item ITEM_50 "In progress" 50)"
    branch "fix/50-slow" 30
    write_fake_gh
    run_reconcile
    [[ "$output" == *"STALE issue #50"* ]]
    [[ "$output" == *"report only"* ]]
    refute_gh 'item-edit'
}

@test "In progress with a recent commit is not reported" {
    write_issues "$(open_issue 50)"
    write_items "$(item ITEM_50 "In progress" 50)"
    branch "fix/50-fresh" 1
    write_fake_gh
    run_reconcile
    [[ "$output" != *"STALE"* ]]
}

@test "the threshold is the named constant" {
    write_issues "$(open_issue 50)"
    write_items "$(item ITEM_50 "In progress" 50)"
    branch "fix/50-mid" 3
    write_fake_gh
    run bash -c "export KANBAN_STALE_DAYS=2; source '$LIB_DIR/kanban_reconcile.sh'; \
        source '$LIB_DIR/dispatch_claims.sh'; source '$LIB_DIR/kanban_reconcile_done.sh'; \
        source '$LIB_DIR/kanban_reconcile_stale.sh'; \
        reconcile_kanban_stale owner repo '$REPO_DIR'; printf '%s\n' \"\$RECONCILE_STALE_REPORT\""
    [[ "$output" == *"STALE issue #50"* ]]
}

# --- open PR outside In review is counted --------------------------------------------------

@test "an open PR on a card outside In review is counted" {
    write_issues "$(open_issue 60)"
    write_items "$(item ITEM_60 "Ready" 60)"
    pr open "" "feat/60-x"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"open-PR cards outside In review: 1"* ]]
    refute_gh 'item-edit'
}

# --- fail closed ---------------------------------------------------------------------------

@test "an unreadable PR list reports UNKNOWN and moves nothing" {
    write_issues "$(open_issue 42)"
    write_items "$(item ITEM_42 "In review" 42)"
    pr closed "" "fix/42-thing"
    touch "$TEST_TMP/fail-prs"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"rc=1"* ]]
    [[ "$output" == *"STATUS=unknown"* ]]
    [[ "$output" == *"UNKNOWN: could not read pull requests"* ]]
    refute_gh 'item-edit'
}

@test "an unreadable item list reports UNKNOWN and moves nothing" {
    write_issues "$(open_issue 42)"
    echo 'not json' > "$TEST_TMP/items.json"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"STATUS=unknown"* ]]
    refute_gh 'item-edit'
}

@test "a failed move is reported, not claimed" {
    write_issues "$(open_issue 42)"
    write_items "$(item ITEM_42 "In review" 42)"
    pr closed "" "fix/42-thing"
    touch "$TEST_TMP/fail-item-edit"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"FAILED to move issue #42 to Ready"* ]]
}
