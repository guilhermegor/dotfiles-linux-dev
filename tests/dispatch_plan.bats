#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/dispatch_plan.py — the planner
# round_dispatch_guard.sh reads for its verdict (dotfiles-linux-dev#433 item 2).
#
# Strategy (same as dispatch_free_surface_guard.bats): `gh` is stubbed on PATH with a real
# executable script written per-test — dispatch_plan.py shells out to it directly, and again
# indirectly through the bash subprocess that sources lib/free_surface.sh, so the stub has to be
# a real file on PATH, not a shell function (a function in this bats process is invisible to
# either child process). `git` is the real `/usr/bin/git` against a throwaway local repo, so
# `git rev-parse --show-toplevel` and glob expansion have a real tree to work against.
#
# The gate's own two-halves contract (ai_clients/CLAUDE.md, dotfiles-linux-dev#398) applies here too:
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
    # dotfiles-linux-dev#572: live_agent_held_paths() now delegates to gate_live_agent_surface
    # (free_surface.sh), which resolves ITS OWN default branch from a real `origin` remote --
    # unlike the planner's old from-scratch walk, which took the branch name as a plain
    # argument and needed no remote at all. A non-GitHub URL keeps every test below byte-for-
    # byte unchanged (the forge dead-worktree exclusion stays off, same as every fixture in
    # tests/live_agent_surface.bats) while giving the gate a real refs/remotes/origin/HEAD to
    # resolve "main" from, with no network call.
    /usr/bin/git remote add origin "$TEST_TMP"
    /usr/bin/git update-ref refs/remotes/origin/main refs/heads/main
    /usr/bin/git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

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
# on it — simulates a LIVE agent (dotfiles-linux-dev#433 finding 1: collision is agent-vs-agent, a
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

# mk_dead_agent_worktree BRANCH FILE -> echoes the worktree's HEAD sha.
# Like mk_agent_worktree, but also fabricates a same-commit upstream tracking ref — this
# fixture has no real remote to push to, and _worktree_dead_and_clean (free_surface.sh,
# dotfiles-linux-dev#551) requires "nothing ahead of upstream" before it will call a worktree dead.
# Exercises the #572 delegation end-to-end: a forge-confirmed dead worktree must stop holding
# its files once dispatch_plan.py routes through gate_live_agent_surface.
mk_dead_agent_worktree() {
    local branch="$1" file="$2"
    mk_agent_worktree "$branch" "$file"
    local wt="${AGENT_WORKTREES[${#AGENT_WORKTREES[@]}-1]}"
    local head
    head="$(/usr/bin/git -C "$wt" rev-parse HEAD)"
    /usr/bin/git -C "$TEST_TMP" update-ref "refs/remotes/origin/$branch" "$head"
    /usr/bin/git -C "$wt" branch --set-upstream-to="origin/$branch" "$branch" >/dev/null
    printf '%s\n' "$head"
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

# issue_json_labeled NUMBER LABEL SURFACE_PATH...
# Same as issue_json but with a "labels" array carrying LABEL — dedicated variant so the common
# case (issue_json) never has to thread an empty/optional labels list through every test.
issue_json_labeled() {
    local number="$1" label="$2"
    shift 2
    local body="\`\`\`surface\\n"
    local f
    for f in "$@"; do
        body="${body}${f}\\n"
    done
    body="${body}\`\`\`"
    printf '{"number": %s, "body": "%s", "labels": [{"name": "%s"}]}' "$number" "$body" "$label"
}

# stub_gh ISSUES_JSON [HELD_FILE] [CLAIMED_ISSUE] [FAIL_BRANCH] [FROZEN_PR_FILE] [MENTION_PRS_JSON]
#         [NATIVE_BLOCK_ISSUE] [NATIVE_BLOCK_JSON] [NATIVE_BLOCK_FAIL_ISSUE] [DEAD_PR_ROW]
# ISSUES_JSON is the full `gh issue list --json number,body` array. HELD_FILE, if given, is the
# one file the "feature" branch's compare reports as held (gate_free_surface's OWN held-paths
# computation — unused by the planner's classification since #433 finding 1, still exercised
# here so gate_free_surface itself keeps succeeding for the claimed-issue answer it still
# supplies). CLAIMED_ISSUE, if given, is the one issue number closingIssuesReferences reports as
# already claimed. FAIL_BRANCH=1 makes the default-branch lookup fail, exercising
# gate_free_surface's own fail-closed path, and the claimed-issues read too: the planner no longer
# computes the gate's held set (dotfiles-linux-dev#607), so the default-branch lookup alone cannot break
# the gate any more. Every call is appended to $BIN/gh.calls.
# FROZEN_PR_FILE, if given, is a file an OPEN PR (no
# live agent behind it — no matching worktree) touches, for finding 1's own test. MENTION_PRS_JSON,
# if given, is the flat `number,title,body,closingIssuesReferences` PR array the stub serves, re-shaped
# into GraphQL pages, to the planner's OWN mention-without-closing read (dotfiles-linux-dev#413) returns — default `[]` (no PRs
# mention anything). NATIVE_BLOCK_ISSUE/NATIVE_BLOCK_JSON, if given, make the
# `issues/<n>/dependencies/blocked_by` read for that one issue return NATIVE_BLOCK_JSON (a
# `_ru_native_blockers`-shaped array) instead of the default `[]` (no native blockers).
# NATIVE_BLOCK_FAIL_ISSUE, if given, makes that same read FAIL for that one issue (dotfiles-
# dev#560's fail-closed path). Every other issue's blocked_by read defaults to `[]`. DEAD_PR_ROW,
# if given as "<oid>:<branch>", is the one row `_dead_branch_index` (free_surface.sh,
# dotfiles-linux-dev#572) reports as a MERGED PR — default `[]` (no dead PRs), which is what keeps the
# forge dead-worktree exclusion off for every test that does not opt in via a GitHub-shaped
# origin (see mk_dead_agent_worktree).
stub_gh() {
    local issues_json="$1" held="${2:-}" claimed="${3:-}" fail="${4:-0}" frozen="${5:-}"
    local mention_prs="${6:-[]}"
    local native_block_issue="${7:-}" native_block_json="${8:-[]}" native_block_fail_issue="${9:-}"
    local dead_row="${10:-}"
    local claimed_nodes="[]"
    [ -n "$claimed" ] && claimed_nodes="[{\"closingIssuesReferences\":{\"nodes\":[{\"number\":$claimed}]}}]"
    local pr_list='[]'
    [ -n "$frozen" ] && pr_list='[{"number":99,"headRefName":"frozen-pr-branch"}]'
    local dead_prs='[]'
    if [ -n "$dead_row" ]; then
        dead_prs="[{\"headRefName\":\"${dead_row#*:}\",\"headRefOid\":\"${dead_row%%:*}\",\"state\":\"MERGED\",\"isCrossRepository\":false}]"
    fi
    cat >"$BIN/gh" <<STUB
#!/bin/bash
echo "\$*" >>"$BIN/gh.calls"
case "\$*" in
"repo view --json nameWithOwner -q .nameWithOwner") echo "acme/widgets" ;;
"api --paginate repos/acme/widgets/issues"*)
    # open_issues() reads REST, not \`gh issue list\` -- GraphQL refuses under the secondary
    # limiter while REST keeps answering. A prefix pattern, because the query string carries
    # \`?\` and \`&\`, both of which are glob metacharacters inside \`case\`.
    #
    # \`gh api --paginate\` MERGES array pages into one array (measured: per_page=5 over 6
    # pages -> a single 28-element array \`json.loads\` parses), so the stub emits one array
    # exactly as the real command does -- never one array per page.
    cat <<'JSON'
$issues_json
JSON
    ;;
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
"api graphql -f owner="*)
    # open_prs() pages the board (dotfiles-linux-dev#600): honour the planner's own \`first=\` and
    # \`after=\` variables and re-shape the flat MENTION_PRS_JSON fixture into the GraphQL page
    # the real API returns, with the offset as the cursor. GH_FAIL_AFTER=<cursor> makes the page
    # requested after that cursor fail like a gateway 502.
    after=0
    first=20
    for arg in "\$@"; do
        case "\$arg" in
            after=*) after="\${arg#after=}" ;;
            first=*) first="\${arg#first=}" ;;
        esac
    done
    if [ "\$after" = "\${GH_FAIL_AFTER:-none}" ]; then
        echo "gh: HTTP 502" >&2
        exit 1
    fi
    jq --argjson after "\$after" --argjson first "\$first" '
        . as \$all | .[\$after:\$after + \$first] as \$page
        | {data: {repository: {pullRequests: {
            pageInfo: {hasNextPage: ((\$after + \$first) < (\$all | length)),
                       endCursor: ((\$after + \$first) | tostring)},
            nodes: [\$page[] | {number, title, body,
                closingIssuesReferences: {nodes: (.closingIssuesReferences // [])}}]}}}}' <<'JSON'
$mention_prs
JSON
    ;;
"pr view 99 --repo acme/widgets --json files --jq .files[].path") echo "$frozen" ;;
"api repos/acme/widgets/branches --paginate --jq .[].name") printf 'main\nfeature\n' ;;
"api repos/acme/widgets/compare/main...feature --jq .files[]?.filename") echo "$held" ;;
"api repos/acme/widgets/issues/${native_block_fail_issue}/dependencies/blocked_by"*) exit 1 ;;
"api repos/acme/widgets/issues/${native_block_issue}/dependencies/blocked_by"*)
    cat <<'JSON'
$native_block_json
JSON
    ;;
"api repos/acme/widgets/issues/"*"/dependencies/blocked_by"*) echo '[]' ;;
"pr list --repo acme/widgets --state all --limit 200 --json headRefName,headRefOid,state,isCrossRepository")
    echo '$dead_prs'
    ;;
"api graphql -f query="*)
    [ "$fail" = 1 ] && exit 1
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

# --- blocked state (dotfiles-linux-dev#560): distinct from UNDECLARED, never dispatchable ----------

@test "an open native blocker excludes the issue as blocked, not UNDECLARED (no surface)" {
    # Mirrors #119: an open issue with no declared surface AND a native blocked_by relation --
    # pre-fix this read as UNDECLARED, hiding the real, more fundamental reason.
    stub_gh "[$(issue_json 119)]" "" "" 0 "" "[]" \
        119 '[{"state":"open","repository":{"full_name":"acme/widgets"},"number":334}]'
    run_planner
    [ "$status" -eq 0 ]
    [ "$(field '.dispatchable | length')" -eq 0 ]
    [ "$(field '.excluded[0].issue')" = "119" ]
    [[ "$(field '.excluded[0].reason')" == *"blocked"* ]]
    [[ "$(field '.excluded[0].reason')" == *"acme/widgets#334"* ]]
    [[ "$(field '.excluded[0].reason')" != *"UNDECLARED"* ]]
}

@test "an open native blocker excludes an otherwise-free issue, never dispatched" {
    stub_gh "[$(issue_json 120 free/a.sh)]" "" "" 0 "" "[]" \
        120 '[{"state":"open","repository":{"full_name":"acme/widgets"},"number":119}]'
    run_planner
    [ "$status" -eq 0 ]
    [ "$(field '.dispatchable | length')" -eq 0 ]
    [ "$(field '.excluded[0].issue')" = "120" ]
    [[ "$(field '.excluded[0].reason')" == *"blocked"* ]]
}

@test "a closed native blocker does not block — the issue is still dispatchable" {
    stub_gh "[$(issue_json 8 free/a.sh)]" "" "" 0 "" "[]" \
        8 '[{"state":"closed","repository":{"full_name":"acme/widgets"},"number":7}]'
    run_planner
    [ "$status" -eq 0 ]
    [ "$(field '.dispatchable[0].issue')" = "8" ]
    [ "$(field '.excluded | length')" -eq 0 ]
}

@test "a state:blocked label with no native blocker excludes the issue as blocked" {
    stub_gh "[$(issue_json_labeled 9 state:blocked free/a.sh)]"
    run_planner
    [ "$status" -eq 0 ]
    [ "$(field '.dispatchable | length')" -eq 0 ]
    [ "$(field '.excluded[0].issue')" = "9" ]
    [[ "$(field '.excluded[0].reason')" == *"blocked"* ]]
    [[ "$(field '.excluded[0].reason')" == *"state:blocked"* ]]
}

@test "a failed native-blocker read excludes the issue as UNKNOWN, never dispatched" {
    stub_gh "[$(issue_json 13 free/a.sh)]" "" "" 0 "" "[]" "" "[]" 13
    run_planner
    [ "$status" -eq 0 ]
    [ "$(field '.dispatchable | length')" -eq 0 ]
    [ "$(field '.excluded[0].issue')" = "13" ]
    [[ "$(field '.excluded[0].reason')" == *"UNKNOWN"* ]]
}

@test "a native-blocker batch that times out is UNKNOWN for every issue, never a crash" {
    run python3 - "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib" <<'PY'
import subprocess, sys
sys.path.insert(0, sys.argv[1])
import dispatch_plan

def timeout(*_args, **_kwargs):
    raise subprocess.TimeoutExpired(cmd="bash", timeout=1)

dispatch_plan.subprocess.run = timeout
print(dispatch_plan.native_open_blockers("acme/widget", [3, 7]))
PY
    [ "$status" -eq 0 ]
    [ "$output" = "{3: None, 7: None}" ]
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

# --- dotfiles-linux-dev#549: local-tree expansion and the held-path check must agree on `*` -------
#
# Both tests below expand against the REAL on-disk tree (a real subprocess python3 run against
# a real git repo, same as every other test in this file) -- not the stubbed `gh` responses --
# so they exercise the actual reachability of `root.glob`/`fnmatch`, not just the JSON parse.
# Pre-fix, `*` meant "stops at /" on the local side (pathlib) and "crosses /" on the held side
# (fnmatch): both tests below fail against that mismatch, for the two failure directions the
# issue measured.

@test "the template's docs/** placeholder expands to every nested file, never zero (#549)" {
    mkdir -p "$TEST_TMP/docs/sub/deep"
    : >"$TEST_TMP/docs/a.md"
    : >"$TEST_TMP/docs/sub/b.md"
    : >"$TEST_TMP/docs/sub/deep/c.md"
    stub_gh "[$(issue_json 30 'docs/**')]"
    run_planner
    [ "$status" -eq 0 ]
    # pre-fix: pathlib's `**` yields directories, `root.glob("docs/**")` matches 0 FILES, and
    # expand_tokens's `matches or [token]` fallback then reports the literal "docs/**" as the
    # whole surface (length 1) instead of the 3 real files it should have found.
    [ "$(field '.dispatchable[0].surface | length')" -eq 3 ]
    [[ "$(field '.dispatchable[0].surface | join(",")')" == *"docs/sub/deep/c.md"* ]]
}

@test "a single-star token crosses subdirectories, per the issue template's stated semantics" {
    mkdir -p "$TEST_TMP/docs/sub"
    : >"$TEST_TMP/docs/a.md"
    : >"$TEST_TMP/docs/sub/b.md"
    stub_gh "[$(issue_json 31 'docs/*')]"
    run_planner
    [ "$status" -eq 0 ]
    # pre-fix: pathlib's `*` stops at `/`, so `root.glob("docs/*")` only matches the top-level
    # docs/a.md -- the nested docs/sub/b.md is invisible to the local side, a false "free" for a
    # collision the held-side `fnmatch` would have caught.
    [ "$(field '.dispatchable[0].surface | length')" -eq 2 ]
    [[ "$(field '.dispatchable[0].surface | join(",")')" == *"docs/sub/b.md"* ]]
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

# --- dotfiles-linux-dev#572: the shared gate's dead-worktree exclusion reaches the planner too --------

@test "a forge-confirmed dead worktree is no longer counted as a live writer" {
    local dead_oid
    dead_oid="$(mk_dead_agent_worktree agent-dead dead/held.sh)"
    /usr/bin/git -C "$TEST_TMP" remote set-url origin git@github.com:acme/widgets.git
    stub_gh "[$(issue_json 13 dead/held.sh)]" "" "" 0 "" "[]" "" "[]" "" "$dead_oid:agent-dead"
    run_planner
    [ "$status" -eq 0 ]
    [ "$(field '.dispatchable[0].issue')" = "13" ]
    [ "$(field '.excluded | length')" -eq 0 ]
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

# --- mentioned-without-closing: a PR naming an issue but not closing it (dotfiles-linux-dev#413) ----

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

# --- dotfiles-linux-dev#600: the PR board is read in small pages, whole or not at all --------------

# mention_board N MENTIONER — a flat board of N PRs naming nothing, except PR number MENTIONER,
# whose body names issue #361 without a closing keyword. Putting it on the LAST page means it
# is only seen if every page before it was read and kept.
mention_board() {
    jq -nc --argjson n "$1" --argjson m "$2" '[range(1; $n + 1) | {
        number: ., title: "", closingIssuesReferences: [],
        body: (if . == $m then "relates to #361" else "" end)}]'
}

@test "a PR board larger than one page is read to the end: a mention on page 3 still counts" {
    stub_gh "[$(issue_json 361 free/a.sh)]" "" "" 0 "" "$(mention_board 45 45)"
    run_planner
    [ "$status" -eq 0 ]
    [ "$(field '.dispatchable | length')" -eq 0 ]
    [[ "$(field '.excluded[0].reason')" == *"PR #45"* ]]
}

@test "a page that fails mid-pagination is UNREADABLE for the whole board, never a partial one" {
    # Page one (PRs 1-20) answers and names nothing; the page after cursor 20 returns a 502. A
    # partial board here would read #361 as unmentioned and DISPATCH it despite the open PR on
    # page three — so every candidate must be excluded by name instead.
    export GH_FAIL_AFTER=20
    stub_gh "[$(issue_json 361 free/a.sh)]" "" "" 0 "" "$(mention_board 45 45)"
    run_planner
    [ "$status" -eq 0 ]
    [ "$(field '.dispatchable | length')" -eq 0 ]
    [ "$(field '.excluded[0].issue')" = "361" ]
    [[ "$(field '.excluded[0].reason')" == *"UNREADABLE"* ]]
}

@test "open_prs asks for small pages and returns every PR of every page" {
    stub_gh "[]" "" "" 0 "" "$(mention_board 45 0)"
    cd "$BATS_TEST_TMPDIR"
    run python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import dispatch_plan
prs = dispatch_plan.open_prs("acme/widgets")
print(len(prs), sorted(p["number"] for p in prs) == list(range(1, 46)), prs[0]["closingIssuesReferences"])
' "$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/lib"
    [ "$status" -eq 0 ]
    [ "$output" = "45 True []" ]
}

# --- fail-closed half of the gate contract (dotfiles-linux-dev#398) --------------------------------

@test "a gate failure excludes every issue as UNKNOWN, never a partial free answer" {
    stub_gh "[$(issue_json 1 free/a.sh), $(issue_json 2 free/b.sh)]" "" "" 1
    run_planner
    [ "$status" -eq 0 ]
    [ "$(field '.dispatchable | length')" -eq 0 ]
    [ "$(field '.excluded | length')" -eq 2 ]
    [[ "$(field '.excluded[0].reason')" == *"UNKNOWN"* ]]
    [[ "$(field '.excluded[1].reason')" == *"UNKNOWN"* ]]
}

# --- dotfiles-linux-dev#607: no gh call whose answer the planner throws away ----------------------

@test "the planner never reads per-PR files or per-branch compares it overwrites" {
    # gate_free_surface's agent-vs-open-PR held set is replaced by the live-agent set (#433
    # finding 1), yet computing it cost one `pr view` per open PR plus one compare per pushed
    # branch -- a cost that grows with the board and made the planner outrun the Stop guard.
    stub_gh "[$(issue_json 1 free/a.sh)]" held/file.sh "" 0 frozen/file.sh
    run_planner
    [ "$status" -eq 0 ]
    [ "$(field '.dispatchable[0].issue')" = "1" ]
    [ -s "$BIN/gh.calls" ]
    run grep -E 'pr view|/compare/|/branches' "$BIN/gh.calls"
    [ "$status" -ne 0 ]
}

# --- fails loud, not closed-and-quiet, on a broken read itself -------------------------------

@test "gh missing entirely prints nothing parseable, never a fake empty plan" {
    rm -f "$BIN/gh"
    run_planner
    [ "$status" -ne 0 ]
    [[ "$output" != *'"dispatchable"'* ]]
}

# --- dotfiles-linux-dev#534: the repo slug is a LOCAL fact -----------------------------------------

@test "repo_slug reads the local origin remote, so a dead gh cannot break the plan" {
	# The planner's FIRST call used to be `gh repo view --json nameWithOwner` (GraphQL). During a
	# GraphQL outage it died there, before reading a single issue, and both Stop guards reported
	# the plan UNREADABLE. `gh` is made to FAIL rather than removed from PATH: the fallback branch
	# must still be reachable, and a hard-missing binary would not distinguish the two.
	cd "$BATS_TEST_TMPDIR"
	git init -q slugrepo
	git -C slugrepo remote add origin git@github.com:someowner/somerepo.git
	mkdir -p bin
	printf '#!/bin/sh\nexit 1\n' >bin/gh
	chmod +x bin/gh
	# cwd must be INSIDE the repo: repo_slug reads `git remote get-url origin` from it
	cd slugrepo

	run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import dispatch_plan
print(dispatch_plan.repo_slug())
' "$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/lib" 
	[ "$status" -eq 0 ]
	[ "$output" = "someowner/somerepo" ]
}

@test "a non-GitHub origin falls through to gh, never a slug guessed from the URL shape" {
	# PR #545 review, Major: a bare [:/]owner/name tail also matched
	# git@gitlab.com:team/project.git, so repo_slug skipped the fallback and build_plan queried
	# GITHUB for that slug — a plausible answer about a repository that is not this checkout.
	cd "$BATS_TEST_TMPDIR"
	git init -q elsewhere
	git -C elsewhere remote add origin git@gitlab.com:team/project.git
	mkdir -p bin2
	printf '#!/bin/sh\nprintf "fellback/viagh\\n"\n' >bin2/gh
	chmod +x bin2/gh
	cd elsewhere

	run env PATH="$BATS_TEST_TMPDIR/bin2:$PATH" python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import dispatch_plan
print(dispatch_plan.repo_slug())
' "$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/lib"
	[ "$status" -eq 0 ]
	# the FALLBACK answered, not the regex: a gitlab URL must never yield team/project here
	[ "$output" = "fellback/viagh" ]
}

@test "repo_slug parses every remote URL shape this account actually uses" {
	run python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
from dispatch_plan import SLUG_RE
for url in ("git@github.com:o/r.git", "https://github.com/o/r.git",
            "https://github.com/o/r", "ssh://git@github.com/o/r.git"):
    m = SLUG_RE.search(url)
    print(f"{m.group(1)}/{m.group(2)}" if m else "NO-MATCH")
' "$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/lib"
	[ "$status" -eq 0 ]
	[ "$(printf '%s\n' "$output" | sort -u)" = "o/r" ]
}

# --- dotfiles-linux-dev#534: REST for what REST can answer, fail-closed-but-readable for what it cannot

@test "open_issues drops pull requests, which REST returns alongside issues" {
	# GitHub models a PR as an issue, so /issues returns both. `gh issue list` filtered for us;
	# `gh api` does not — without the filter the planner treats its own PRs as candidates.
	cd "$BATS_TEST_TMPDIR"
	mkdir -p bin3
	cat >bin3/gh <<'STUB'
#!/bin/sh
printf '[{"number":11,"body":"a real issue"},{"number":12,"body":"a PR","pull_request":{"url":"x"}}]\n'
STUB
	chmod +x bin3/gh

	run env PATH="$BATS_TEST_TMPDIR/bin3:$PATH" python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import dispatch_plan
print([i["number"] for i in dispatch_plan.open_issues("o/r")])
' "$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/lib"
	[ "$status" -eq 0 ]
	[ "$output" = "[11]" ]
}

@test "a refused closingIssuesReferences read excludes every issue BY NAME, never kills the plan" {
	# That read has no REST equivalent, so it alone can be refused while everything else is
	# healthy. Dying printed nothing and both Stop guards reported UNREADABLE; the plan must stay
	# readable and fail closed instead.
	cd "$BATS_TEST_TMPDIR"
	git init -q planrepo
	git -C planrepo remote add origin git@github.com:o/r.git
	mkdir -p bin4
	cat >bin4/gh <<'STUB'
#!/bin/sh
case "$*" in
  *"api graphql"*) exit 1 ;;                               # the GraphQL-only read, refused
  *"issues?state=open"*) printf '[{"number":77,"body":"no surface"}]\n' ;;
  *) printf 'master\n' ;;                                   # default_branch et al
esac
STUB
	chmod +x bin4/gh
	cd planrepo

	run env PATH="$BATS_TEST_TMPDIR/bin4:$PATH" python3 -c '
import json, sys
sys.path.insert(0, sys.argv[1])
import dispatch_plan
plan = dispatch_plan.build_plan()
print(json.dumps({"d": plan["dispatchable"], "x": [e["issue"] for e in plan["excluded"]],
                  "unreadable": all("UNREADABLE" in e["reason"] for e in plan["excluded"])}))
' "$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/lib"
	[ "$status" -eq 0 ]
	[[ "$output" == *'"d": []'* ]]
	[[ "$output" == *'"x": [77]'* ]]
	[[ "$output" == *'"unreadable": true'* ]]
}
