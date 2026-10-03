#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/kanban_reconcile_done.sh (dotfiles-dev#556)
#
# Same fixture shape as tests/kanban_reconcile.bats: a fake `gh` script first on PATH answers
# `project list` / `project field-list` / `project item-list` / `project item-edit` / the
# `repos/<o>/<r>/issues` REST listing from fixture files this test writes, and logs every
# invocation to $GH_LOG so a test can assert a call never happened. `git` is the real
# `/usr/bin/git` against a throwaway local repo (no network) for the pushed-branch check.
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    LIB_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/lib"
    LIB="$LIB_DIR/kanban_reconcile_done.sh"
    KANBAN_LIB="$LIB_DIR/kanban_reconcile.sh"
    TEST_TMP="$(mktemp -d)"
    FAKE_BIN="$TEST_TMP/bin"
    mkdir -p "$FAKE_BIN"
    PATH="$FAKE_BIN:$PATH"
    export GH_LOG="$TEST_TMP/gh.log"
    : > "$GH_LOG"
    export CLAUDE_CONFIG_DIR="$TEST_TMP/claude-home"

    # A throwaway repo for the pushed-branch check — no network, no gh call. `origin` points at
    # itself (a local path git happily treats as a remote) so `git ls-remote --heads origin`,
    # the exact command the lib runs, has something real to answer from.
    REPO_DIR="$TEST_TMP/repo"
    mkdir -p "$REPO_DIR"
    git init -q "$REPO_DIR"
    git -C "$REPO_DIR" config user.email t@t.example
    git -C "$REPO_DIR" config user.name t
    git -C "$REPO_DIR" commit -q --allow-empty -m init
    git -C "$REPO_DIR" remote add origin "$REPO_DIR"

    # Board: Ready < In progress < In review < Blocked < Done.
    cat > "$TEST_TMP/fields.json" <<'JSON'
{"fields":[{"name":"Status","id":"FIELD_1","options":[
    {"name":"Ready","id":"OPT_READY"},
    {"name":"In progress","id":"OPT_PROGRESS"},
    {"name":"In review","id":"OPT_REVIEW"},
    {"name":"Blocked","id":"OPT_BLOCKED"},
    {"name":"Done","id":"OPT_DONE"}
]}]}
JSON
}

teardown() {
    rm -rf "$TEST_TMP"
}

# item ID STATUS NUMBER [REPO_NAME_WITH_OWNER]
item() {
    jq -nc --arg id "$1" --arg status "$2" --argjson number "$3" --arg repo "${4:-owner/repo}" \
        '{id: $id, status: $status, content: {type: "Issue", number: $number, repository: $repo}}'
}

write_items() {
    printf '%s\n' "$@" | jq -sc '{items: .}' > "$TEST_TMP/items.json"
}

# issue NUMBER STATE [LABEL...]
issue() {
    local number="$1" state="$2"
    shift 2
    jq -nc --argjson number "$number" --arg state "$state" \
        --argjson labels "$(printf '%s\n' "$@" | jq -R . | jq -sc 'map(select(length > 0))')" \
        '{number: $number, state: $state, labels: ($labels | map({name: .}))}'
}

write_issues() {
    printf '%s\n' "$@" | jq -sc '.' > "$TEST_TMP/issues.json"
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
    "project item-list")
        [ -f "$TEST_TMP/fail-item-list" ] && exit 1
        cat "$TEST_TMP/items.json"
        ;;
    "project item-edit")
        [ -f "$TEST_TMP/fail-item-edit" ] && exit 1
        echo ok
        ;;
    *)
        case "\$1" in
            api)
                case "\$2" in
                    repos/*/issues\?*)
                        [ -f "$TEST_TMP/fail-issues" ] && exit 1
                        # Honour the state= filter like the real endpoint: a state=open read
                        # must not return closed issues, or the board-scoped read goes untested.
                        case "\$2" in
                            *state=open*) jq -c 'map(select(.state == "open"))' "$TEST_TMP/issues.json" ;;
                            *) cat "$TEST_TMP/issues.json" 2>/dev/null ;;
                        esac
                        ;;
                    repos/*/issues/[0-9]*)
                        [ -f "$TEST_TMP/fail-confirm" ] && exit 1
                        n="\${2##*/}"
                        # A missing issue is a 404 — non-zero exit, like the real endpoint.
                        jq -ce --argjson n "\$n" 'map(select(.number == \$n)) | first // empty' \\
                            "$TEST_TMP/issues.json" | grep . || exit 1
                        ;;
                    *) exit 1 ;;
                esac
                ;;
            *) exit 1 ;;
        esac
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
    run bash -c "source '$KANBAN_LIB'; source '$LIB_DIR/dispatch_claims.sh'; source '$LIB'; \
        reconcile_kanban_done owner repo '$REPO_DIR'; \
        echo \"rc=\$?\"; echo \"STATUS=\$RECONCILE_DONE_STATUS\"; \
        echo \"REPORT_START\"; printf '%s\n' \"\$RECONCILE_DONE_REPORT\"; echo \"REPORT_END\""
}

# --- closed -> Done -------------------------------------------------------------------------

@test "a closed issue in Backlog-equivalent status is moved to Done" {
    write_issues "$(issue 42 closed)"
    write_items "$(item ITEM_42 "In review" 42)"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"rc=0"* ]]
    [[ "$output" == *"STATUS=ok"* ]]
    [[ "$output" == *"moved issue #42 to Done (was: In review)"* ]]
    grep -q -- '--id ITEM_42 --field-id FIELD_1 --single-select-option-id OPT_DONE' "$GH_LOG"
}

@test "a closed issue with no Status at all is moved to Done" {
    write_issues "$(issue 42 closed)"
    write_items "$(item ITEM_42 "" 42)"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"moved issue #42 to Done (was: none)"* ]]
}

# --- never backwards -------------------------------------------------------------------------

@test "a closed issue already in Done is a no-op" {
    write_issues "$(issue 42 closed)"
    write_items "$(item ITEM_42 Done 42)"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"STATUS=ok"* ]]
    [[ "$output" != *"moved issue"* ]]
    refute_gh 'item-edit'
}

@test "an open issue that already has a Status is left alone" {
    write_issues "$(issue 42 open)"
    write_items "$(item ITEM_42 "In review" 42)"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"STATUS=ok"* ]]
    [[ "$output" != *"moved issue"* ]]
    refute_gh 'item-edit'
}

# --- No-Status derivation ---------------------------------------------------------------------

@test "a No-Status open issue labeled state:blocked is moved to Blocked" {
    write_issues "$(issue 42 open state:blocked)"
    write_items "$(item ITEM_42 "" 42)"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"moved issue #42 from No Status to Blocked"* ]]
    grep -q -- '--single-select-option-id OPT_BLOCKED' "$GH_LOG"
}

@test "a No-Status open issue with a pushed branch is moved to In progress" {
    git -C "$REPO_DIR" branch fix/42-board-thing
    write_issues "$(issue 42 open)"
    write_items "$(item ITEM_42 "" 42)"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"moved issue #42 from No Status to In progress"* ]]
    grep -q -- '--single-select-option-id OPT_PROGRESS' "$GH_LOG"
}

@test "a No-Status open issue with a live dispatch claim is moved to In progress, not Ready" {
    # The claim lives in REPO_DIR's git common dir, never the test's own $PWD — the lookup must
    # follow the CWD argument, and the caller (subagent_stop_sweep.sh) must have sourced the lib.
    (cd "$REPO_DIR" && source "$LIB_DIR/dispatch_claims.sh" && printf '' > "$(dispatch_state_dir)/pr-held-paths.tsv" &&
        [ "$(claim_files 42 some/path.sh)" = "CLAIMED" ])
    write_issues "$(issue 42 open)"
    write_items "$(item ITEM_42 "" 42)"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"moved issue #42 from No Status to In progress"* ]]
    grep -q -- '--single-select-option-id OPT_PROGRESS' "$GH_LOG"
}

@test "branch number matching is delimited, not a substring" {
    git -C "$REPO_DIR" branch fix/1442-unrelated
    write_issues "$(issue 42 open)"
    write_items "$(item ITEM_42 "" 42)"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"moved issue #42 from No Status to Ready"* ]]
}

@test "a No-Status open issue with none of the signals is moved to Ready" {
    write_issues "$(issue 42 open)"
    write_items "$(item ITEM_42 "" 42)"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"moved issue #42 from No Status to Ready"* ]]
    grep -q -- '--single-select-option-id OPT_READY' "$GH_LOG"
}

# --- read failure -> UNKNOWN, nothing moved ---------------------------------------------------

@test "gh failure reading project items: UNKNOWN, nothing moved" {
    touch "$TEST_TMP/fail-item-list"
    write_issues "$(issue 42 closed)"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"rc=1"* ]]
    [[ "$output" == *"STATUS=unknown"* ]]
    refute_gh 'item-edit'
}

@test "gh failure reading the issue list: UNKNOWN, nothing moved" {
    touch "$TEST_TMP/fail-issues"
    write_items "$(item ITEM_42 "In review" 42)"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"rc=1"* ]]
    [[ "$output" == *"STATUS=unknown"* ]]
    refute_gh 'item-edit'
}

@test "board field-list failure: UNKNOWN, nothing moved" {
    touch "$TEST_TMP/fail-field-list"
    write_issues "$(issue 42 closed)"
    write_items "$(item ITEM_42 "In review" 42)"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"rc=1"* ]]
    [[ "$output" == *"STATUS=unknown"* ]]
    refute_gh 'item-edit'
}

# --- per-card fail-closed: one bad card doesn't abort the round -------------------------------

@test "an issue that cannot be confirmed is reported UNKNOWN and the round continues" {
    write_issues "$(issue 43 closed)"
    write_items "$(item ITEM_42 "In review" 42)" "$(item ITEM_43 "In review" 43)"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"STATUS=ok"* ]]
    [[ "$output" == *"UNKNOWN issue #42: could not confirm its state"* ]]
    [[ "$output" == *"moved issue #43 to Done"* ]]
}

# --- board-scoped read (CodeRabbit, PR #589): cost follows the board, not the repo's history ----

@test "the listing is never read with state=all" {
    write_issues "$(issue 42 closed)" "$(issue 43 open)"
    write_items "$(item ITEM_42 "In review" 42)" "$(item ITEM_43 "In review" 43)"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"STATUS=ok"* ]]
    refute_gh 'state=all'
    grep -q -- 'state=open' "$GH_LOG"
}

@test "a card absent from the open listing is confirmed per card and moved when closed" {
    write_issues "$(issue 42 closed)"
    write_items "$(item ITEM_42 "In review" 42)"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"moved issue #42 to Done (was: In review)"* ]]
    grep -q -- 'repos/owner/repo/issues/42' "$GH_LOG"
}

@test "a card already in Done costs no confirmation read" {
    write_issues "$(issue 42 closed)"
    write_items "$(item ITEM_42 Done 42)"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"STATUS=ok"* ]]
    refute_gh 'repos/owner/repo/issues/42'
}

@test "an open card is answered by the listing, no confirmation read" {
    write_issues "$(issue 42 open)"
    write_items "$(item ITEM_42 "" 42)"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"moved issue #42 from No Status to Ready"* ]]
    refute_gh 'repos/owner/repo/issues/42'
}

@test "a failed confirmation read is UNKNOWN for that card, never closed, nothing moved" {
    touch "$TEST_TMP/fail-confirm"
    write_issues "$(issue 42 closed)"
    write_items "$(item ITEM_42 "In review" 42)"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"STATUS=ok"* ]]
    [[ "$output" == *"UNKNOWN issue #42: could not confirm its state"* ]]
    [[ "$output" != *"moved issue"* ]]
    refute_gh 'item-edit'
}

# --- item-list cap: truncated read is unknown, never a partial ok -----------------------------

@test "project item list hitting its cap: STATUS=unknown, nothing touched" {
    write_issues "$(issue 1 closed)"
    local many=() i
    for (( i = 1; i <= 500; i++ )); do many+=("$(item "ITEM_$i" "In review" "$i")"); done
    write_items "${many[@]}"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"rc=1"* ]]
    [[ "$output" == *"STATUS=unknown"* ]]
    refute_gh 'item-edit'
}

# --- cross-repository card is not this repo's to judge -----------------------------------------

@test "a card from another repo on the board is left alone" {
    write_issues "$(issue 42 closed)"
    write_items "$(item ITEM_OTHER "In review" 42 other/repo)"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"STATUS=ok"* ]]
    [[ "$output" != *"moved issue"* ]]
    refute_gh 'item-edit'
}
