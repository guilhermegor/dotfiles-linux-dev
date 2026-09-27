#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/roadmap_unblock.sh (dotfiles-dev#369)
#
# Strategy (same shape as kanban_lifecycle.bats): a fake `gh` script is placed first on PATH so
# these tests never touch the network or a real project board. It logs every invocation to
# $GH_LOG (for asserting which mutations did or did not happen) and answers `project item-list`
# from a fixture file, and `api .../dependencies/blocked_by` from a per-test map keyed by issue
# number (FAKE_BLOCKERS_<n>), so one item-list fixture can carry several Blocked items at once.
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    LIB="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/lib/roadmap_unblock.sh"
    TEST_TMP="$(mktemp -d)"
    FAKE_BIN="$TEST_TMP/bin"
    mkdir -p "$FAKE_BIN"
    PATH="$FAKE_BIN:$PATH"
    export GH_LOG="$TEST_TMP/gh.log"
    : > "$GH_LOG"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# item OWNER/REPO NUMBER STATUS BLOCKED_BY_TEXT BODY
# Emits one project-item JSON object. BLOCKED_BY_TEXT may be "" (field absent, matching the real
# API which only emits the "blocked by" key when the field is non-empty).
item() {
    local repo="$1" number="$2" status="$3" blocked_by="$4" body="$5"
    jq -nc --arg repo "$repo" --argjson number "$number" --arg status "$status" \
        --arg blocked_by "$blocked_by" --arg body "$body" '
        {status: $status, content: {type: "Issue", number: $number, repository: $repo,
         url: ("https://github.com/" + $repo + "/issues/" + ($number|tostring)), body: $body}}
        | if $blocked_by == "" then . else . + {"blocked by": $blocked_by} end
    '
}

# write_items ITEM_JSON...
# Writes {"items":[...]} to the fixture file the fake gh's `project item-list` reads.
write_items() {
    printf '%s\n' "$@" | jq -sc '{items: .}' > "$TEST_TMP/items.json"
}

# blocker NUMBER STATE REPO
blocker() {
    jq -nc --argjson number "$1" --arg state "$2" --arg repo "$3" \
        '{number: $number, state: $state, repository: {full_name: $repo}}'
}

# write_blockers ISSUE_NUMBER BLOCKER_JSON...
# Registers the dependencies/blocked_by fixture for one issue number, or a bare "FAIL" sentinel
# file to make that read fail (simulating an API error).
write_blockers() {
    local number="$1"; shift
    if [ "$1" = "FAIL" ]; then
        echo FAIL > "$TEST_TMP/blockers-$number.json"
    else
        printf '%s\n' "$@" | jq -sc '.' > "$TEST_TMP/blockers-$number.json"
    fi
}

# write_blocker_pages ISSUE_NUMBER PAGE_JSON...
# Registers a MULTI-PAGE dependencies/blocked_by fixture: one JSON array per line, which is exactly
# what `gh api --paginate` emits (concatenated arrays, not a merged one). Each PAGE_JSON is a
# newline-separated group of `blocker` objects.
write_blocker_pages() {
    local number="$1"; shift
    local page
    : > "$TEST_TMP/blockers-$number.json"
    for page in "$@"; do
        printf '%s\n' "$page" | jq -sc '.' >> "$TEST_TMP/blockers-$number.json"
    done
}

# write_existing_comments ISSUE_NUMBER BODY...
# Registers what `gh issue view --json comments` returns for one issue. Absent = no comments.
write_existing_comments() {
    local number="$1"; shift
    printf '%s\n' "$@" | jq -R . | jq -sc '{comments: [.[] | {body: .}]}' \
        > "$TEST_TMP/comments-$number.json"
}

# write_ref_state REPO NUMBER STATE
# Registers what `gh issue view NUMBER --repo REPO --json state --jq .state` returns for one
# prose-referenced issue (dotfiles-dev#416) — STATE is the real API's own casing ("OPEN"/"CLOSED").
# A bare "FAIL" sentinel leaves no fixture file, so the fake gh's `[ -f "$f" ]` check exits 1 —
# the fail-closed path for prose-blocker resolution.
write_ref_state() {
    local repo="$1" number="$2" state="$3" key
    key="${repo//\//_}-$number"
    [ "$state" = "FAIL" ] || printf '%s' "$state" > "$TEST_TMP/refstate-$key.json"
}

write_fake_gh() {
    cat > "$FAKE_BIN/gh" <<EOF
#!/bin/bash
echo "\$*" >> "$GH_LOG"
case "\$1 \$2" in
    "project item-list")
        cat "$TEST_TMP/items.json"
        ;;
    "api "*)
        path="\$2"
        n="\${path##*/issues/}"
        n="\${n%%/dependencies*}"
        f="$TEST_TMP/blockers-\$n.json"
        [ -f "\$f" ] || { echo '[]'; exit 0; }
        if [ "\$(cat "\$f")" = "FAIL" ]; then
            exit 1
        fi
        cat "\$f"
        ;;
    "issue edit")
        [ -f "$TEST_TMP/fail-issue-edit" ] && exit 1
        echo ok
        ;;
    "issue view")
        # Keyed on the --json PROJECTION (state vs comments), never the full query string —
        # a stub keyed on the whole command silently breaks the moment a flag is added
        # elsewhere (dotfiles-dev#409).
        if printf '%s' "\$*" | grep -q -- '--json state'; then
            repo="\$5"
            key="\${repo//\//_}-\$3"
            f="$TEST_TMP/refstate-\$key.json"
            [ -f "\$f" ] || exit 1
            cat "\$f"
        else
            f="$TEST_TMP/comments-\$3.json"
            [ -f "\$f" ] || exit 0
            jq -r '.comments[].body' "\$f"
        fi
        ;;
    "project item-edit")
        [ -f "$TEST_TMP/fail-item-edit" ] && exit 1
        echo ok
        ;;
    "issue comment")
        [ -f "$TEST_TMP/fail-comment" ] && exit 1
        echo ok
        ;;
    *)
        exit 1
        ;;
esac
EOF
    chmod +x "$FAKE_BIN/gh"
}

# refute_gh PATTERN
# Asserts PATTERN never appears in the gh invocation log. NOT `! grep -q …`: bash exempts a
# `!`-inverted command from `set -e`, so such a line silently passes unless it happens to be the
# test's very last statement — six assertions here could never have failed (PR #376 review).
refute_gh() {
    run grep -q -- "$1" "$GH_LOG"
    [ "$status" -ne 0 ]
}

run_reconcile() {
    run bash -c "source '$LIB'; reconcile_roadmap_unblock owner 17; \
        echo \"STATUS=\$RECONCILE_STATUS\"; echo \"REPORT_START\"; \
        printf '%s\n' \"\$RECONCILE_REPORT\"; echo \"REPORT_END\""
}

# --- one closed blocker: unblocked + commented ---------------------------------------------------

@test "one closed native blocker: item is unblocked, labeled, and commented" {
    write_items "$(item "owner/repo" 3 "Blocked" "" "**Blocked by:** owner/repo#2")"
    write_blockers 3 "$(blocker 2 closed "owner/repo")"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"STATUS=ok"* ]]
    [[ "$output" == *"unblocked owner/repo#3"* ]]
    [[ "$output" == *"owner/repo#2"* ]]
    grep -q 'issue edit 3 --repo owner/repo --add-label state:ready --remove-label state:blocked' "$GH_LOG"
    grep -q 'project item-edit 17 --owner owner --url .*--field Status --value Ready' "$GH_LOG"
    grep -q 'project item-edit 17 --owner owner --url .*--field Blocked by --clear' "$GH_LOG"
    grep -q 'issue comment 3 --repo owner/repo' "$GH_LOG"
}

# --- one open of two: untouched ------------------------------------------------------------------

@test "one open blocker of two: left blocked, no mutation" {
    write_items "$(item "owner/repo" 4 "Blocked" "" "**Blocked by:** owner/repo#2, owner/repo#5")"
    write_blockers 4 "$(blocker 2 closed "owner/repo")" "$(blocker 5 open "owner/repo")"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"STATUS=ok"* ]]
    [[ "$output" == *"still blocked owner/repo#4"* ]]
    [[ "$output" == *"owner/repo#5"* ]]
    refute_gh 'issue edit'
    refute_gh 'item-edit'
    refute_gh 'issue comment'
}

# --- a cross-repo blocker, all closed: still unblocks -------------------------------------------

@test "cross-repo native blocker, closed: unblocked" {
    write_items "$(item "owner/greenfield" 12 "Blocked" "" "**Blocked by:** owner/blueprintx#482")"
    write_blockers 12 "$(blocker 482 closed "owner/blueprintx")"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"unblocked owner/greenfield#12"* ]]
    [[ "$output" == *"owner/blueprintx#482"* ]]
}

# --- prose blocker resolution (dotfiles-dev#416): native empty, blocker recorded only in prose ---
# Repro shape measured on dotfiles-dev#405: `gh api .../dependencies/blocked_by` returns [] (no
# native relation) while the body's own "**Blocked by:**" line names an issue — before this fix
# the item read "still blocked" forever, blind to whether that named issue ever closed.

@test "prose blocker referencing an open issue, no native blocked_by: still blocked" {
    write_items "$(item "owner/repo" 405 "Blocked" "" "**Blocked by:** owner/blueprintx#314")"
    write_blockers 405
    write_ref_state "owner/blueprintx" 314 "OPEN"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"STATUS=ok"* ]]
    [[ "$output" == *"still blocked owner/repo#405"* ]]
    [[ "$output" == *"owner/blueprintx#314"* ]]
    refute_gh 'issue edit'
    refute_gh 'item-edit'
    refute_gh 'issue comment'
}

@test "prose blocker referencing a closed issue, no native blocked_by: unblocked" {
    write_items "$(item "owner/repo" 405 "Blocked" "" "**Blocked by:** owner/blueprintx#314")"
    write_blockers 405
    write_ref_state "owner/blueprintx" 314 "CLOSED"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"STATUS=ok"* ]]
    [[ "$output" == *"unblocked owner/repo#405"* ]]
    [[ "$output" == *"owner/blueprintx#314"* ]]
    grep -q 'issue edit 405 --repo owner/repo --add-label state:ready --remove-label state:blocked' "$GH_LOG"
    grep -q 'project item-edit 17 --owner owner --url .*--field Status --value Ready' "$GH_LOG"
}

@test "a decision: prose blocker naming a closed issue is still never auto-cleared" {
    write_items "$(item "owner/repo" 405 "Blocked" "" \
        "**Blocked by:** decision: pick a vendor, see owner/blueprintx#314")"
    write_blockers 405
    write_ref_state "owner/blueprintx" 314 "CLOSED"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"decision blocker owner/repo#405"* ]]
    refute_gh 'issue edit'
    refute_gh 'item-edit'
    refute_gh 'issue comment'
}

@test "prose blocker ref state read failure: reported UNKNOWN, left untouched (fail closed)" {
    write_items "$(item "owner/repo" 405 "Blocked" "" "**Blocked by:** owner/blueprintx#314")"
    write_blockers 405
    write_ref_state "owner/blueprintx" 314 "FAIL"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"STATUS=ok"* ]]
    [[ "$output" == *"UNKNOWN owner/repo#405"* ]]
    refute_gh 'issue edit'
    refute_gh 'item-edit'
    refute_gh 'issue comment'
}

# --- decision blocker: never auto-cleared, even alone with no native blocker ---------------------

@test "decision: blocker present (in the Blocked-by field): left untouched" {
    write_items "$(item "owner/repo" 7 "Blocked" "decision: find and read the terms of use" "")"
    write_blockers 7
    write_fake_gh
    run_reconcile
    [[ "$output" == *"STATUS=ok"* ]]
    [[ "$output" == *"decision blocker owner/repo#7"* ]]
    [[ "$output" == *"decision: find and read the terms of use"* ]]
    refute_gh 'issue edit'
    refute_gh 'item-edit'
    refute_gh 'issue comment'
}

@test "decision: blocker present only in the body line: still left untouched" {
    write_items "$(item "owner/repo" 7 "Blocked" "" "**Blocked by:** decision: pick a vendor")"
    write_blockers 7
    write_fake_gh
    run_reconcile
    [[ "$output" == *"decision blocker owner/repo#7"* ]]
    refute_gh 'issue edit'
}

# --- blocked by nothing: reported, untouched ------------------------------------------------------

@test "blocked by nothing: Status=Blocked with no blocker recorded anywhere is reported, not moved" {
    write_items "$(item "owner/repo" 13 "Blocked" "" "no blocker line here")"
    write_blockers 13
    write_fake_gh
    run_reconcile
    [[ "$output" == *"STATUS=ok"* ]]
    [[ "$output" == *"blocked by nothing owner/repo#13"* ]]
    refute_gh 'issue edit'
    refute_gh 'item-edit'
}

# --- API failure: UNKNOWN, untouched --------------------------------------------------------------

@test "dependencies API failure: reported UNKNOWN, left untouched (fail closed)" {
    write_items "$(item "owner/repo" 16 "Blocked" "" "**Blocked by:** owner/repo#9")"
    write_blockers 16 FAIL
    write_fake_gh
    run_reconcile
    [[ "$output" == *"STATUS=ok"* ]]
    [[ "$output" == *"UNKNOWN owner/repo#16"* ]]
    refute_gh 'issue edit'
    refute_gh 'item-edit'
    refute_gh 'issue comment'
}

@test "the board itself unreadable: global UNKNOWN, non-zero return, nothing touched" {
    write_fake_gh
    rm -f "$TEST_TMP/items.json"   # item-list now fails: no such fixture file for `cat`
    run bash -c "source '$LIB'; reconcile_roadmap_unblock owner 17; echo \"rc=\$?\"; \
        echo \"STATUS=\$RECONCILE_STATUS\"; echo \"REPORT=\$RECONCILE_REPORT\""
    [[ "$output" == *"rc=1"* ]]
    [[ "$output" == *"STATUS=unknown"* ]]
    [[ "$output" == *"UNKNOWN"* ]]
    refute_gh 'issue edit'
}

# --- idempotent: re-running after an unblock changes nothing -------------------------------------

@test "idempotent: an already-Ready item (no longer Blocked) triggers no mutation on re-run" {
    # Round 1: unblock it.
    write_items "$(item "owner/repo" 3 "Blocked" "" "**Blocked by:** owner/repo#2")"
    write_blockers 3 "$(blocker 2 closed "owner/repo")"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"unblocked owner/repo#3"* ]]

    # Round 2: the board now reflects Ready (as the real board would after round 1's writes) —
    # the item no longer matches the Status=="Blocked" filter, so nothing fires again.
    : > "$GH_LOG"
    write_items "$(item "owner/repo" 3 "Ready" "" "")"
    run_reconcile
    [[ "$output" == *"STATUS=ok"* ]]
    [[ "$output" != *"owner/repo#3"* ]]
    refute_gh 'issue edit'
    refute_gh 'item-edit'
    refute_gh 'issue comment'
}

# --- a partial write failure is surfaced, never silently swallowed -------------------------------

@test "a gh write failing partway is reported as FAILED, not silently as unblocked" {
    write_items "$(item "owner/repo" 3 "Blocked" "" "**Blocked by:** owner/repo#2")"
    write_blockers 3 "$(blocker 2 closed "owner/repo")"
    write_fake_gh
    touch "$TEST_TMP/fail-item-edit"
    run_reconcile
    [[ "$output" == *"FAILED to unblock owner/repo#3"* ]]
    [[ "$output" != *"unblocked owner/repo#3"* ]]
}

# --- PR #376 review: a blocker on a later page must still count ----------------------------------

@test "an open blocker on the second page keeps the item blocked" {
    write_items "$(item "owner/repo" 3 "Blocked" "" "**Blocked by:** owner/repo#2")"
    write_blocker_pages 3 "$(blocker 2 closed "owner/repo")" "$(blocker 5 open "owner/repo")"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"still blocked owner/repo#3"* ]]
    [[ "$output" == *"owner/repo#5"* ]]
    refute_gh 'item-edit'
}

@test "closed blockers spread over two pages still unblock" {
    write_items "$(item "owner/repo" 3 "Blocked" "" "**Blocked by:** owner/repo#2")"
    write_blocker_pages 3 "$(blocker 2 closed "owner/repo")" "$(blocker 5 closed "owner/repo")"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"unblocked owner/repo#3"* ]]
    [[ "$output" == *"owner/repo#5"* ]]
}

@test "the blocked_by read is paginated, not left at the default page size" {
    write_items "$(item "owner/repo" 3 "Blocked" "" "**Blocked by:** owner/repo#2")"
    write_blockers 3 "$(blocker 2 closed "owner/repo")"
    write_fake_gh
    run_reconcile
    grep -q 'api repos/owner/repo/issues/3/dependencies/blocked_by?per_page=100 --paginate' "$GH_LOG"
}

# --- PR #376 review: Status is the completion marker, so it is written last ----------------------

@test "Status is the last write, after the field clear and the audit comment" {
    write_items "$(item "owner/repo" 3 "Blocked" "" "**Blocked by:** owner/repo#2")"
    write_blockers 3 "$(blocker 2 closed "owner/repo")"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"unblocked owner/repo#3"* ]]
    # Line numbers in the invocation log, so "after" is asserted rather than assumed.
    local status_line clear_line comment_line
    status_line="$(grep -n -- '--field Status --value Ready' "$GH_LOG" | cut -d: -f1)"
    clear_line="$(grep -n -- '--field Blocked by --clear' "$GH_LOG" | cut -d: -f1)"
    comment_line="$(grep -n '^issue comment 3 ' "$GH_LOG" | cut -d: -f1)"
    ((clear_line < status_line))
    ((comment_line < status_line))
}

@test "a failed field clear leaves Status Blocked so the next round retries" {
    write_items "$(item "owner/repo" 3 "Blocked" "" "**Blocked by:** owner/repo#2")"
    write_blockers 3 "$(blocker 2 closed "owner/repo")"
    write_fake_gh
    touch "$TEST_TMP/fail-item-edit"
    run_reconcile
    [[ "$output" == *"FAILED to unblock owner/repo#3"* ]]
    refute_gh '--field Status --value Ready'
}

@test "the audit comment is not posted twice when it is already on the issue" {
    write_items "$(item "owner/repo" 3 "Blocked" "" "**Blocked by:** owner/repo#2")"
    write_blockers 3 "$(blocker 2 closed "owner/repo")"
    write_existing_comments 3 "Unblocked: owner/repo#2. Status set to Ready."
    write_fake_gh
    run_reconcile
    [[ "$output" == *"unblocked owner/repo#3"* ]]
    refute_gh '^issue comment 3 '
    grep -q -- '--field Status --value Ready' "$GH_LOG"
}

# --- PR #376 review: a wrong-shaped board response is UNKNOWN, never a silent no-op --------------

@test "a board response with no items array is UNKNOWN, not an empty ok round" {
    echo '{}' > "$TEST_TMP/items.json"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"STATUS=unknown"* ]]
    [[ "$output" == *"could not parse project owner/17"* ]]
}

@test "a board response with a null items field is UNKNOWN" {
    echo '{"items": null}' > "$TEST_TMP/items.json"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"STATUS=unknown"* ]]
    [[ "$output" == *"could not parse project owner/17"* ]]
}

# --- blocker-kind reporting (dotfiles-dev#528) ----------------------------------------------------

@test "same-repo native blocker: reported internal" {
    write_items "$(item "owner/repo" 3 "Blocked" "" "**Blocked by:** owner/repo#2")"
    write_blockers 3 "$(blocker 2 closed "owner/repo")"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"unblocked owner/repo#3"* ]]
    [[ "$output" == *"[blocker-kind: internal]"* ]]
    [[ "$output" != *"[blocker-kind: external]"* ]]
}

@test "cross-repo native blocker: reported external, still unblocks" {
    write_items "$(item "owner/greenfield" 12 "Blocked" "" "**Blocked by:** owner/blueprintx#482")"
    write_blockers 12 "$(blocker 482 closed "owner/blueprintx")"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"unblocked owner/greenfield#12"* ]]
    [[ "$output" == *"[blocker-kind: external]"* ]]
}

@test "cross-repo prose blocker, still open: reported external and still blocked" {
    write_items "$(item "owner/repo" 405 "Blocked" "" "**Blocked by:** owner/blueprintx#314")"
    write_blockers 405
    write_ref_state "owner/blueprintx" 314 "OPEN"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"still blocked owner/repo#405"* ]]
    [[ "$output" == *"[blocker-kind: external]"* ]]
}

@test "same-repo prose blocker, still open: reported internal" {
    write_items "$(item "owner/repo" 405 "Blocked" "" "**Blocked by:** owner/repo#9")"
    write_blockers 405
    write_ref_state "owner/repo" 9 "OPEN"
    write_fake_gh
    run_reconcile
    [[ "$output" == *"still blocked owner/repo#405"* ]]
    [[ "$output" == *"[blocker-kind: internal]"* ]]
}

@test "decision blocker: reported with the decision kind tag" {
    write_items "$(item "owner/repo" 7 "Blocked" "decision: find and read the terms of use" "")"
    write_blockers 7
    write_fake_gh
    run_reconcile
    [[ "$output" == *"decision blocker owner/repo#7"* ]]
    [[ "$output" == *"[blocker-kind: decision]"* ]]
}

@test "blocked by nothing: no blocker-kind tag, since there is nothing to classify" {
    write_items "$(item "owner/repo" 13 "Blocked" "" "no blocker line here")"
    write_blockers 13
    write_fake_gh
    run_reconcile
    [[ "$output" == *"blocked by nothing owner/repo#13"* ]]
    [[ "$output" != *"blocker-kind"* ]]
}
