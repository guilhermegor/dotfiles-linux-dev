#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/orphaned_issues.sh (dotfiles-linux-dev#418).
# Both halves of the gate contract (ai_clients/CLAUDE.md, "A gate's contract"): success returns
# a usable, non-empty answer on a fixture that provably has content, and the fail-closed path
# leaves every global empty. All `gh` calls are stubbed -- never a live token.

setup() {
    source "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/orphaned_issues.sh"
}

# --- _orphan_merged_pr_mentions: the mention-without-link extraction ----------------------------

@test "a merged PR mentioning an issue by title, with no closing link, is reported" {
    gh() {
        case "$*" in
            "api graphql -f query="*)
                cat <<'JSON'
{"data":{"search":{"pageInfo":{"hasNextPage":false,"endCursor":null},
"nodes":[{"number":509,"title":"identifier-masking gate for #355","body":"",
"headRefName":"feat/509-masking","closingIssuesReferences":{"nodes":[]}}]}}}
JSON
                ;;
            *) return 1 ;;
        esac
    }
    run _orphan_merged_pr_mentions o/r
    [ "$status" -eq 0 ]
    [[ "$output" == $'355\t509\t' ]]
}

@test "a merged PR that DOES declare the closing link is not reported" {
    gh() {
        case "$*" in
            "api graphql -f query="*)
                cat <<'JSON'
{"data":{"search":{"pageInfo":{"hasNextPage":false,"endCursor":null},
"nodes":[{"number":292,"title":"fix things","body":"Closes #135",
"headRefName":"fix/292","closingIssuesReferences":{"nodes":[{"number":135}]}}]}}}
JSON
                ;;
            *) return 1 ;;
        esac
    }
    run _orphan_merged_pr_mentions o/r
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a branch name carrying the issue number is caught even with no title/body mention" {
    gh() {
        case "$*" in
            "api graphql -f query="*)
                cat <<'JSON'
{"data":{"search":{"pageInfo":{"hasNextPage":false,"endCursor":null},
"nodes":[{"number":467,"title":"alembic parity","body":"",
"headRefName":"refactor/migrations-folder-alembic-parity-373-381",
"closingIssuesReferences":{"nodes":[{"number":373}]}}]}}}
JSON
                ;;
            *) return 1 ;;
        esac
    }
    run _orphan_merged_pr_mentions o/r
    [ "$status" -eq 0 ]
    # 373 is declared closed and must be excluded; 381 is mentioned only by the branch and
    # must surface -- the exact blueprintx#381/PR#467 shape from the issue's own measurement.
    [[ "$output" == $'381\t467\t373' ]]
}

@test "a read failure fails the extraction closed" {
    gh() { return 1; }
    run _orphan_merged_pr_mentions o/r
    [ "$status" -eq 1 ]
}

# --- gate_orphaned_issues: the top-level contract, not just its sub-helper ----------------------

@test "gate_orphaned_issues: success sets ok with a non-empty, parseable candidate line" {
    gh() {
        case "$*" in
            "api repos/o/r --jq .default_branch") echo master ;;
            "issue list --repo o/r --state open --limit 501 --json number --jq .[].number")
                printf '355\n999\n' ;;
            "api graphql -f query="*)
                cat <<'JSON'
{"data":{"search":{"pageInfo":{"hasNextPage":false,"endCursor":null},
"nodes":[{"number":509,"title":"identifier-masking gate for #355","body":"",
"headRefName":"feat/509-masking","closingIssuesReferences":{"nodes":[]}}]}}}
JSON
                ;;
            *) return 1 ;;
        esac
    }

    gate_orphaned_issues o r
    local rc=$?

    [ "$rc" -eq 0 ]
    [ "$ORPHAN_STATUS" = "ok" ]
    [[ "$ORPHAN_REPORT" == "#355 may already be shipped by PR #509 (mentions #355, closingIssuesReferences=none) -- verify on master" ]]
}

@test "gate_orphaned_issues: a mentioned number that is not an open issue is not reported" {
    gh() {
        case "$*" in
            "api repos/o/r --jq .default_branch") echo master ;;
            # 355 already closed elsewhere -- not in the open-issue set.
            "issue list --repo o/r --state open --limit 501 --json number --jq .[].number")
                printf '999\n' ;;
            "api graphql -f query="*)
                cat <<'JSON'
{"data":{"search":{"pageInfo":{"hasNextPage":false,"endCursor":null},
"nodes":[{"number":509,"title":"identifier-masking gate for #355","body":"",
"headRefName":"feat/509-masking","closingIssuesReferences":{"nodes":[]}}]}}}
JSON
                ;;
            *) return 1 ;;
        esac
    }

    gate_orphaned_issues o r
    local rc=$?

    [ "$rc" -eq 0 ]
    [ "$ORPHAN_STATUS" = "ok" ]
    [ -z "$ORPHAN_REPORT" ]
}

@test "gate_orphaned_issues: a read failure fails the whole gate closed, no partial answer" {
    gh() {
        case "$*" in
            "api repos/o/r --jq .default_branch") echo master ;;
            "issue list --repo o/r --state open --limit 501 --json number --jq .[].number")
                printf '355\n' ;;
            "api graphql -f query="*) echo "gh: API rate limit exceeded (HTTP 403)" >&2; return 1 ;;
            *) return 1 ;;
        esac
    }

    local rc=0
    gate_orphaned_issues o r || rc=$?

    [ "$rc" -eq 1 ]
    [ "$ORPHAN_STATUS" = "unknown" ]
    [ -z "$ORPHAN_REPORT" ]
}

# --- truncation and pagination fail closed (PR #471 review) -------------------------------------
#
# All three assert the SAME contract from different angles: a set this gate cannot fully
# enumerate must answer unknown, never a partial `ok`. A partial `ok` is the worse failure
# because nothing downstream distinguishes "no orphans" from "did not look at all of them".

@test "a merged-PR set past the search ceiling is unknown, never a partial answer" {
    ORPHAN_SEARCH_CEILING=2
    gh() {
        case "$*" in
            "api graphql -f query="*)
                # issueCount is the TOTAL matches, not this page: 3 > the ceiling of 2, so the
                # tail is unreachable however far we paginate, even though page 1 parses fine
                # and carries a real candidate.
                cat <<'JSON'
{"data":{"search":{"issueCount":3,"pageInfo":{"hasNextPage":false,"endCursor":null},
"nodes":[{"number":509,"title":"masks #355","body":"",
"headRefName":"feat/509","closingIssuesReferences":{"nodes":[]}}]}}}
JSON
                ;;
            *) return 1 ;;
        esac
    }
    run _orphan_merged_pr_mentions o/r
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "hasNextPage true with an unreadable cursor fails closed, never loops on page one" {
    gh() {
        case "$*" in
            "api graphql -f query="*)
                # The server says there is more but gives no cursor to reach it. Without the
                # guard the next iteration re-requests page 1 with the same empty cursor --
                # forever. With it, the gate says unknown.
                cat <<'JSON'
{"data":{"search":{"issueCount":1,"pageInfo":{"hasNextPage":true,"endCursor":null},
"nodes":[{"number":509,"title":"masks #355","body":"",
"headRefName":"feat/509","closingIssuesReferences":{"nodes":[]}}]}}}
JSON
                ;;
            *) return 1 ;;
        esac
    }
    run timeout 10 bash -c '
        source "'"$BATS_TEST_DIRNAME"'/../ai_clients/claude/hooks/lib/orphaned_issues.sh"
        gh() {
            cat <<'\''JSON'\''
{"data":{"search":{"issueCount":1,"pageInfo":{"hasNextPage":true,"endCursor":null},
"nodes":[{"number":509,"title":"masks #355","body":"",
"headRefName":"feat/509","closingIssuesReferences":{"nodes":[]}}]}}}
JSON
        }
        _orphan_merged_pr_mentions o/r
    '
    [ "$status" -eq 1 ]
}

@test "gate_orphaned_issues: an open-issue set at the ceiling is unknown, both globals empty" {
    ORPHAN_OPEN_ISSUE_CEILING=2
    gh() {
        case "$*" in
            "api repos/o/r --jq .default_branch") echo master ;;
            # Three come back for a ceiling of two: the real set is larger than we can read,
            # so issue 355 might be open and simply past the cut -- unknowable, not absent.
            "issue list --repo o/r --state open --limit 3 --json number --jq .[].number")
                printf '111\n222\n333\n' ;;
            *) return 1 ;;
        esac
    }

    local rc=0
    gate_orphaned_issues o r || rc=$?

    [ "$rc" -eq 1 ]
    [ "$ORPHAN_STATUS" = "unknown" ]
    [ -z "$ORPHAN_REPORT" ]
}

# --- _orphan_surface_lines / _orphan_surface_present_count: pure helpers (dotfiles-linux-dev#419) ------

@test "_orphan_surface_lines extracts a fenced surface block, dropping the fences" {
    local body
    body="$(printf 'intro text\n```surface\nai_clients/claude/hooks/lib/*.sh\ntests/*.bats\n```\n\nmore text\n')"
    run _orphan_surface_lines "$body"
    [ "$status" -eq 0 ]
    [[ "$output" == $'ai_clients/claude/hooks/lib/*.sh\ntests/*.bats' ]]
}

@test "_orphan_surface_lines on a body with no surface block is empty" {
    run _orphan_surface_lines "just prose, no fenced block"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "_orphan_surface_present_count: every line matches, present equals total" {
    local tree
    tree="$(printf 'a/one.sh\nb/two.sh\nc/three.sh\n')"
    run _orphan_surface_present_count "$tree" "a/one.sh" "b/two.sh"
    [ "$output" = "2 2" ]
}

@test "_orphan_surface_present_count: a glob line matches a tracked path" {
    local tree
    tree="$(printf 'templates/python-common/src/chassis/db_schema/infrastructure/user_handler.py\n')"
    run _orphan_surface_present_count "$tree" 'templates/*/src/chassis/db_schema/infrastructure/*_handler.py'
    [ "$output" = "1 1" ]
}

@test "_orphan_surface_present_count: a missing path is not counted present" {
    local tree
    tree="$(printf 'a/one.sh\n')"
    run _orphan_surface_present_count "$tree" "a/one.sh" "b/never-shipped.sh"
    [ "$output" = "1 2" ]
}

# --- gate_orphaned_surface: the zero-PR-mention direction (dotfiles-linux-dev#419) ---------------------
#
# gate_orphaned_surface composes gate_free_surface (never re-derived) with a content probe, so
# every fixture below stubs BOTH `gh` (free_surface's own calls, plus `gh issue view` for the
# body) and `git` (symbolic-ref + ls-tree against the resolved default branch).

@test "gate_orphaned_surface: a fully-present declared surface with no claiming PR is reported" {
    git() {
        case "$*" in
            "symbolic-ref --quiet --short refs/remotes/origin/HEAD") echo "origin/master" ;;
            "ls-tree -r --name-only origin/master") printf 'seams/otel_logging.py\n' ;;
            *) command git "$@" ;;
        esac
    }
    gh() {
        case "$*" in
            "api repos/o/r --jq .default_branch") echo master ;;
            "pr list --repo o/r --state open --json number,headRefName --limit 200") echo '[]' ;;
            "api repos/o/r/branches --paginate --jq .[].name") echo master ;;
            "api graphql -f query="*) echo '{"data":{"search":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}' ;;
            "issue list --repo o/r --state open --limit 500 --json number --jq .[].number") echo 438 ;;
            "issue view 438 --repo o/r --json body --jq .body")
                printf 'shipped both seams\n```surface\nseams/otel_logging.py\n```\n' ;;
            *) return 1 ;;
        esac
    }

    gate_orphaned_surface o r
    local rc=$?

    [ "$rc" -eq 0 ]
    [ "$ORPHAN_SURFACE_STATUS" = "ok" ]
    [[ "$ORPHAN_SURFACE_REPORT" == "#438 may already be shipped -- declared surface fully present on origin/master, no PR claims it -- verify before closing" ]]
}

@test "gate_orphaned_surface: a partially-present surface is reported as partial, not full" {
    git() {
        case "$*" in
            "symbolic-ref --quiet --short refs/remotes/origin/HEAD") echo "origin/master" ;;
            "ls-tree -r --name-only origin/master") printf 'seams/one.py\n' ;;
            *) command git "$@" ;;
        esac
    }
    gh() {
        case "$*" in
            "api repos/o/r --jq .default_branch") echo master ;;
            "pr list --repo o/r --state open --json number,headRefName --limit 200") echo '[]' ;;
            "api repos/o/r/branches --paginate --jq .[].name") echo master ;;
            "api graphql -f query="*) echo '{"data":{"search":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}' ;;
            "issue list --repo o/r --state open --limit 500 --json number --jq .[].number") echo 355 ;;
            "issue view 355 --repo o/r --json body --jq .body")
                printf '```surface\nseams/one.py\nseams/two.py\n```\n' ;;
            *) return 1 ;;
        esac
    }

    gate_orphaned_surface o r
    local rc=$?

    [ "$rc" -eq 0 ]
    [ "$ORPHAN_SURFACE_STATUS" = "ok" ]
    [[ "$ORPHAN_SURFACE_REPORT" == "#355 partially shipped (1 of 2 surface paths present on origin/master) -- verify before closing" ]]
}

@test "gate_orphaned_surface: an issue with no declared surface block is skipped, not reported" {
    git() {
        case "$*" in
            "symbolic-ref --quiet --short refs/remotes/origin/HEAD") echo "origin/master" ;;
            "ls-tree -r --name-only origin/master") printf 'seams/one.py\n' ;;
            *) command git "$@" ;;
        esac
    }
    gh() {
        case "$*" in
            "api repos/o/r --jq .default_branch") echo master ;;
            "pr list --repo o/r --state open --json number,headRefName --limit 200") echo '[]' ;;
            "api repos/o/r/branches --paginate --jq .[].name") echo master ;;
            "api graphql -f query="*) echo '{"data":{"search":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}' ;;
            "issue list --repo o/r --state open --limit 500 --json number --jq .[].number") echo 999 ;;
            "issue view 999 --repo o/r --json body --jq .body") echo "no surface block here" ;;
            *) return 1 ;;
        esac
    }

    gate_orphaned_surface o r
    local rc=$?

    [ "$rc" -eq 0 ]
    [ "$ORPHAN_SURFACE_STATUS" = "ok" ]
    [ -z "$ORPHAN_SURFACE_REPORT" ]
}

@test "gate_orphaned_surface: an issue already claimed by a PR is excluded from the candidate pool" {
    # Reuses gate_free_surface's own FREE_UNCLAIMED_ISSUES -- an issue closingIssuesReferences
    # already links to a PR never reaches the surface probe at all.
    git() {
        case "$*" in
            "symbolic-ref --quiet --short refs/remotes/origin/HEAD") echo "origin/master" ;;
            "ls-tree -r --name-only origin/master") printf 'seams/one.py\n' ;;
            *) command git "$@" ;;
        esac
    }
    gh() {
        case "$*" in
            "api repos/o/r --jq .default_branch") echo master ;;
            "pr list --repo o/r --state open --json number,headRefName --limit 200") echo '[]' ;;
            "api repos/o/r/branches --paginate --jq .[].name") echo master ;;
            "api graphql -f query="*)
                echo '{"data":{"search":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"closingIssuesReferences":{"nodes":[{"number":355}]}}]}}}' ;;
            "issue list --repo o/r --state open --limit 500 --json number --jq .[].number")
                printf '355\n' ;;
            "issue view "*) echo "must not be called for a claimed issue" ; return 1 ;;
            *) return 1 ;;
        esac
    }

    gate_orphaned_surface o r
    local rc=$?

    [ "$rc" -eq 0 ]
    [ "$ORPHAN_SURFACE_STATUS" = "ok" ]
    [ -z "$ORPHAN_SURFACE_REPORT" ]
}

@test "gate_orphaned_surface: gate_free_surface failing fails the whole gate closed" {
    git() { command git "$@"; }
    gh() { return 1; }

    local rc=0
    gate_orphaned_surface o r || rc=$?

    [ "$rc" -eq 1 ]
    [ "$ORPHAN_SURFACE_STATUS" = "unknown" ]
    [ -z "$ORPHAN_SURFACE_REPORT" ]
}

@test "gate_orphaned_surface: an unresolvable default branch fails closed" {
    git() {
        case "$*" in
            "symbolic-ref --quiet --short refs/remotes/origin/HEAD") return 1 ;;
            *) command git "$@" ;;
        esac
    }
    gh() {
        case "$*" in
            "api repos/o/r --jq .default_branch") echo master ;;
            "pr list --repo o/r --state open --json number,headRefName --limit 200") echo '[]' ;;
            "api repos/o/r/branches --paginate --jq .[].name") echo master ;;
            "api graphql -f query="*) echo '{"data":{"search":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}' ;;
            "issue list --repo o/r --state open --limit 500 --json number --jq .[].number") echo 438 ;;
            *) return 1 ;;
        esac
    }

    local rc=0
    gate_orphaned_surface o r || rc=$?

    [ "$rc" -eq 1 ]
    [ "$ORPHAN_SURFACE_STATUS" = "unknown" ]
    [ -z "$ORPHAN_SURFACE_REPORT" ]
}
