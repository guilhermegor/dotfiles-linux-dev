#!/bin/bash
# ai_clients/claude/hooks/lib/collision_rerun.sh
#
# s:dev-loop DRAIN helpers for repos with strict up-to-date OFF (dotfiles-linux-dev#1096,
# toolchain half of blueprintx#1286). Without strict, a merge no longer forces every open PR to
# update, so no PR is re-tested against the new main unless something does it. The only PRs worth
# re-testing are those whose files the merge touched; the rest are left alone.
#
#   ruleset_strict OWNER REPO
#       Prints `true`, `false` or `unknown`. Unknown (any read error, no ruleset exposing the
#       flag) must be treated as true by the caller: it keeps the one-merge-per-round drain.
#
#   collision_hits MERGE_FILES < "PR<TAB>PATH" lines
#       Pure. MERGE_FILES is newline-separated; stdin is one `PR<TAB>PATH` line per PR file.
#       Prints each PR number whose files intersect MERGE_FILES, once, ascending.
#
#   collision_rerun OWNER REPO MERGE_SHA
#       Thin REST wrapper: reads the merge's files and every open PR's files, runs
#       collision_hits, calls update-branch on the hits only and prints their numbers; returns 1 after trying every hit if any
#       update-branch failed. A PR whose
#       file list cannot be read counts as a hit (an unknown overlap is not "no overlap").
#       The caller re-reviews a hit only if its own patch fingerprint changed.
set -u

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "collision_rerun.sh is meant to be sourced, not executed." >&2
    exit 1
fi

ruleset_strict() {
    local owner="$1" repo="$2" ids id strict
    ids=$(gh api --paginate "repos/$owner/$repo/rulesets?per_page=100" --jq '.[].id' 2>/dev/null) || { echo unknown; return 0; }
    [ -n "$ids" ] || { echo unknown; return 0; }
    local seen=""
    for id in $ids; do
        strict=$(gh api "repos/$owner/$repo/rulesets/$id" \
            --jq 'select(.enforcement == "active") | [.rules[]? | select(.type == "required_status_checks")
                   | .parameters.strict_required_status_checks_policy] | first | if . == null then "none" else tostring end' 2>/dev/null) \
            || { echo unknown; return 0; }
        case "$strict" in
            true) echo true; return 0 ;;
            false) seen=false ;;
        esac
    done
    echo "${seen:-unknown}"
}

collision_hits() {
    awk -F'\t' -v files="$1" '
        BEGIN { n = split(files, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") m[a[i]] = 1 }
        $2 in m { hit[$1] = 1 }
        END { for (p in hit) print p }
    ' | sort -n
}

collision_rerun() {
    local owner="$1" repo="$2" sha="$3" merged prs pr files rows="" hits rc=0
    merged=$(gh api --paginate "repos/$owner/$repo/commits/$sha?per_page=100" --jq '.files[] | (.filename, (.previous_filename // empty))') || return 1
    prs=$(gh api --paginate "repos/$owner/$repo/pulls?state=open&per_page=100" --jq '.[].number') || return 1
    for pr in $prs; do
        if files=$(gh api --paginate "repos/$owner/$repo/pulls/$pr/files?per_page=100" --jq '.[] | (.filename, (.previous_filename // empty))'); then
            rows+=$(printf '%s\n' "$files" | sed "s/^/$pr\t/")$'\n'
        else
            # unreadable file list: force a hit via a sentinel the merge always "touches"
            merged+=$'\n'"?unreadable-$pr"
            rows+="$pr"$'\t'"?unreadable-$pr"$'\n'
        fi
    done
    hits=$(printf '%s' "$rows" | collision_hits "$merged")
    for pr in $hits; do
        gh api -X PUT "repos/$owner/$repo/pulls/$pr/update-branch" >/dev/null 2>&1 \
            || { echo "update-branch failed for #$pr" >&2; rc=1; }
    done
    [ -z "$hits" ] || printf '%s\n' "$hits"
    return "$rc"
}
