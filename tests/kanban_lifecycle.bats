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

# --- #594 round 3: escaped quotes tokenize; a --head with no value never falls back to HEAD -----

@test "gh pr create with escaped quotes in --title still honours --head" {
    write_fake_gh_two_cards
    run run_hook 'gh pr create --title "say \"hi\"" --head fix/564-other'
    [ "$status" -eq 0 ]
    [[ "$output" == *"issue #564"* ]]
}

@test "gh pr create ending in a bare --head moves nothing (no fallback to HEAD)" {
    write_fake_gh_two_cards
    run run_hook "gh pr create --title x --head"
    [ "$status" -eq 0 ]
    [[ "$output" != *"moved issue"* ]]
}

@test "gh pr create --head= with an empty value moves nothing (no fallback to HEAD)" {
    write_fake_gh_two_cards
    run run_hook "gh pr create --head= --title x"
    [ "$status" -eq 0 ]
    [[ "$output" != *"moved issue"* ]]
}

@test "gh pr create ending in a bare -H moves nothing (no fallback to HEAD)" {
    write_fake_gh_two_cards
    run run_hook "gh pr create --title x -H"
    [ "$status" -eq 0 ]
    [[ "$output" != *"moved issue"* ]]
}

# --- #594 round 4: the matcher sees raw text, never Bash's expansion of it -----------------------
# `--head "${BRANCH:-fix/564}"` may expand to ANY branch, so the `564` inside is not the card.

@test "gh pr create --head with a \${VAR:-default} expansion moves nothing" {
    write_fake_gh_two_cards
    run run_hook 'gh pr create --head "${BRANCH:-fix/564}" --title x'
    [ "$status" -eq 0 ]
    [[ "$output" != *"moved issue"* ]]
}

@test "gh pr create --head with a bare \$VAR moves nothing" {
    write_fake_gh_two_cards
    run run_hook 'gh pr create --head fix/564-$SUFFIX --title x'
    [ "$status" -eq 0 ]
    [[ "$output" != *"moved issue"* ]]
}

@test "gh pr create --head with a command substitution moves nothing" {
    write_fake_gh_two_cards
    run run_hook 'gh pr create --head "$(echo fix/564-x)" --title x'
    [ "$status" -eq 0 ]
    [[ "$output" != *"moved issue"* ]]
}

@test "gh pr create --head with a backtick substitution moves nothing" {
    write_fake_gh_two_cards
    run run_hook 'gh pr create --head "`echo fix/564-x`" --title x'
    [ "$status" -eq 0 ]
    [[ "$output" != *"moved issue"* ]]
}

@test "gh pr create --head with a brace expansion moves nothing" {
    write_fake_gh_two_cards
    run run_hook 'gh pr create --head fix/{564,131}-x --title x'
    [ "$status" -eq 0 ]
    [[ "$output" != *"moved issue"* ]]
}

@test "gh pr create --head -H <b> takes -H as the head value and moves nothing" {
    # pflag consumes the next argv as the value even when it looks like a flag
    write_fake_gh_two_cards
    run run_hook 'gh pr create --head -H fix/564-other --title x'
    [ "$status" -eq 0 ]
    [[ "$output" != *"moved issue"* ]]
}

# --- #859: a REST-opened PR (`gh api repos/<o>/<r>/pulls ... head=<b>`) is a PR-open event ------
# The REST fallback is what /issue and s:dev-loop tell agents to use when GraphQL is rate-limited,
# and it never matched the literal `gh pr create` verb, so the card stayed in Ready.

# Wrap the fake gh so every call is logged to $TEST_TMP/gh.log (owner/repo must come from the URL).
log_gh_calls() {
    mv "$FAKE_BIN/gh" "$FAKE_BIN/gh.real"
    cat > "$FAKE_BIN/gh" <<EOF2
#!/bin/bash
echo "\$*" >> "$TEST_TMP/gh.log"
exec "$FAKE_BIN/gh.real" "\$@"
EOF2
    chmod +x "$FAKE_BIN/gh"
}

# The board is looked up by the URL's repo ("widgets kanban"), not cwd's ("dotfiles-dev kanban").
write_fake_gh_widgets_board() {
    write_fake_gh_two_cards
    sed -i 's|dotfiles-dev kanban|widgets kanban|' "$FAKE_BIN/gh"
}

assert_rest_pr_moves_card() {
    write_fake_gh_widgets_board
    run run_hook "$1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"issue #564"* ]]
    [[ "$output" == *"In review"* ]]
}

assert_rest_call_moves_nothing() {
    write_fake_gh_widgets_board
    run run_hook "$1"
    [ "$status" -eq 0 ]
    [[ "$output" != *"moved issue"* ]]
}

@test "gh api pulls -f head=<b> (implicit POST) moves the card of <b>" {
    assert_rest_pr_moves_card "gh api repos/acme/widgets/pulls -f title=x -f head=fix/564-other -f base=main"
}

@test "gh api pulls -F head=<b> moves the card" {
    assert_rest_pr_moves_card "gh api repos/acme/widgets/pulls -F head=fix/564-other"
}

@test "gh api pulls --field head=<b> moves the card" {
    assert_rest_pr_moves_card "gh api repos/acme/widgets/pulls --field head=fix/564-other"
}

@test "gh api pulls --raw-field head=<b> moves the card" {
    assert_rest_pr_moves_card "gh api repos/acme/widgets/pulls --raw-field head=fix/564-other"
}

@test "gh api pulls --field=head=<b> (attached) moves the card" {
    assert_rest_pr_moves_card "gh api repos/acme/widgets/pulls --field=head=fix/564-other"
}

@test "gh api pulls -fhead=<b> (attached short flag) moves the card" {
    assert_rest_pr_moves_card "gh api repos/acme/widgets/pulls -fhead=fix/564-other"
}

@test "gh api pulls -X POST -f head=<b> moves the card" {
    assert_rest_pr_moves_card "gh api -X POST repos/acme/widgets/pulls -f head=fix/564-other"
}

@test "gh api pulls --method POST -f head=<b> moves the card" {
    assert_rest_pr_moves_card "gh api repos/acme/widgets/pulls --method POST -f head=fix/564-other"
}

@test "rtk gh api pulls -f head=<b> moves the card" {
    assert_rest_pr_moves_card "rtk gh api repos/acme/widgets/pulls -f head=fix/564-other"
}

@test "gh api pulls with head=owner:<b> strips the owner prefix" {
    assert_rest_pr_moves_card "gh api repos/acme/widgets/pulls -f head=acme:fix/564-other"
}

@test "gh api pulls takes owner/repo from the URL, not from cwd" {
    write_fake_gh_widgets_board
    log_gh_calls
    run run_hook "gh api repos/acme/widgets/pulls -f head=fix/564-other"
    [ "$status" -eq 0 ]
    [[ "$output" == *"issue #564"* ]]
    grep -q -- "--repo acme/widgets" "$TEST_TMP/gh.log"
}

@test "gh api GET on pulls (no fields) moves nothing" {
    assert_rest_call_moves_nothing "gh api repos/acme/widgets/pulls"
}

@test "gh api -X GET on pulls with a head= field moves nothing" {
    assert_rest_call_moves_nothing "gh api -X GET repos/acme/widgets/pulls -f head=fix/564-other"
}

@test "gh api pulls POST without a head field moves nothing" {
    assert_rest_call_moves_nothing "gh api repos/acme/widgets/pulls -f title=x -f base=main"
}

@test "gh api pulls/<n>/reviews moves nothing" {
    assert_rest_call_moves_nothing "gh api repos/acme/widgets/pulls/5/reviews -f head=fix/564-other"
}

@test "gh api pulls/<n>/comments moves nothing" {
    assert_rest_call_moves_nothing "gh api repos/acme/widgets/pulls/5/comments -f body=x -f head=fix/564-other"
}

@test "gh api pulls/<n>/update-branch moves nothing" {
    assert_rest_call_moves_nothing "gh api -X PUT repos/acme/widgets/pulls/5/update-branch -f head=fix/564-other"
}

@test "gh api pulls/<n>/merge moves nothing" {
    assert_rest_call_moves_nothing "gh api -X PUT repos/acme/widgets/pulls/5/merge -f head=fix/564-other"
}

@test "echo of a gh api pulls call moves nothing" {
    assert_rest_call_moves_nothing "echo gh api repos/acme/widgets/pulls -f head=fix/564-other"
}

@test "gh api pulls with a shell-built head moves nothing" {
    assert_rest_call_moves_nothing 'gh api repos/acme/widgets/pulls -f head=$BRANCH'
}

# --- #859: a failed board read/write warns instead of exiting silently --------------------------

@test "board write failure warns with issue, board and target column" {
    write_fake_gh "OPEN"
    sed -i 's|echo .{"id":"ITEM_1"}.|exit 1|' "$FAKE_BIN/gh"
    run run_hook "gh pr create --title x --body y"
    [ "$status" -eq 0 ]
    [[ "$output" == *"additionalContext"* ]]
    [[ "$output" == *"#131"* ]]
    [[ "$output" == *"dotfiles-dev kanban"* ]]
    [[ "$output" == *"In review"* ]]
    [[ "$output" == *"NOT moved"* ]]
}

@test "board card read failure warns" {
    write_fake_gh "OPEN"
    sed -i '/"project item-list")/{n;s|.*|        exit 1|}' "$FAKE_BIN/gh"
    run run_hook "gh pr create --title x --body y"
    [ "$status" -eq 0 ]
    [[ "$output" == *"#131"* ]]
    [[ "$output" == *"NOT moved"* ]]
}

@test "board read failure (project list errors) warns" {
    write_fake_gh "OPEN"
    sed -i '/"project list")/{n;s|.*|        exit 1|}' "$FAKE_BIN/gh"
    run run_hook "gh pr create --title x --body y"
    [ "$status" -eq 0 ]
    [[ "$output" == *"read the board"* ]]
    [[ "$output" == *"In review"* ]]
}

@test "no matching board stays silent (not a failure)" {
    write_fake_gh "OPEN"
    sed -i 's|dotfiles-dev kanban|other kanban|' "$FAKE_BIN/gh"
    run run_hook "gh pr create --title x --body y"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- #861 review: parser edge cases that must not move a guessed card ---------------------------

@test "gh api pulls -F head=@<file> moves nothing" {
    assert_rest_call_moves_nothing "gh api repos/acme/widgets/pulls -F head=@564-x.txt"
}

@test "gh api pulls --input with -f head= moves nothing" {
    assert_rest_call_moves_nothing "gh api repos/acme/widgets/pulls --input body.json -f head=fix/564-other"
}

@test "checkout -b compounded with a REST PR call does not use the REST issue" {
    assert_rest_call_moves_nothing "git checkout -b feat/1-x ; gh api repos/acme/widgets/pulls -f head=fix/564-other"
}

@test "gh api pulls with an attached short value flag before the path still moves the card" {
    assert_rest_pr_moves_card "gh api -pshadow-cat repos/acme/widgets/pulls -f head=fix/564-other"
}

@test "gh api pulls head with leading zeros resolves to the plain issue number" {
    assert_rest_pr_moves_card "gh api repos/acme/widgets/pulls -f head=fix/0564-other"
}

# --- #865: a FAILED PR-open must not move the card ----------------------------------------------

# payload with a tool_response; $1 command, $2 tool_response JSON
run_hook_resp() {
    jq -nc --arg cmd "$1" --argjson r "$2" \
        '{tool_name: "Bash", tool_input: {command: $cmd}, tool_response: $r}' | "$HOOK"
}

@test "gh pr create with a PR URL in stdout still moves the card" {
    write_fake_gh "OPEN"
    run run_hook_resp "gh pr create --title x" '{"stdout":"https://github.com/o/r/pull/9\n","stderr":""}'
    [[ "$output" == *"moved issue"* ]]
}

@test "gh pr create that exited non-zero moves nothing" {
    write_fake_gh "OPEN"
    run run_hook_resp "gh pr create --title x" '{"stdout":"","stderr":"boom","exit_code":1}'
    [ "$status" -eq 0 ]
    [[ "$output" != *"moved issue"* ]]
}

@test "gh pr create with no PR URL in stdout moves nothing" {
    write_fake_gh "OPEN"
    run run_hook_resp "gh pr create --title x" '{"stdout":"a pull request already exists","stderr":""}'
    [[ "$output" != *"moved issue"* ]]
}

@test "gh pr create with redirected (empty) stdout still moves the card" {
    write_fake_gh "OPEN"
    run run_hook_resp "gh pr create --title x >/dev/null" '{"stdout":"","stderr":""}'
    [[ "$output" == *"moved issue"* ]]
}

@test "gh pr create with the PR URL only in stderr still moves the card" {
    write_fake_gh "OPEN"
    run run_hook_resp "gh pr create --title x" '{"stdout":"Creating pull request","stderr":"https://github.com/o/r/pull/9"}'
    [[ "$output" == *"moved issue"* ]]
}

@test "a string 'Error' tool_response moves nothing" {
    write_fake_gh "OPEN"
    run run_hook_resp "gh pr create --title x" '"Error: Exit code 1"'
    [[ "$output" != *"moved issue"* ]]
}

@test "REST POST pulls with an HTTP 422 in stderr moves nothing" {
    write_fake_gh "OPEN"
    run run_hook_resp "gh api repos/guilhermegor/dotfiles-dev/pulls -f head=feat/131-fix -f base=main" \
        '{"stdout":"{\"message\":\"Validation Failed\"}","stderr":"gh: Validation Failed (HTTP 422)"}'
    [[ "$output" != *"moved issue"* ]]
}

@test "REST POST pulls that succeeded still moves the card" {
    write_fake_gh "OPEN"
    run run_hook_resp "gh api repos/guilhermegor/dotfiles-dev/pulls -f head=feat/131-fix -f base=main" \
        '{"stdout":"{\"html_url\":\"https://github.com/o/r/pull/9\"}","stderr":""}'
    [[ "$output" == *"moved issue"* ]]
}

# --- #865: board_config tells "no board" (silent) from a gh error (warns), no second gh call ----

@test "no kanban board: silent, and gh project list is called exactly once" {
    write_fake_gh "OPEN"
    sed -i 's|"project list")|"project list") echo x >> "'"$TEST_TMP"'/list.calls"|; s|echo .{"projects".*|echo '"'"'{"projects":[]}'"'"'|' "$FAKE_BIN/gh"
    run run_hook "gh pr create --title x"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(wc -l < "$TEST_TMP/list.calls")" -eq 1 ]
}

@test "gh project list failure: warns that the board was not read" {
    write_fake_gh "OPEN"
    sed -i 's|echo .{"projects".*|exit 1|' "$FAKE_BIN/gh"
    run run_hook "gh pr create --title x"
    [ "$status" -eq 0 ]
    [[ "$output" == *"could NOT read the board"* ]]
}

@test "board without a Status field: silent, no 'could NOT read the board' warning" {
    write_fake_gh "OPEN"
    mv "$FAKE_BIN/gh" "$FAKE_BIN/gh.real"
    printf '%s\n' '#!/bin/bash' \
        '[[ "$1 $2" == "project field-list" ]] && { echo "{\"fields\":[]}"; exit 0; }' \
        'exec "$(dirname "$0")/gh.real" "$@"' > "$FAKE_BIN/gh"
    chmod +x "$FAKE_BIN/gh"
    run run_hook "gh pr create --title x"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "gh project list returning unparseable JSON warns instead of reading as no board" {
    write_fake_gh "OPEN"
    sed -i 's|echo .{"projects".*|echo not-json|' "$FAKE_BIN/gh"
    run run_hook "gh pr create --title x"
    [ "$status" -eq 0 ]
    [[ "$output" == *"could NOT read the board"* ]]
}

@test "warm cache missing the target column: silent, no read-the-board warning" {
    write_fake_gh "OPEN"
    run run_hook "gh pr create --title x"   # primes the cache via the happy path
    [[ "$output" == *"moved issue"* ]]
    local cache; cache="$(find "$CLAUDE_CONFIG_DIR" -name '*.json' | head -n1)"
    [ -n "$cache" ]
    jq 'del(.options["In review"])' "$cache" > "$cache.t" && mv "$cache.t" "$cache"
    sed -i '/"In review"/d' "$FAKE_BIN/gh"   # the board really has no such column now
    run run_hook "gh pr create --title x"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a string exit_code of \"0\" is not a failure" {
    write_fake_gh "OPEN"
    run run_hook_resp "gh pr create --title x" '{"stdout":"https://github.com/o/r/pull/9","stderr":"","exit_code":"0"}'
    [[ "$output" == *"moved issue"* ]]
}

@test "rtk-condensed gh pr create output (PR #N, no URL) still moves the card" {
    write_fake_gh "OPEN"
    run run_hook_resp "rtk gh pr create --title x" '{"stdout":"ok created PR #9","stderr":""}'
    [[ "$output" == *"moved issue"* ]]
}

# --- #900: `--input` REST PRs and compound commands ---------------------------------------------

write_pr_json() {
    local json='{"head":"fix/131-rest","base":"main"}'
    printf '%s' "${2:-$json}" > "$1"
}

@test "gh api pulls --input moves the card named by head in the file" {
    write_fake_gh "OPEN"
    write_pr_json "$TEST_TMP/pr.json"
    git checkout -q -b feat/999-other
    run run_hook "gh api -X POST repos/guilhermegor/dotfiles-dev/pulls --input $TEST_TMP/pr.json"
    [[ "$output" == *"moved issue"*"131"* ]]
}

@test "gh api pulls --input with an owner:branch head strips the owner" {
    write_fake_gh "OPEN"
    write_pr_json "$TEST_TMP/pr.json" '{"head":"guilhermegor:fix/131-rest"}'
    run run_hook "gh api -X POST repos/guilhermegor/dotfiles-dev/pulls --input $TEST_TMP/pr.json"
    [[ "$output" == *"moved issue"*"131"* ]]
}

@test "gh api pulls --input moves nothing for a missing file, bad JSON, or no head" {
    write_fake_gh "OPEN"
    run run_hook "gh api -X POST repos/guilhermegor/dotfiles-dev/pulls --input $TEST_TMP/nope.json"
    [ -z "$output" ]
    write_pr_json "$TEST_TMP/bad.json" 'not json'
    run run_hook "gh api -X POST repos/guilhermegor/dotfiles-dev/pulls --input $TEST_TMP/bad.json"
    [ -z "$output" ]
    write_pr_json "$TEST_TMP/nohead.json" '{"base":"main"}'
    run run_hook "gh api -X POST repos/guilhermegor/dotfiles-dev/pulls --input $TEST_TMP/nohead.json"
    [ -z "$output" ]
    write_pr_json "$TEST_TMP/list.json" '["fix/131-rest"]'
    run run_hook "gh api -X POST repos/guilhermegor/dotfiles-dev/pulls --input $TEST_TMP/list.json"
    [ -z "$output" ]
}

@test "gh api pulls --input with a shell-built path or stdin moves nothing" {
    write_fake_gh "OPEN"
    write_pr_json "$TEST_TMP/pr.json"
    run run_hook 'gh api -X POST repos/guilhermegor/dotfiles-dev/pulls --input "$F"'
    [ -z "$output" ]
    run run_hook "gh api -X POST repos/guilhermegor/dotfiles-dev/pulls --input -"
    [ -z "$output" ]
}

@test "a relative --input resolves from the cd path" {
    write_fake_gh "OPEN"
    mkdir "$TEST_TMP/sub"
    write_pr_json "$TEST_TMP/sub/pr.json"
    run run_hook "cd $TEST_TMP/sub && gh api -X POST repos/guilhermegor/dotfiles-dev/pulls --input pr.json"
    [[ "$output" == *"moved issue"* ]]
}

@test "cd <worktree> && gh pr create uses that worktree's branch" {
    write_fake_gh "OPEN"
    git worktree add -q -b feat/131-wt "$TEST_TMP/wt"
    git checkout -q -b feat/999-other
    run run_hook "cd $TEST_TMP/wt && gh pr create --title x --body y"
    [[ "$output" == *"moved issue"*"131"* ]]
}

@test "cd <worktree> && git checkout -b moves the card to In progress" {
    write_fake_gh "OPEN"
    git worktree add -q -b feat/131-wt "$TEST_TMP/wt"
    git checkout -q -b feat/999-other
    run run_hook "cd $TEST_TMP/wt && git checkout -b feat/131-next"
    [[ "$output" == *"moved issue"*"In progress"* ]]
}

@test "a verb after another command in a chain still counts, with no cd" {
    write_fake_gh "OPEN"
    run run_hook "git push -u origin HEAD && gh pr create --title x --body y"
    [[ "$output" == *"moved issue"* ]]
}

@test "a cd the hook cannot resolve moves nothing" {
    write_fake_gh "OPEN"
    run run_hook 'cd "$WT" && gh pr create --title x --body y'
    [ -z "$output" ]
    run run_hook 'cd && gh pr create --title x --body y'
    [ -z "$output" ]
    run run_hook "cd $TEST_TMP/missing && gh pr create --title x --body y"
    [ -z "$output" ]
}

@test "a verb inside a quoted argument or an echo does not count" {
    write_fake_gh "OPEN"
    run run_hook 'echo "git checkout -b feat/131-x && gh pr create"'
    [ -z "$output" ]
    run run_hook 'git commit -m "gh pr create" && echo gh pr create'
    [ -z "$output" ]
}

@test "a verb on a later line of a quoted argument does not count" {
    write_fake_gh "OPEN"
    run run_hook "$(printf 'echo "first line\ngit checkout -b feat/131-x\ngh pr create"')"
    [ -z "$output" ]
}

@test "a cd that does not carry to the verb (|| or |) moves nothing from the cd path" {
    write_fake_gh "OPEN"
    git worktree add -q -b feat/131-wt "$TEST_TMP/wt"
    git checkout -q -b feat/999-other
    run run_hook "cd $TEST_TMP/wt || gh pr create --title x --body y"
    [ -z "$output" ]
    run run_hook "cd $TEST_TMP/wt | gh pr create --title x --body y"
    [ -z "$output" ]
}

@test "pushd and builtin cd stop the scan rather than resolve the wrong card" {
    write_fake_gh "OPEN"
    git worktree add -q -b feat/131-wt "$TEST_TMP/wt"
    git checkout -q -b feat/999-other
    run run_hook "pushd $TEST_TMP/wt && gh pr create --title x --body y"
    [ -z "$output" ]
    run run_hook "builtin cd $TEST_TMP/wt && gh pr create --title x --body y"
    [ -z "$output" ]
}

@test "the first verb wins: checkout -b then pr create lands In progress" {
    write_fake_gh "OPEN"
    run run_hook "git checkout -b feat/131-x && gh pr create --title x --body y"
    [[ "$output" == *"In progress"* ]]
}

@test "a lone & or command cd does not carry the cd path" {
    write_fake_gh "OPEN"
    git worktree add -q -b feat/131-wt "$TEST_TMP/wt"
    git checkout -q -b feat/999-other
    run run_hook "cd $TEST_TMP/wt & gh pr create --title x --body y"
    [ -z "$output" ]
    run run_hook "command cd $TEST_TMP/wt && gh pr create --title x --body y"
    [ -z "$output" ]
}

@test "a REST PR whose --input file vanished does not fall back to HEAD's issue" {
    write_fake_gh "OPEN"
    git checkout -q -b feat/131-head
    run run_hook "gh api -X POST repos/guilhermegor/dotfiles-dev/pulls --input $TEST_TMP/gone.json"
    [ -z "$output" ]
}

@test "a cd followed by other work then a lone & or || does not carry the path" {
    write_fake_gh "OPEN"
    git worktree add -q -b feat/131-wt "$TEST_TMP/wt"
    git checkout -q -b feat/999-other
    run run_hook "cd $TEST_TMP/wt && git status & gh pr create --title x --body y"
    [ -z "$output" ]
    run run_hook "cd $TEST_TMP/wt && git status || gh pr create --title x --body y"
    [ -z "$output" ]
}

@test "a cd hidden behind if, time, ! or an assignment stops the scan" {
    write_fake_gh "OPEN"
    git worktree add -q -b feat/131-wt "$TEST_TMP/wt"
    git checkout -q -b feat/999-other
    run run_hook "if true; then cd $TEST_TMP/wt; fi; gh pr create --title x --body y"
    [ -z "$output" ]
    run run_hook "time cd $TEST_TMP/wt; gh pr create --title x --body y"
    [ -z "$output" ]
}
