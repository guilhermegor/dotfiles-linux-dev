#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/owner_decisions.sh (dotfiles-linux-dev#1033).
# Every source is a provider seam replaced with a fixture; nothing here calls GitHub.

setup() {
    source "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/owner_decisions.sh"
    export OWNER_DECISIONS_REPOS="owner/repo"
    export OWNER_DECISIONS_EXCLUDE_FILE="$BATS_TEST_TMPDIR/exclusions.txt"
    : >"$OWNER_DECISIONS_EXCLUDE_FILE"
    PR_JSON='[]'
    ISSUE_JSON='[]'
    BOARD_REPORT=""
    WORKFLOWS=""
    REMOTE=""
    od_pr_json() { printf '%s' "$PR_JSON"; }
    od_issue_json() { printf '%s' "$ISSUE_JSON"; }
    od_board_report() { printf '%s\n' "$BOARD_REPORT"; }
    od_workflows_off() { printf '%s' "$WORKFLOWS"; }
    od_report_remote() { printf '%s' "$REMOTE"; }
    GATE_PENDING=""
    od_gate_pending() { printf '%s' "$GATE_PENDING"; }
    # Board discovery is a live GraphQL read; a test that wants it overrides this stub.
    discover_roadmap_boards() { return 0; }
}

@test "should-fail: a decision-blocked card IS listed" {
    BOARD_REPORT=$'owner/repo#7\tdecision: pick a vendor'
    run owner_decisions_collect
    [ "$status" -eq 0 ]
    [[ "$output" == *"owner/repo#7"* ]]
    [[ "$output" == *"pick a vendor"* ]]
}

# The real od_board_report against a stubbed `gh`: decision cards only, and no write call ever.
_board_fixture_gh() {
    GH_LOG="$BATS_TEST_TMPDIR/gh.log"
    : >"$GH_LOG"
    gh() {
        printf '%s\n' "$*" >>"$GH_LOG"
        [[ "$1 $2" == "project item-list" ]] || return 1
        printf '%s' '{"items":[
          {"status":"Blocked","blocked by":"decision: pick a vendor","content":{"type":"Issue","number":7,"repository":"owner/repo","body":""}},
          {"status":"Blocked","blocked by":"","content":{"type":"Issue","number":8,"repository":"owner/repo","body":"**Blocked by:** decision: which db"}},
          {"status":"Blocked","blocked by":"owner/repo#2","content":{"type":"Issue","number":9,"repository":"owner/repo","body":""}},
          {"status":"Ready","blocked by":"decision: x","content":{"type":"Issue","number":10,"repository":"owner/repo","body":""}}]}'
    }
}

@test "should-pass: the real board source lists only decision-blocked cards" {
    source "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/owner_decisions.sh"
    ROADMAP_BOARDS=("owner|1|repo")
    _board_fixture_gh
    run od_board_report
    [ "$status" -eq 0 ]
    [[ "$output" == *$'owner/repo#7\tdecision: pick a vendor'* ]]
    [[ "$output" == *"owner/repo#8"* ]]
    [[ "$output" != *"#9"* && "$output" != *"#10"* ]]
}

@test "should-fail: the board source never writes to a board" {
    source "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/owner_decisions.sh"
    ROADMAP_BOARDS=("owner|1|repo")
    _board_fixture_gh
    run od_board_report
    run grep -E 'item-edit|issue edit|mutation' "$GH_LOG"
    [ "$status" -ne 0 ]
}

@test "should-fail: a failing gh is UNREADABLE for every source, never none" {
    source "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/owner_decisions.sh"
    ROADMAP_BOARDS=("owner|1|repo")
    gh() { echo "HTTP 401" >&2; return 1; }
    prune_branches() { return 2; }
    _kb_checkout() { printf '%s\n' "$BATS_TEST_TMPDIR"; }
    run owner_decisions_collect
    [[ "$output" == *"UNREADABLE"*"open PRs of owner/repo"* ]]
    [[ "$output" == *"UNREADABLE"*"owner-decision issues of owner/repo"* ]]
    [[ "$output" == *"UNREADABLE"*"board decision blockers"* ]]
    [[ "$output" == *"UNREADABLE"*"Projects workflows"* ]]
    [[ "$output" == *"UNREADABLE"*"REPORT-REMOTE branches"* ]]
}

@test "a null project in the workflows answer is UNREADABLE, not none OFF" {
    source "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/owner_decisions.sh"
    ROADMAP_BOARDS=("org|1|repo")
    gh() { printf '%s' '{"data":{"user":null}}'; }
    run od_workflows_off
    [ "$status" -ne 0 ]
}

@test "an issue that is also a decision card is listed once" {
    ISSUE_JSON='[{"number":7,"title":"a","labels":[{"name":"state:blocked"}],"body":"**Blocked by:** decision: v","pull_request":null}]'
    BOARD_REPORT=$'owner/repo#7\tdecision: v'
    run owner_decisions_collect
    [ "$(grep -c 'owner/repo#7' <<<"$output")" -eq 1 ]
}

@test "should-pass: a #N exclusion does not hide a branch whose name holds #N" {
    REMOTE=$'fix#12\n'
    printf '#12\n' >"$OWNER_DECISIONS_EXCLUDE_FILE"
    run owner_decisions_collect
    [[ "$output" == *"fix#12"* ]]
}

@test "branch: and workflow: exclusions hide their rows" {
    WORKFLOWS=$'owner/13\tAuto-add to project\n'
    REMOTE=$'feat/old\n'
    printf 'branch:feat/old\nworkflow:owner/13/Auto-add to project # never ask\n' >"$OWNER_DECISIONS_EXCLUDE_FILE"
    run owner_decisions_collect
    [[ "$output" == *"No pending owner decisions."* ]]
}

@test "a Blocked by line that merely mentions decision is not a decision blocker" {
    ISSUE_JSON='[{"number":13,"title":"c","labels":[{"name":"state:blocked"}],"body":"**Blocked by:** #12 (no decision needed)","pull_request":null}]'
    run owner_decisions_collect
    [[ "$output" != *"owner/repo#13"* ]]
}

@test "a long multibyte cell is cut on a character boundary" {
    local long
    export LC_ALL=C.UTF-8
    long="$(printf 'é%.0s' {1..250})"
    run _od_cell "$long"
    [ "${#output}" -eq 200 ]
    iconv -f UTF-8 -t UTF-8 <<<"$output" >/dev/null
}

@test "should-pass: a routine merged PR is NOT listed" {
    PR_JSON='[{"number":5,"title":"feat: x","state":"closed","merged_at":"2026-11-01T00:00:00Z","body":"Decide whether to keep this."},
              {"number":6,"title":"chore: y","state":"open","merged_at":null,"body":"Ready to merge, then release."}]'
    run owner_decisions_collect
    [[ "$output" == *"No pending owner decisions."* ]]
    [[ "$output" != *"#5"* && "$output" != *"#6"* ]]
}

@test "an open PR flagging a judgement call is listed" {
    PR_JSON='[{"number":9,"title":"feat: y","state":"open","merged_at":null,"body":"Intro\nDecide whether to enable the surface expansion.\nBye"}]'
    run owner_decisions_collect
    [[ "$output" == *"owner/repo#9"* ]]
    [[ "$output" == *"Decide whether to enable"* ]]
}

@test "hitl issue is listed; state:blocked only when blocked by a decision" {
    ISSUE_JSON='[{"number":11,"title":"a","labels":[{"name":"hitl"}],"body":"","pull_request":null},
                 {"number":12,"title":"b","labels":[{"name":"state:blocked"}],"body":"**Blocked by:** decision: x","pull_request":null},
                 {"number":13,"title":"c","labels":[{"name":"state:blocked"}],"body":"**Blocked by:** #2","pull_request":null}]'
    run owner_decisions_collect
    [[ "$output" == *"owner/repo#11"* ]]
    [[ "$output" == *"owner/repo#12"* ]]
    [[ "$output" != *"owner/repo#13"* ]]
}

@test "should-pass: an issue named in the exclusions file is NOT listed" {
    ISSUE_JSON='[{"number":1046,"title":"blocked","labels":[{"name":"hitl"}],"body":"","pull_request":null},
                 {"number":12,"title":"other","labels":[{"name":"hitl"}],"body":"","pull_request":null}]'
    printf '# standing exclusions\n#1046 # blocked until owner says, never ask\n' >"$OWNER_DECISIONS_EXCLUDE_FILE"
    run owner_decisions_collect
    [[ "$output" != *"#1046"* ]]
    [[ "$output" == *"owner/repo#12"* ]]
}

@test "a full-ref exclusion also hides a decision-blocked card" {
    BOARD_REPORT='  decision blocker owner/repo#7: decision: v — left untouched [blocker-kind: decision]'
    printf 'owner/repo#7\n' >"$OWNER_DECISIONS_EXCLUDE_FILE"
    run owner_decisions_collect
    [[ "$output" == *"No pending owner decisions."* ]]
}

@test "OFF workflows and REPORT-REMOTE branches are listed" {
    WORKFLOWS=$'owner/13\tAuto-add to project\n'
    REMOTE=$'feat/old\n'
    run owner_decisions_collect
    [[ "$output" == *"Auto-add to project"* ]]
    [[ "$output" == *"feat/old"* ]]
}

@test "an unreadable source is reported, never read as none" {
    od_pr_json() { return 1; }
    run owner_decisions_collect
    [[ "$output" == *"UNREADABLE"*"open PRs of owner/repo"* ]]
}

@test "default repos come from ROADMAP_BOARDS owner and repo, each once" {
    unset OWNER_DECISIONS_REPOS
    ROADMAP_BOARDS=("acme|1|tool" "acme|2|tool" "guilhermegor|3|other")
    SEEN="$BATS_TEST_TMPDIR/repos.log"
    od_pr_json() { printf '%s\n' "$1" >>"$SEEN"; printf '[]'; }
    run owner_decisions_collect
    [ "$(cat "$SEEN")" = $'acme/tool\nguilhermegor/other' ]
}

# --- REPORT-REMOTE across every board repo (dotfiles-linux-dev#1046) ---

@test "should-fail: REPORT-REMOTE branches of EVERY board repo are listed, tagged by repo" {
    OWNER_DECISIONS_REPOS="acme/a acme/b"
    od_report_remote() {
        case "$1" in
        acme/a) printf 'feat/shared\n' ;;
        acme/b) printf 'feat/shared\nfix/only-b\n' ;;
        esac
    }
    run owner_decisions_collect
    [ "$(grep -c 'feat/shared' <<<"$output")" -eq 2 ]
    [[ "$output" == *"branch:acme/a:feat/shared"* ]]
    [[ "$output" == *"branch:acme/b:feat/shared"* ]]
    [[ "$output" == *"branch:acme/b:fix/only-b"* ]]
}

@test "should-fail: a board repo with no checkout is UNREADABLE, the others still list" {
    OWNER_DECISIONS_REPOS="acme/a acme/b"
    od_report_remote() { [[ "$1" == acme/a ]] || return 3; printf 'feat/x\n'; }
    run owner_decisions_collect
    [[ "$output" == *"branch:acme/a:feat/x"* ]]
    [[ "$output" == *'UNREADABLE (not "none"): REPORT-REMOTE branches of acme/b (no local checkout)'* ]]
    [[ "$output" != *"No pending owner decisions."* ]]
}

@test "should-fail: a repo whose branch pass fails is UNREADABLE, not clean" {
    OWNER_DECISIONS_REPOS="acme/a"
    od_report_remote() { return 1; }
    run owner_decisions_collect
    [[ "$output" == *"UNREADABLE"*"REPORT-REMOTE branches of acme/a"* ]]
    [[ "$output" != *"(no local checkout)"* ]]
}

@test "the real od_report_remote runs the dry-run pass in the repo's own checkout" {
    source "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/owner_decisions.sh"
    _kb_checkout() { printf '%s %s\n' "$1" "$2" >"$BATS_TEST_TMPDIR/co.log"; printf '/checkouts/%s\n' "$2"; }
    prune_branches() {
        printf '%s %s\n' "$1" "$2" >"$BATS_TEST_TMPDIR/prune.log"
        printf 'KEEP-REMOTE feat/held: held by a worktree\nREPORT-REMOTE feat/old: content missing from origin/master (judgement call, not deleted):\n    +x\n'
    }
    run od_report_remote acme/tool
    [ "$status" -eq 0 ]
    [ "$output" = "feat/old" ]
    [ "$(cat "$BATS_TEST_TMPDIR/co.log")" = "acme tool" ]
    [ "$(cat "$BATS_TEST_TMPDIR/prune.log")" = "/checkouts/tool 0" ]
}

@test "the real od_report_remote: no checkout is rc 3, an unreadable pass is rc 1" {
    source "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/owner_decisions.sh"
    _kb_checkout() { return 1; }
    run od_report_remote acme/tool
    [ "$status" -eq 3 ]
    _kb_checkout() { printf '/c\n'; }
    prune_branches() { echo "[branch-prune] forge PR list unreadable - skipped"; return 2; }
    run od_report_remote acme/tool
    [ "$status" -eq 1 ]
}

@test "an inherited GIT_DIR does not hide another repo's checkout" {
    source "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/owner_decisions.sh"
    export KANBAN_CHECKOUT_ROOT="$BATS_TEST_TMPDIR/github"
    local r
    for r in a b; do
        mkdir -p "$KANBAN_CHECKOUT_ROOT/$r"
        git init -q "$KANBAN_CHECKOUT_ROOT/$r"
        git -C "$KANBAN_CHECKOUT_ROOT/$r" remote add origin "https://github.com/acme/$r.git"
    done
    prune_branches() { printf 'REPORT-REMOTE feat/in-%s: content missing\n' "${1##*/}"; }
    export GIT_DIR="$KANBAN_CHECKOUT_ROOT/a/.git"
    run od_report_remote acme/b
    [ "$status" -eq 0 ]
    [ "$output" = "feat/in-b" ]
    [ "$GIT_DIR" = "$KANBAN_CHECKOUT_ROOT/a/.git" ]
}

@test "a failed board discovery is UNREADABLE, never an empty repo list" {
    discover_roadmap_boards() { ROADMAP_BOARDS_ERROR="UNKNOWN: board discovery failed"; return 1; }
    run owner_decisions_collect
    [[ "$output" == *'UNREADABLE (not "none"): board discovery'* ]]
}

@test "a board discovery skip reported UNKNOWN is UNREADABLE" {
    discover_roadmap_boards() { ROADMAP_BOARDS_REPORT=$'board me/4 (x): UNKNOWN - no linked repo\nboard me/5 (y): skipped - project is closed\n'; return 0; }
    run owner_decisions_collect
    [[ "$output" == *'UNREADABLE (not "none"): board me/4 (x): UNKNOWN'* ]]
    [[ "$output" != *"me/5"* ]]
}

@test "a repo-qualified branch exclusion hides only that repo's branch" {
    OWNER_DECISIONS_REPOS="acme/a acme/b"
    od_report_remote() { printf 'feat/dup\n'; }
    printf 'branch:acme/a:feat/dup # superseded\n' >"$OWNER_DECISIONS_EXCLUDE_FILE"
    run owner_decisions_collect
    [[ "$output" != *"branch:acme/a:feat/dup"* ]]
    [[ "$output" == *"branch:acme/b:feat/dup"* ]]
}

@test "a bare branch: exclusion hides that branch name in every repo" {
    OWNER_DECISIONS_REPOS="acme/a acme/b"
    od_report_remote() { printf 'feat/dup\n'; }
    printf 'branch:feat/dup\n' >"$OWNER_DECISIONS_EXCLUDE_FILE"
    run owner_decisions_collect
    [[ "$output" == *"No pending owner decisions."* ]]
}

# Failed board discovery leaves ROADMAP_BOARDS empty; that must never scan the phantom repo "/" (#1059).
_empty_boards_in_checkout() {
    unset OWNER_DECISIONS_REPOS
    ROADMAP_BOARDS=()
    SCANNED="$BATS_TEST_TMPDIR/scanned.log"
    : >"$SCANNED"
    od_pr_json() { printf '%s\n' "$1" >>"$SCANNED"; printf '[]'; }
    git init -q "$BATS_TEST_TMPDIR/co"
    git -C "$BATS_TEST_TMPDIR/co" remote add origin git@github.com:acme/widgets.git
    cd "$BATS_TEST_TMPDIR/co"
}

@test "should-fail: an empty ROADMAP_BOARDS never scans the phantom repo /" {
    _empty_boards_in_checkout
    run owner_decisions_collect
    run grep -qx '/' "$SCANNED"
    [ "$status" -eq 1 ]
}

@test "the cwd fallback strips a trailing slash from an https origin" {
    _empty_boards_in_checkout
    git remote set-url origin https://github.com/acme/widgets.git/
    run owner_decisions_collect
    [ "$(cat "$SCANNED")" = "acme/widgets" ]
}

@test "the cwd fallback scans nothing for a non-GitHub origin" {
    _empty_boards_in_checkout
    git remote set-url origin /srv/repos/widgets.git
    run owner_decisions_collect
    [ ! -s "$SCANNED" ]
    [[ "$output" == *"fallback to cwd origin repo (none)"* ]]
}

@test "the cwd fallback ignores an inherited GIT_DIR" {
    _empty_boards_in_checkout
    git init -q "$BATS_TEST_TMPDIR/other"
    git -C "$BATS_TEST_TMPDIR/other" remote add origin git@github.com:evil/elsewhere.git
    GIT_DIR="$BATS_TEST_TMPDIR/other/.git" run owner_decisions_collect
    [ "$(cat "$SCANNED")" = "acme/widgets" ]
}

@test "should-pass: an empty ROADMAP_BOARDS scans the cwd origin repo and reports the fallback" {
    _empty_boards_in_checkout
    run owner_decisions_collect
    [ "$(cat "$SCANNED")" = "acme/widgets" ]
    [[ "$output" == *"fallback"*"acme/widgets"* ]]
}

# --- owner-only gate approvals (#1130) -------------------------------------------------------

@test "should-pass: a PR waiting on a gate approval is listed as a decision" {
    GATE_PENDING=$'1312\ttouches gate-protected .review-bots.yaml, lacks label gate-change-approved'
    run owner_decisions_collect
    [ "$status" -eq 0 ]
    [[ "$output" == *"Approve gate change on PR owner/repo#1312"* ]]
    [[ "$output" == *".review-bots.yaml"* ]]
}

@test "should-fail: a failing gate source is UNREADABLE, never none" {
    od_gate_pending() { return 1; }
    run owner_decisions_collect
    [[ "$output" == *'UNREADABLE (not "none"): gate approvals of owner/repo'* ]]
}

# The real od_gate_pending against a stubbed gh. The repo's workflow declares its own paths.
_gate_fixture_gh() {
    source "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/owner_decisions.sh"
    FAIL_PR_FILES=""
    PRS='[{"number":1,"state":"open","merged_at":null,"head":{"sha":"aaa"},"labels":[]},
          {"number":2,"state":"open","merged_at":null,"head":{"sha":"bbb"},"labels":[{"name":"gate-change-approved"}]},
          {"number":3,"state":"open","merged_at":null,"head":{"sha":"ccc"},"labels":[]},
          {"number":4,"state":"open","merged_at":null,"head":{"sha":"ddd"},"labels":[{"name":"gate-change-approved"}]},
          {"number":5,"state":"open","merged_at":null,"head":{"sha":"eee"},"labels":[]}]'
    od_pr_json() { printf '%s' "$PRS"; }
    gh() {
        local a="$*"
        [[ "$a" == *"contents/.github/workflows/ci.yml"* ]] && { echo 'run: make test'; return 0; }
        if [[ "$a" == *"contents/.github/workflows/gate.yml"* ]]; then
            printf '%s\n' 'grep -Fx \' '  -e .github/workflows/gate.yml \' '  -e .review-bots.yaml || true' \
                'grep -Fxq gate-change-approved'
            return 0
        fi
        [[ "$a" == *"contents/.github/workflows"* ]] \
            && { printf '.github/workflows/ci.yml\n.github/workflows/gate.yml\n'; return 0; }
        [[ -n "$FAIL_PR_FILES" && "$a" == *"pulls/$FAIL_PR_FILES/files"* ]] && return 1
        [[ "$a" == *"pulls/1/files"* ]] && { printf '.review-bots.yaml\nREADME.md\n'; return 0; }
        [[ "$a" == *"pulls/2/files"* ]] && { printf '.review-bots.yaml\n'; return 0; }
        [[ "$a" == *"pulls/"*"/files"* ]] && { printf 'src/a.py\n'; return 0; }
        [[ "$a" == *"commits/ddd/check-runs"* ]] && { echo 901; return 0; }
        [[ "$a" == *"commits/"*"/check-runs"* ]] && return 0
        [[ "$a" == *"check-runs/901/annotations"* ]] \
            && { printf 'gate-weakening change(s) with no justification\n'; return 0; }
        return 1
    }
}

@test "should-pass: unlabelled gate-path PR and a GATE_CHANGE_OK refusal are listed" {
    _gate_fixture_gh
    run od_gate_pending owner/repo
    [ "$status" -eq 0 ]
    [[ "$output" == *$'1\ttouches gate-protected .review-bots.yaml'* ]]
    [[ "$output" == *$'4\tgate check failed on the GATE_CHANGE_OK refusal'* ]]
}

@test "should-fail: a labelled PR and an unrelated PR are not listed" {
    _gate_fixture_gh
    run od_gate_pending owner/repo
    [[ "$output" != *$'2\t'* && "$output" != *$'3\t'* && "$output" != *$'5\t'* ]]
}

@test "should-pass: a repo declaring no gate-protected paths lists no path hit" {
    _gate_fixture_gh
    gh() { [[ "$*" == *"contents/.github/workflows"* ]] && { echo "HTTP 404" >&2; return 1; }; return 0; }
    run od_gate_pending owner/repo
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "should-fail: an unreadable workflow listing is rc 1, not a clean none" {
    _gate_fixture_gh
    gh() { echo "HTTP 502" >&2; return 1; }
    run od_gate_pending owner/repo
    [ "$status" -eq 1 ]
}

@test "should-fail: an unreadable PR file list is rc 1" {
    _gate_fixture_gh
    FAIL_PR_FILES=1
    run od_gate_pending owner/repo
    [ "$status" -eq 1 ]
}

# --- review follow-ups on #1132 --------------------------------------------------------------

@test "should-pass: only the approval step's -e paths are gate-protected" {
    _gate_fixture_gh
    PRS='[{"number":1,"state":"open","merged_at":null,"head":{"sha":"aaa"},"labels":[]},
          {"number":2,"state":"open","merged_at":null,"head":{"sha":"bbb"},"labels":[]}]'
    gh() {
        local a="$*"
        [[ "$a" == *"contents/.github/workflows/gate.yml"* ]] && {
            printf '%s\n' '    steps:' '      - name: unrelated' '        run: |' \
                '          grep -Fx \' '            -e README.md || true' \
                '      - name: gate' '        run: |' '          grep -Fx \' \
                '            -e .review-bots.yaml || true' '          grep -Fxq gate-change-approved'
            return 0
        }
        [[ "$a" == *"contents/.github/workflows"* ]] && { echo .github/workflows/gate.yml; return 0; }
        [[ "$a" == *"pulls/1/files"* ]] && { echo README.md; return 0; }
        [[ "$a" == *"pulls/2/files"* ]] && { echo .review-bots.yaml; return 0; }
        return 0
    }
    run od_gate_pending owner/repo
    [ "$status" -eq 0 ]
    [[ "$output" == *$'2\ttouches gate-protected .review-bots.yaml'* ]]
    [[ "$output" != *"README.md"* ]]
}

@test "should-pass: a refusal annotation that only appears on page 2 is found" {
    _gate_fixture_gh
    PRS='[{"number":4,"state":"open","merged_at":null,"head":{"sha":"ddd"},"labels":[]}]'
    gh() {
        local a="$*"
        [[ "$a" == *"contents/.github/workflows"* ]] && return 0
        [[ "$a" == *"commits/ddd/check-runs"* ]] && { echo 901; return 0; }
        if [[ "$a" == *"check-runs/901/annotations"* ]]; then
            echo 'page one noise'
            [[ "$a" == *"--paginate"* ]] && echo 'GATE_CHANGE_OK required'
            return 0
        fi
        return 1
    }
    run od_gate_pending owner/repo
    [[ "$output" == *$'4\tgate check failed on the GATE_CHANGE_OK refusal'* ]]
}

@test "should-fail: an unreadable annotation read is rc 1, not a clean none" {
    _gate_fixture_gh
    PRS='[{"number":4,"state":"open","merged_at":null,"head":{"sha":"ddd"},"labels":[]}]'
    gh() {
        local a="$*"
        [[ "$a" == *"contents/.github/workflows"* ]] && return 0
        [[ "$a" == *"commits/ddd/check-runs"* ]] && { echo 901; return 0; }
        return 1
    }
    run od_gate_pending owner/repo
    [ "$status" -eq 1 ]
}

@test "should-pass: a PR with a decision row and a gate row keeps both" {
    PR_JSON='[{"number":9,"title":"feat: y","state":"open","merged_at":null,"body":"Decide whether to enable the surface expansion."}]'
    GATE_PENDING=$'9\ttouches gate-protected .review-bots.yaml, lacks label gate-change-approved'
    run owner_decisions_collect
    [[ "$output" == *"Approve gate change on PR owner/repo#9"* ]]
    [[ "$output" == *"surface expansion"* ]]
}

@test "should-pass: an exact repeat of the same decision kind is still suppressed" {
    GATE_PENDING=$'9\twhy one\n9\twhy two'
    run owner_decisions_collect
    [ "$(grep -o 'Approve gate change on PR owner/repo#9' <<<"$output" | wc -l)" -eq 1 ]
}
