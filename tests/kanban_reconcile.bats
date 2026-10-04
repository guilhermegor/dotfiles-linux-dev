#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/kanban_reconcile.sh (dotfiles-linux-dev#448)
#
# Strategy (same shape as roadmap_unblock.bats / kanban_lifecycle.bats): a fake `gh` script is
# placed first on PATH so these tests never touch the network or a real project board. It logs
# every invocation to $GH_LOG and answers `project list`/`project field-list`/`pr list`/
# `project item-list`/`project item-edit`/`api graphql` from fixture files this test writes.
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    LIB="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/lib/kanban_reconcile.sh"
    TEST_TMP="$(mktemp -d)"
    FAKE_BIN="$TEST_TMP/bin"
    mkdir -p "$FAKE_BIN"
    PATH="$FAKE_BIN:$PATH"
    export GH_LOG="$TEST_TMP/gh.log"
    : > "$GH_LOG"

    # Isolate the board-id cache from any real ~/.claude/kanban-boards on a dev machine.
    export CLAUDE_CONFIG_DIR="$TEST_TMP/claude-home"

    # Default board: Backlog < In progress < In review < Done (order is what the reconcile ranks
    # against — never hardcoded in the lib itself).
    cat > "$TEST_TMP/fields.json" <<'JSON'
{"fields":[{"name":"Status","id":"FIELD_1","options":[
    {"name":"Backlog","id":"OPT_BACKLOG"},
    {"name":"In progress","id":"OPT_PROGRESS"},
    {"name":"In review","id":"OPT_REVIEW"},
    {"name":"Done","id":"OPT_DONE"}
]}]}
JSON
}

teardown() {
    rm -rf "$TEST_TMP"
}

# write_prs NUMBER...
# The bare numbers `gh pr list ... --jq '.[].number'` would print, one per line.
write_prs() {
    printf '%s\n' "$@" > "$TEST_TMP/prs.txt"
}

# item ID STATUS NUMBER [REPO_NAME_WITH_OWNER]
# `gh project item-list --format json` carries `.content.repository` (verified live against a
# real board), and a project can hold cards from several repositories — so the fixture models
# it too, defaulting to this suite's own owner/repo.
item() {
    jq -nc --arg id "$1" --arg status "$2" --argjson number "$3" --arg repo "${4:-owner/repo}" \
        '{id: $id, status: $status, content: {type: "Issue", number: $number, repository: $repo}}'
}

write_items() {
    printf '%s\n' "$@" | jq -sc '{items: .}' > "$TEST_TMP/items.json"
}

# write_closing PR_NUMBER ISSUE_NUMBER:STATE[:REPO]...
# Registers the closingIssuesReferences GraphQL response for one PR. A bare "FAIL" makes that
# PR's read fail (simulating a 403/network error); a bare "TRUNCATED" returns a page with
# hasNextPage=true, which the reader must treat as that PR's own unknown rather than a subset.
# Each node carries `repository.nameWithOwner` because closingIssuesReferences can name an
# issue in another repository; the third field defaults to this suite's own owner/repo.
write_closing() {
    local pr="$1"; shift
    if [ "$1" = "FAIL" ]; then
        echo FAIL > "$TEST_TMP/closing-$pr.json"
        return
    fi
    local has_next=false
    if [ "$1" = "TRUNCATED" ]; then
        has_next=true
        shift
    fi
    local nodes="[]" pair number state repo rest
    for pair in "$@"; do
        number="${pair%%:*}"
        rest="${pair#*:}"
        state="${rest%%:*}"
        if [ "$rest" = "$state" ]; then repo="owner/repo"; else repo="${rest#*:}"; fi
        nodes="$(printf '%s' "$nodes" | jq -c --argjson n "$number" --arg s "$state" --arg r "$repo" \
            '. + [{number: $n, state: $s, repository: {nameWithOwner: $r}}]')"
    done
    jq -nc --argjson nodes "$nodes" --argjson hasNext "$has_next" \
        '{data: {repository: {pullRequest: {closingIssuesReferences:
            {pageInfo: {hasNextPage: $hasNext}, nodes: $nodes}}}}}' \
        > "$TEST_TMP/closing-$pr.json"
}

# write_board_cache
# Pre-populates the on-disk board cache `board_config` reads, so a test can fail `gh project
# field-list` for `_kr_status_names`'s OWN read (dotfiles-linux-dev#567) without also breaking
# `board_config`'s unrelated discover-on-cache-miss call to the same porcelain subcommand.
write_board_cache() {
    mkdir -p "$CLAUDE_CONFIG_DIR/kanban-boards"
    jq -n '{project_number: 1, project_node_id: "PVT_1", status_field_id: "FIELD_1",
        options: {Backlog: "OPT_BACKLOG", "In progress": "OPT_PROGRESS",
                  "In review": "OPT_REVIEW", Done: "OPT_DONE"}}' \
        > "$CLAUDE_CONFIG_DIR/kanban-boards/owner-repo.json"
}

# write_throttled
# Makes the `_board_throttled` probe (`gh api graphql -f query='query{rateLimit{remaining}}'`)
# fail with rate-limit-shaped text, confirming a throttle. Absent (the default): the probe
# succeeds, i.e. GraphQL itself is healthy.
write_throttled() {
    touch "$TEST_TMP/throttled"
}

# graphql_node ID NUMBER REPO STATUS
# One `repositoryOwner.projectV2.items.nodes[]` entry, shaped like the real GraphQL response
# `_board_item_list_graphql` translates into the porcelain's own `{"items":[...]}` JSON.
graphql_node() {
    jq -nc --arg id "$1" --argjson number "$2" --arg repo "$3" --arg status "$4" \
        --argjson fvNext "${FIELD_VALUES_HAS_NEXT:-false}" '
        {id: $id, content: {__typename: "Issue", number: $number, url: "", body: "",
            repository: {nameWithOwner: $repo}},
         fieldValues: {pageInfo: {hasNextPage: $fvNext}, nodes: [{__typename: "ProjectV2ItemFieldSingleSelectValue",
            name: $status, field: {name: "Status"}}]}}
    '
}

# write_item_list_graphql [TRUNCATED] NODE_JSON... | FAIL
# Registers the `gh api graphql` fallback response `_board_item_list_graphql` reads when the
# `project item-list` porcelain call has failed and no throttle was confirmed. A leading
# "TRUNCATED" sets `hasNextPage: true` — the single-page fallback's own truncation case.
write_item_list_graphql() {
    if [ "$1" = "FAIL" ]; then
        echo FAIL > "$TEST_TMP/item-fallback.json"
        return
    fi
    local has_next=false
    if [ "$1" = "TRUNCATED" ]; then
        has_next=true
        shift
    fi
    printf '%s\n' "$@" | jq -sc --argjson hasNext "$has_next" \
        '{data: {repositoryOwner: {projectV2: {items: {pageInfo: {hasNextPage: $hasNext}, nodes: .}}}}}' \
        > "$TEST_TMP/item-fallback.json"
}

# write_status_names_graphql NAME... | FAIL
# Registers the `gh api graphql` fallback response `_kr_status_names` reads when `project
# field-list` has failed and no throttle was confirmed.
write_status_names_graphql() {
    if [ "$1" = "FAIL" ]; then
        echo FAIL > "$TEST_TMP/status-fallback.json"
        return
    fi
    printf '%s\n' "$@" | jq -R '{name: .}' | jq -sc \
        '{data: {repositoryOwner: {projectV2: {fields: {nodes: [{name: "Status", options: .}]}}}}}' \
        > "$TEST_TMP/status-fallback.json"
}

write_fake_gh() {
    cat > "$FAKE_BIN/gh" <<EOF
#!/bin/bash
echo "\$*" >> "$GH_LOG"
case "\$1 \$2" in
    "project list")
        echo '{"projects":[{"title":"repo kanban","number":1,"id":"PVT_1"}]}'
        ;;
    "project field-list")
        [ -f "$TEST_TMP/fail-field-list" ] && exit 1
        cat "$TEST_TMP/fields.json"
        ;;
    "pr list")
        [ -f "$TEST_TMP/fail-pr-list" ] && exit 1
        cat "$TEST_TMP/prs.txt" 2>/dev/null
        ;;
    "project item-list")
        [ -f "$TEST_TMP/fail-item-list" ] && exit 1
        cat "$TEST_TMP/items.json"
        ;;
    "project item-edit")
        [ -f "$TEST_TMP/fail-item-edit" ] && exit 1
        # Fails the FIRST edit only, then succeeds — the stale-cache shape, where the retry
        # after a board refresh is what must rescue the move.
        if [ -f "$TEST_TMP/fail-item-edit-once" ]; then
            rm -f "$TEST_TMP/fail-item-edit-once"
            exit 1
        fi
        echo ok
        ;;
    "api graphql")
        full="\$*"
        if printf '%s' "\$full" | grep -q 'rateLimit'; then
            if [ -f "$TEST_TMP/throttled" ]; then
                echo 'gh: API rate limit exceeded (RATE_LIMIT)' >&2
                exit 1
            fi
            echo '{"data":{"rateLimit":{"remaining":4999}}}'
        elif printf '%s' "\$full" | grep -q 'pullRequest(number:'; then
            num="\${full#*pullRequest(number:}"
            num="\${num%%)*}"
            f="$TEST_TMP/closing-\$num.json"
            if [ ! -f "\$f" ]; then
                echo '{"data":{"repository":{"pullRequest":{"closingIssuesReferences":{"nodes":[]}}}}}'
            elif [ "\$(cat "\$f")" = "FAIL" ]; then
                exit 1
            else
                cat "\$f"
            fi
        elif printf '%s' "\$full" | grep -q 'items(first'; then
            f="$TEST_TMP/item-fallback.json"
            [ -f "\$f" ] || exit 1
            [ "\$(cat "\$f")" = "FAIL" ] && exit 1
            cat "\$f"
        elif printf '%s' "\$full" | grep -q 'fields(first'; then
            f="$TEST_TMP/status-fallback.json"
            [ -f "\$f" ] || exit 1
            [ "\$(cat "\$f")" = "FAIL" ] && exit 1
            cat "\$f"
        else
            exit 1
        fi
        ;;
    *)
        exit 1
        ;;
esac
EOF
    chmod +x "$FAKE_BIN/gh"
}

refute_gh() {
    run grep -q -- "$1" "$GH_LOG"
    [ "$status" -ne 0 ]
}

run_reconcile() {
    run bash -c "source '$LIB'; reconcile_kanban owner repo; \
        echo \"rc=\$?\"; echo \"STATUS=\$RECONCILE_KANBAN_STATUS\"; \
        echo \"REPORT_START\"; printf '%s\n' \"\$RECONCILE_KANBAN_REPORT\"; echo \"REPORT_END\""
}

# --- (a) Backlog issue with an open closing PR: one item-edit to In review ----------------------

@test "issue in Backlog with an open closing PR is moved to In review" {
    write_prs 10
    write_closing 10 "42:OPEN"
    write_items "$(item ITEM_42 Backlog 42)"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"rc=0"* ]]
    [[ "$output" == *"STATUS=ok"* ]]
    [[ "$output" == *"moved issue #42 to In review"* ]]
    grep -q -- '--id ITEM_42 --field-id FIELD_1 --single-select-option-id OPT_REVIEW' "$GH_LOG"
}

# --- (b) already In review: no call --------------------------------------------------------------

@test "issue already In review triggers no item-edit call" {
    write_prs 10
    write_closing 10 "42:OPEN"
    write_items "$(item ITEM_42 "In review" 42)"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"STATUS=ok"* ]]
    [[ "$output" != *"moved issue"* ]]
    refute_gh 'item-edit'
}

# --- (c) Done with an open referencing PR: never moved backwards --------------------------------

@test "issue in Done with an open referencing PR is left alone (never backwards)" {
    write_prs 10
    write_closing 10 "42:OPEN"
    write_items "$(item ITEM_42 Done 42)"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"STATUS=ok"* ]]
    [[ "$output" != *"moved issue"* ]]
    refute_gh 'item-edit'
}

# --- (d) gh 403 on the PR list / board read: UNKNOWN, zero item-edit calls -----------------------

@test "gh failure listing open PRs: UNKNOWN, nothing touched" {
    touch "$TEST_TMP/fail-pr-list"
    write_items "$(item ITEM_42 Backlog 42)"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"rc=1"* ]]
    [[ "$output" == *"STATUS=unknown"* ]]
    [[ "$output" == *"UNKNOWN"* ]]
    refute_gh 'item-edit'
}

@test "gh 403 resolving one PR's closing issues: reported UNKNOWN for that PR, round continues" {
    write_prs 10 11
    write_closing 10 FAIL
    write_closing 11 "42:OPEN"
    write_items "$(item ITEM_42 Backlog 42)"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"STATUS=ok"* ]]
    [[ "$output" == *"UNKNOWN PR #10"* ]]
    [[ "$output" == *"moved issue #42 to In review"* ]]
}

# --- an unclaimed board / unreadable items: UNKNOWN, fails closed --------------------------------

@test "board items unreadable: STATUS=unknown, non-zero return, nothing touched" {
    write_prs 10
    write_closing 10 "42:OPEN"
    write_fake_gh
    touch "$TEST_TMP/fail-item-list"
    run_reconcile
    [[ "$output" == *"rc=1"* ]]
    [[ "$output" == *"STATUS=unknown"* ]]
    refute_gh 'item-edit'
}

# --- idempotent: an already-moved card produces an empty report on the next round ----------------

@test "idempotent: no cards changed on a re-run once the board reflects In review" {
    write_prs 10
    write_closing 10 "42:OPEN"
    write_items "$(item ITEM_42 "In review" 42)"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"STATUS=ok"* ]]
    # REPORT_START/REPORT_END with nothing meaningful in between (printf on an empty string still
    # emits one blank line).
    [[ "$output" != *"moved issue"* ]]
    refute_gh 'item-edit'
}

# --- two open PRs closing the same issue: moved once, not twice ---------------------------------

@test "two open PRs closing the same issue move its card exactly once" {
    write_prs 10 11
    write_closing 10 "42:OPEN"
    write_closing 11 "42:OPEN"
    write_items "$(item ITEM_42 Backlog 42)"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"moved issue #42 to In review"* ]]
    local edits
    edits="$(grep -c -- '--single-select-option-id OPT_REVIEW' "$GH_LOG")"
    [ "$edits" -eq 1 ]
}

# --- (i) cross-repository issue identity --------------------------------------------------------

@test "a card is matched on repository AND number, never the number alone" {
    write_prs 10
    write_closing 10 "42:OPEN:other/repo"
    write_items "$(item ITEM_MINE Backlog 42)" "$(item ITEM_OTHER Backlog 42 other/repo)"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"STATUS=ok"* ]]
    [[ "$output" == *"moved issue other/repo#42 to In review"* ]]
    grep -q -- '--id ITEM_OTHER ' "$GH_LOG"
    refute_gh '--id ITEM_MINE '
}

# --- (ii) a truncated closingIssuesReferences page is this PR's unknown, not a subset -----------

@test "closingIssuesReferences with hasNextPage is UNKNOWN for that PR, and moves nothing" {
    write_prs 10
    write_closing 10 TRUNCATED "42:OPEN"
    write_items "$(item ITEM_42 Backlog 42)"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"UNKNOWN PR #10"* ]]
    refute_gh 'item-edit'
}

# --- (iii)+(iv) a listing that HIT its cap may be partial: unknown, never a partial ok ----------

@test "open-PR list hitting its cap: STATUS=unknown, nothing touched" {
    # shellcheck disable=SC2046 # deliberate word-splitting: one argument per PR number
    write_prs $(seq 1 200)
    write_items "$(item ITEM_42 Backlog 42)"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"rc=1"* ]]
    [[ "$output" == *"STATUS=unknown"* ]]
    [[ "$output" == *"truncated"* ]]
    refute_gh 'item-edit'
}

@test "project item list hitting its cap: STATUS=unknown, nothing touched" {
    write_prs 10
    write_closing 10 "42:OPEN"
    local many=() i
    for (( i = 1; i <= 500; i++ )); do many+=("$(item "ITEM_$i" Backlog "$i")"); done
    write_items "${many[@]}"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"rc=1"* ]]
    [[ "$output" == *"STATUS=unknown"* ]]
    [[ "$output" == *"truncated"* ]]
    refute_gh 'item-edit'
}

# --- (v) a failed edit invalidates the board cache and retries once ------------------------------

@test "a failed move refreshes the board cache and retries once" {
    write_prs 10
    write_closing 10 "42:OPEN"
    write_items "$(item ITEM_42 Backlog 42)"
    write_fake_gh
    touch "$TEST_TMP/fail-item-edit-once"
    run_reconcile
    [[ "$output" == *"STATUS=ok"* ]]
    [[ "$output" == *"moved issue #42 to In review after a board-cache refresh"* ]]
    [[ "$output" != *"FAILED to move issue #42"* ]]
    # The refresh is real: the board was re-discovered rather than re-read from the stale cache.
    run grep -c 'project field-list' "$GH_LOG"
    [ "$output" -ge 2 ]
}

@test "a move that keeps failing after the refresh is reported FAILED, not ok-and-silent" {
    write_prs 10
    write_closing 10 "42:OPEN"
    write_items "$(item ITEM_42 Backlog 42)"
    write_fake_gh
    touch "$TEST_TMP/fail-item-edit"
    run_reconcile
    [[ "$output" == *"FAILED to move issue #42 to In review"* ]]
}

# --- dotfiles-linux-dev#567: gh project throttle vs a genuinely unreadable board ------------------------

@test "Status column read: field-list fails but GraphQL is healthy, falls back and succeeds" {
    write_board_cache
    write_prs 10
    write_closing 10 "42:OPEN"
    write_items "$(item ITEM_42 Backlog 42)"
    write_status_names_graphql Backlog "In progress" "In review" Done
    write_fake_gh
    touch "$TEST_TMP/fail-field-list"
    run_reconcile
    [[ "$output" == *"STATUS=ok"* ]]
    [[ "$output" == *"moved issue #42 to In review"* ]]
}

@test "Status column read: field-list fails, GraphQL fallback also fails: UNKNOWN board unreadable" {
    write_board_cache
    write_prs 10
    write_items "$(item ITEM_42 Backlog 42)"
    write_status_names_graphql FAIL
    write_fake_gh
    touch "$TEST_TMP/fail-field-list"
    run_reconcile
    [[ "$output" == *"rc=1"* ]]
    [[ "$output" == *"STATUS=unknown"* ]]
    [[ "$output" == *"UNKNOWN (board unreadable): could not read Status column order"* ]]
    refute_gh 'item-edit'
}

@test "Status column read: field-list fails, GraphQL confirms a throttle: UNKNOWN throttled" {
    write_board_cache
    write_prs 10
    write_items "$(item ITEM_42 Backlog 42)"
    write_fake_gh
    touch "$TEST_TMP/fail-field-list"
    write_throttled
    run_reconcile
    [[ "$output" == *"rc=1"* ]]
    [[ "$output" == *"STATUS=unknown"* ]]
    [[ "$output" == *"UNKNOWN (throttled)"* ]]
    refute_gh 'item-edit'
}

@test "project items read: item-list fails but GraphQL is healthy, falls back and succeeds" {
    write_board_cache
    write_prs 10
    write_closing 10 "42:OPEN"
    write_item_list_graphql "$(graphql_node ITEM_42 42 owner/repo Backlog)"
    write_fake_gh
    touch "$TEST_TMP/fail-item-list"
    run_reconcile
    [[ "$output" == *"STATUS=ok"* ]]
    [[ "$output" == *"moved issue #42 to In review"* ]]
    grep -q -- '--id ITEM_42 --field-id FIELD_1 --single-select-option-id OPT_REVIEW' "$GH_LOG"
}

@test "project items read: item-list fails, GraphQL fallback also fails: UNKNOWN board unreadable" {
    write_board_cache
    write_prs 10
    write_closing 10 "42:OPEN"
    write_item_list_graphql FAIL
    write_fake_gh
    touch "$TEST_TMP/fail-item-list"
    run_reconcile
    [[ "$output" == *"rc=1"* ]]
    [[ "$output" == *"STATUS=unknown"* ]]
    [[ "$output" == *"UNKNOWN (board unreadable): could not read project items"* ]]
    refute_gh 'item-edit'
}

@test "project items read: item-list fails, GraphQL confirms a throttle: UNKNOWN throttled" {
    write_board_cache
    write_prs 10
    write_closing 10 "42:OPEN"
    write_fake_gh
    touch "$TEST_TMP/fail-item-list"
    write_throttled
    run_reconcile
    [[ "$output" == *"rc=1"* ]]
    [[ "$output" == *"STATUS=unknown"* ]]
    [[ "$output" == *"UNKNOWN (throttled)"* ]]
    refute_gh 'item-edit'
}

@test "project items read: an item with truncated field values is unreadable, never a backward move" {
    write_board_cache
    write_prs 10
    write_closing 10 "42:OPEN"
    # Done card whose Status value fell off the field-values page: reading it as "no status"
    # would move it back to In review.
    write_item_list_graphql "$(FIELD_VALUES_HAS_NEXT=true graphql_node ITEM_42 42 owner/repo Done)"
    write_fake_gh
    touch "$TEST_TMP/fail-item-list"
    run_reconcile
    [[ "$output" == *"STATUS=unknown"* ]]
    refute_gh 'item-edit'
}

@test "project items read: a truncated GraphQL fallback page is unreadable, never a partial read" {
    write_board_cache
    write_prs 10
    write_closing 10 "42:OPEN"
    write_item_list_graphql TRUNCATED "$(graphql_node ITEM_42 42 owner/repo Backlog)"
    write_fake_gh
    touch "$TEST_TMP/fail-item-list"
    run_reconcile
    [[ "$output" == *"STATUS=unknown"* ]]
    refute_gh 'item-edit'
}
