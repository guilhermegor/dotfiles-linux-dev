#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/dispatch_plan.py — the planner
# round_dispatch_guard.sh reads for its verdict (dotfiles-dev#433 item 2).
#
# Strategy (same as dispatch_free_surface_guard.bats): `gh` is stubbed on PATH with a real
# executable script written per-test — dispatch_plan.py shells out to it directly, and again
# indirectly through the bash subprocess that sources lib/free_surface.sh, so the stub has to be
# a real file on PATH, not a shell function (a function in this bats process is invisible to
# either child process). `git` is the real `/usr/bin/git` against a throwaway local repo, so
# `git rev-parse --show-toplevel` and glob expansion have a real tree to work against.
#
# The gate's own two-halves contract (ai_clients/CLAUDE.md, dotfiles-dev#398) applies here too:
#   1. success returns a USABLE answer — dispatchable/excluded are the documented shape, and
#      non-empty content actually reaches them, not just an exit-0 with nothing set;
#   2. the fail-closed path is exercised with a stub that makes the underlying gh call fail,
#      asserting every open issue comes back excluded (never a partial "some are free" guess)
#      and dispatchable stays empty.
#
# Run locally: bats tests/dispatch_plan.bats

setup() {
    PLANNER="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/lib/dispatch_plan.py"
    TEST_TMP="$(mktemp -d)"
    cd "$TEST_TMP" || return 1
    /usr/bin/git init -q -b main .
    /usr/bin/git config user.email t@t
    /usr/bin/git config user.name t
    /usr/bin/git commit -q --allow-empty -m init

    AGENT_WORKTREES=()

    BIN="$TEST_TMP/bin"
    mkdir -p "$BIN"
    PATH="$BIN:$PATH"
    export PATH
}

teardown() {
    local wt
    for wt in "${AGENT_WORKTREES[@]:-}"; do
        [ -n "$wt" ] || continue
        /usr/bin/git -C "$TEST_TMP" worktree remove --force "$wt" 2>/dev/null
        rm -rf "$wt"
    done
    cd /
    rm -rf "$TEST_TMP"
}

# mk_agent_worktree BRANCH FILE...
# Registers a real git worktree of $TEST_TMP on a new branch off "main", with FILE... committed
# on it — simulates a LIVE agent (dotfiles-dev#433 finding 1: collision is agent-vs-agent, a
# git-worktree notion, never agent-vs-open-PR). The worktree lives outside $TEST_TMP so its
# files can never be reached by root.glob() from the planner's own checkout (finding 3's whole
# point: a live agent's file is invisible to the local glob and must still be caught).
mk_agent_worktree() {
    local branch="$1"
    shift
    local wt
    wt="$(mktemp -d)"
    AGENT_WORKTREES+=("$wt")
    /usr/bin/git worktree add -q -b "$branch" "$wt" main
    local f
    for f in "$@"; do
        mkdir -p "$(dirname "$wt/$f")"
        : >"$wt/$f"
        /usr/bin/git -C "$wt" add "$f"
    done
    /usr/bin/git -C "$wt" -c user.email=t@t -c user.name=t commit -q -m "agent: $branch"
}

# gh_field NAME -> the .body value of one gh issue-list record: a fenced ```surface block
# built from the remaining args, one path/glob per line. No args -> no block at all.
issue_json() {
    local number="$1"
    shift
    if [ "$#" -eq 0 ]; then
        printf '{"number": %s, "body": "no surface here"}' "$number"
        return
    fi
    local body="\`\`\`surface\\n"
    local f
    for f in "$@"; do
        body="${body}${f}\\n"
    done
    body="${body}\`\`\`"
    printf '{"number": %s, "body": "%s"}' "$number" "$body"
}

# stub_gh ISSUES_JSON [HELD_FILE] [CLAIMED_ISSUE] [FAIL_BRANCH] [FROZEN_PR_FILE] [MENTION_PRS_JSON]
# ISSUES_JSON is the full `gh issue list --json number,body` array. HELD_FILE, if given, is the
# one file the "feature" branch's compare reports as held (gate_free_surface's OWN held-paths
# computation — unused by the planner's classification since #433 finding 1, still exercised
# here so gate_free_surface itself keeps succeeding for the claimed-issue answer it still
# supplies). CLAIMED_ISSUE, if given, is the one issue number closingIssuesReferences reports as
# already claimed. FAIL_BRANCH=1 makes the default-branch lookup fail, exercising
# gate_free_surface's own fail-closed path. FROZEN_PR_FILE, if given, is a file an OPEN PR (no
# live agent behind it — no matching worktree) touches, for finding 1's own test. MENTION_PRS_JSON,
# if given, is the full `gh pr list --json number,title,body,closingIssuesReferences` array the
# planner's OWN mention-without-closing read (dotfiles-dev#413) returns — default `[]` (no PRs
# mention anything).
stub_gh() {
    local issues_json="$1" held="${2:-}" claimed="${3:-}" fail="${4:-0}" frozen="${5:-}"
    local mention_prs="${6:-[]}"
    local claimed_nodes="[]"
    [ -n "$claimed" ] && claimed_nodes="[{\"closingIssuesReferences\":{\"nodes\":[{\"number\":$claimed}]}}]"
    local pr_list='[]'
    [ -n "$frozen" ] && pr_list='[{"number":99,"headRefName":"frozen-pr-branch"}]'
    cat >"$BIN/gh" <<STUB
#!/bin/bash
case "\$*" in
"repo view --json nameWithOwner -q .nameWithOwner") echo "acme/widgets" ;;
"issue list --repo acme/widgets --state open --limit 500 --json number,body")
    cat <<'JSON'
$issues_json
JSON
    ;;
"issue list --repo acme/widgets --state open --limit 500 --json number --jq .[].number")
    # A QUOTED heredoc, exactly like the --json number,body branch above. Interpolating
    # \$issues_json into a double-quoted printf argument instead breaks the generated stub:
    # the JSON's own double quotes end the quoting and its \`\`\`surface fence becomes command
    # substitution, so this branch exited non-zero and gate_free_surface's third
    # \`|| return 1\` fired -- every issue came back UNKNOWN and tests 3-8 failed.
    python3 -c 'import json,sys; [print(i["number"]) for i in json.load(sys.stdin)]' <<'JSON'
$issues_json
JSON
    ;;
"api repos/acme/widgets --jq .default_branch")
    [ "$fail" = 1 ] && exit 1
    echo main
    ;;
"pr list --repo acme/widgets --state open --json number,headRefName --limit 200") echo '$pr_list' ;;
"pr list --repo acme/widgets --state open --json number,title,body,closingIssuesReferences --limit 200")
    cat <<'JSON'
$mention_prs
JSON
    ;;
"pr view 99 --repo acme/widgets --json files --jq .files[].path") echo "$frozen" ;;
"api repos/acme/widgets/branches --paginate --jq .[].name") printf 'main\nfeature\n' ;;
"api repos/acme/widgets/compare/main...feature --jq .files[]?.filename") echo "$held" ;;
"api graphql -f query="*)
    echo '{"data":{"search":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":$claimed_nodes}}}'
    ;;
*) echo "UNSTUBBED: \$*" >&2; exit 1 ;;
esac
STUB
    chmod +x "$BIN/gh"
}

run_planner() {
    run python3 "$PLANNER"
}

field() {
    # field JQ_EXPR -> evaluate JQ_EXPR against $output.
    printf '%s' "$output" | jq -r "$1"
}

# --- shape: the documented contract, both arrays, always ------------------------------------

@test "output is exactly one JSON object with dispatchable and excluded arrays" {
    stub_gh "[$(issue_json 1 free/a.sh)]"
    run_planner
    [ "$status" -eq 0 ]
    [ "$(field '(.dispatchable | type) + "," + (.excluded | type)')" = "array,array" ]
}

@test "zero open issues is a valid, empty plan" {
    stub_gh '[]'
    run_planner
    [ "$status" -eq 0 ]
    [ "$(field '.dispatchable | length')" -eq 0 ]
    [ "$(field '.excluded | length')" -eq 0 ]
}

# --- the three classify states, kept apart -------------------------------------------------

@test "a fully free surface is dispatchable with its files named" {
    stub_gh "[$(issue_json 3 free/a.sh)]"
    run_planner
    [ "$status" -eq 0 ]
    [ "$(field '.dispatchable[0].issue')" = "3" ]
    [ "$(field '.dispatchable[0].surface[0]')" = "free/a.sh" ]
    [ "$(field '.excluded | length')" -eq 0 ]
}

@test "a fully held surface is excluded, naming the held path" {
    stub_gh "[$(issue_json 2 held/file.sh)]"
    mk_agent_worktree agent-a held/file.sh
    run_planner
    [ "$status" -eq 0 ]
    [ "$(field '.dispatchable | length')" -eq 0 ]
    [[ "$(field '.excluded[0].reason')" == *"held/file.sh"* ]]
}

@test "a partially held surface (would-need-a-held-file) is dispatched anyway" {
    stub_gh "[$(issue_json 4 free/a.sh held/file.sh)]" held/file.sh
    run_planner
    [ "$status" -eq 0 ]
    [ "$(field '.dispatchable[0].issue')" = "4" ]
    [ "$(field '.dispatchable[0].surface | length')" -eq 2 ]
    [ "$(field '.excluded | length')" -eq 0 ]
}

# --- issues that never reach a collision check at all ---------------------------------------

@test "an issue with no declared surface is excluded, never silently dropped" {
    stub_gh "[$(issue_json 1)]"
    run_planner
    [ "$status" -eq 0 ]
    [ "$(field '.dispatchable | length')" -eq 0 ]
    [ "$(field '.excluded[0].issue')" = "1" ]
    [[ "$(field '.excluded[0].reason')" == *"no declared file surface"* ]]
}

@test "an issue already claimed by a PR is excluded and never blocks its neighbour" {
    stub_gh "[$(issue_json 5 free/a.sh), $(issue_json 6 free/b.sh)]" "" 5
    run_planner
    [ "$status" -eq 0 ]
    [ "$(field '.dispatchable[0].issue')" = "6" ]
    [ "$(field '.excluded[0].issue')" = "5" ]
    [[ "$(field '.excluded[0].reason')" == *"already claimed"* ]]
}

# --- glob expansion against the real tree ----------------------------------------------------

@test "a glob token expands to the concrete files it matches in the tree" {
    mkdir -p "$TEST_TMP/hooks/lib"
    : >"$TEST_TMP/hooks/lib/foo_handler.py"
    : >"$TEST_TMP/hooks/lib/bar_handler.py"
    stub_gh "[$(issue_json 7 'hooks/lib/*_handler.py')]"
    run_planner
    [ "$status" -eq 0 ]
    [ "$(field '.dispatchable[0].surface | length')" -eq 2 ]
    [[ "$(field '.dispatchable[0].surface | join(",")')" == *"hooks/lib/bar_handler.py"* ]]
    [[ "$(field '.dispatchable[0].surface | join(",")')" == *"hooks/lib/foo_handler.py"* ]]
}

# --- finding 1: collision is agent-vs-agent, never agent-vs-open-PR (PR #476 review) ---------

@test "a candidate colliding only with a frozen open PR (no live agent) is dispatchable" {
    stub_gh "[$(issue_json 10 frozen/only.sh)]" "" "" 0 frozen/only.sh
    run_planner
    [ "$status" -eq 0 ]
    [ "$(field '.dispatchable[0].issue')" = "10" ]
    [ "$(field '.excluded | length')" -eq 0 ]
}

@test "a candidate colliding with a live agent worktree is excluded (pre-fix: same case was free)" {
    mk_agent_worktree agent-live agent/held.sh
    stub_gh "[$(issue_json 11 agent/held.sh)]"
    run_planner
    [ "$status" -eq 0 ]
    [ "$(field '.dispatchable | length')" -eq 0 ]
    [[ "$(field '.excluded[0].reason')" == *"agent/held.sh"* ]]
}

# --- finding 2: a truncated issue read must not yield a complete-looking plan (LATENT here) ---

@test "an issue list at the 500-issue cap refuses to print a plan, never a partial one" {
    local json="[" i
    for ((i = 1; i <= 500; i++)); do
        [ "$i" -gt 1 ] && json+=","
        json+="$(issue_json "$i")"
    done
    json+="]"
    stub_gh "$json"
    run_planner
    [ "$status" -ne 0 ]
    [[ "$output" != *'"dispatchable"'* ]]
}

# --- finding 3: a glob token must see a live agent's file too, not just the local checkout ----

@test "a live agent's file invisible to root.glob still collides (pre-fix: read as free)" {
    mk_agent_worktree agent-glob hooks/lib/new_handler.py
    stub_gh "[$(issue_json 12 'hooks/lib/*_handler.py')]"
    run_planner
    [ "$status" -eq 0 ]
    [ "$(field '.dispatchable | length')" -eq 0 ]
    [[ "$(field '.excluded[0].reason')" == *"hooks/lib/new_handler.py"* ]]
}

# --- finding 4: dispatchable candidates must be mutually disjoint -----------------------------

@test "two candidates declaring the same free path are not both dispatched" {
    stub_gh "[$(issue_json 20 shared.sh), $(issue_json 21 shared.sh extra.sh)]"
    run_planner
    [ "$status" -eq 0 ]
    [ "$(field '.dispatchable | length')" -eq 1 ]
    [ "$(field '.dispatchable[0].issue')" = "20" ]
    [ "$(field '.excluded[0].issue')" = "21" ]
    [[ "$(field '.excluded[0].reason')" == *"shared.sh"* ]]
}

@test "greedy selection prefers two small disjoint candidates over one bigger one" {
    stub_gh "[$(issue_json 30 x.sh), $(issue_json 31 y.sh), $(issue_json 32 x.sh y.sh)]"
    run_planner
    [ "$status" -eq 0 ]
    [ "$(field '.dispatchable | length')" -eq 2 ]
    [ "$(field '[.dispatchable[].issue] | sort | join(",")')" = "30,31" ]
    [ "$(field '.excluded[0].issue')" = "32" ]
}

# --- mentioned-without-closing: a PR naming an issue but not closing it (dotfiles-dev#413) ----

@test "an issue named by an open PR without a closing keyword is excluded, not offered" {
    stub_gh "[$(issue_json 361 free/a.sh)]" "" "" 0 "" \
        '[{"number":514,"title":"stacked follow-up","body":"relates to #361 five times, see #361","closingIssuesReferences":[]}]'
    run_planner
    [ "$status" -eq 0 ]
    [ "$(field '.dispatchable | length')" -eq 0 ]
    [ "$(field '.excluded[0].issue')" = "361" ]
    [[ "$(field '.excluded[0].reason')" == *"PR #514"* ]]
    [[ "$(field '.excluded[0].reason')" == *"closing keyword"* ]]
}

@test "an issue an open PR actually closes is unaffected by the mention check" {
    stub_gh "[$(issue_json 40 free/a.sh)]" "" "" 0 "" \
        '[{"number":41,"title":"fix","body":"Closes #40","closingIssuesReferences":[{"number":40}]}]'
    run_planner
    [ "$status" -eq 0 ]
    [ "$(field '.dispatchable[0].issue')" = "40" ]
    [ "$(field '.excluded | length')" -eq 0 ]
}

@test "a PR mentioning a DIFFERENT issue number never excludes this one (#12 vs #123)" {
    stub_gh "[$(issue_json 12 free/a.sh)]" "" "" 0 "" \
        '[{"number":50,"title":"unrelated","body":"see #123 for context","closingIssuesReferences":[]}]'
    run_planner
    [ "$status" -eq 0 ]
    [ "$(field '.dispatchable[0].issue')" = "12" ]
    [ "$(field '.excluded | length')" -eq 0 ]
}

# --- PR #506 review: same-repo qualified references, and a truncated PR read fails loud -------

@test "a same-repository qualified reference (owner/repo#N) excludes the same as bare #N" {
    stub_gh "[$(issue_json 361 free/a.sh)]" "" "" 0 "" \
        '[{"number":514,"title":"stacked follow-up","body":"see acme/widgets#361 for context","closingIssuesReferences":[]}]'
    run_planner
    [ "$status" -eq 0 ]
    [ "$(field '.dispatchable | length')" -eq 0 ]
    [ "$(field '.excluded[0].issue')" = "361" ]
    [[ "$(field '.excluded[0].reason')" == *"PR #514"* ]]
}

@test "a DIFFERENT repository's qualified reference never excludes this issue" {
    stub_gh "[$(issue_json 361 free/a.sh)]" "" "" 0 "" \
        '[{"number":514,"title":"unrelated","body":"see other/repo#361 for context","closingIssuesReferences":[]}]'
    run_planner
    [ "$status" -eq 0 ]
    [ "$(field '.dispatchable[0].issue')" = "361" ]
    [ "$(field '.excluded | length')" -eq 0 ]
}

@test "a same-repository qualified reference matches case-insensitively" {
    stub_gh "[$(issue_json 361 free/a.sh)]" "" "" 0 "" \
        '[{"number":514,"title":"stacked follow-up","body":"see ACME/Widgets#361 for context","closingIssuesReferences":[]}]'
    run_planner
    [ "$status" -eq 0 ]
    [ "$(field '.dispatchable | length')" -eq 0 ]
    [ "$(field '.excluded[0].issue')" = "361" ]
}

@test "a repo slug that is merely a suffix of a longer word does not match (near-miss)" {
    stub_gh "[$(issue_json 361 free/a.sh)]" "" "" 0 "" \
        '[{"number":514,"title":"noise","body":"notacme/widgets#361 should not count","closingIssuesReferences":[]}]'
    run_planner
    [ "$status" -eq 0 ]
    [ "$(field '.dispatchable[0].issue')" = "361" ]
    [ "$(field '.excluded | length')" -eq 0 ]
}

@test "an open PR list at the 200-PR cap refuses to print a plan, never a partial one" {
    local prs="[" i
    for ((i = 1; i <= 200; i++)); do
        [ "$i" -gt 1 ] && prs+=","
        prs+="{\"number\":$i,\"title\":\"\",\"body\":\"\",\"closingIssuesReferences\":[]}"
    done
    prs+="]"
    stub_gh "[$(issue_json 1)]" "" "" 0 "" "$prs"
    run_planner
    [ "$status" -ne 0 ]
    [[ "$output" != *'"dispatchable"'* ]]
}

# --- fail-closed half of the gate contract (dotfiles-dev#398) --------------------------------

@test "a gate failure excludes every issue as UNKNOWN, never a partial free answer" {
    stub_gh "[$(issue_json 1 free/a.sh), $(issue_json 2 free/b.sh)]" "" "" 1
    run_planner
    [ "$status" -eq 0 ]
    [ "$(field '.dispatchable | length')" -eq 0 ]
    [ "$(field '.excluded | length')" -eq 2 ]
    [[ "$(field '.excluded[0].reason')" == *"UNKNOWN"* ]]
    [[ "$(field '.excluded[1].reason')" == *"UNKNOWN"* ]]
}

# --- fails loud, not closed-and-quiet, on a broken read itself -------------------------------

@test "gh missing entirely prints nothing parseable, never a fake empty plan" {
    rm -f "$BIN/gh"
    run_planner
    [ "$status" -ne 0 ]
    [[ "$output" != *'"dispatchable"'* ]]
}
