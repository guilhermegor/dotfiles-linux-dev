#!/bin/bash
# ai_clients/claude/hooks/lib/shipped_check.sh
#
# Shared "was this already shipped" gate for s:intake-shipped (dotfiles-linux-dev#427,
# parent #422). Same contract shape as review_thread_gate.sh / roadmap_unblock.sh:
# one function, two globals, fail-closed on any read error.
#
# Why a script and not a prose-only skill: the two measured failures (blueprintx,
# 2026-09-20) were both mechanical, not judgment calls. (1) PR #509 shipped #355's
# content and merged with closingIssuesReferences = [] -- the GitHub link is
# reliable evidence of PRESENCE, never of absence, so it can only ever be
# supplementary. (2) Two branches sat 5 and 2 commits ahead of origin/main,
# indistinguishable by ancestry/diff/ls-remote from real unrescued work; a single
# content probe against the repo's default branch settled both instantly. What
# this script does NOT decide: which paths/symbols a given issue actually
# promises -- that extraction is s:intake-shipped's job, never hardcoded here.
#
# Contract: call `shipped_check ISSUE_NUM OWNER/REPO DELIVERABLE [DELIVERABLE...]`
# The default branch is resolved locally via refs/remotes/origin/HEAD -- never
# hardcoded to origin/master, since blueprintx (this gate's own motivating case)
# defaults to main. A DELIVERABLE is a path (existence probe) or `path::pattern`
# (grep the path's content on that branch for an extended regex -- e.g. a gate
# wired into a CI yaml, not only a file that exists).
# Sets two globals, returns nothing meaningful (check SHIPPED_STATUS):
#   SHIPPED_STATUS = SHIPPED | OPEN | UNKNOWN
#   SHIPPED_DETAIL = evidence: the link check, one PRESENT/MISSING line per
#                    deliverable, and a present/missing tally
# shellcheck disable=SC2034 # both are read by every caller after the call returns
set -u

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "shipped_check.sh is meant to be sourced, not executed." >&2
    exit 1
fi

# _shipped_probe_one BASE_REF DELIVERABLE
# Content-tests one deliverable against BASE_REF (the repo's resolved default
# branch, e.g. origin/master or origin/main). Never merge-base, ls-remote, or
# diff-emptiness -- see SKILL.md's table for why each of those lies about a
# squash-merged or delete-on-merge branch.
#
# Returns three states, not two: 0 PRESENT, 1 MISSING (confirmed absent --
# git's own stderr says so), 2 UNKNOWN (git failed for any other reason: a
# corrupt object, an unfetched pack, a bad path traversal). `set -u` with no
# `pipefail` means a pipeline's status is the LAST command's (grep's), so
# git's own exit code is captured separately here rather than trusted through
# a pipe -- a `git show`/`cat-file` operational failure must never collapse
# into "missing", which the caller would read as evidence the deliverable was
# never shipped (dotfiles-linux-dev#427 PR #460 review).
_shipped_probe_one() {
    local base_ref="$1" deliverable="$2" path pattern
    local errfile content git_status stderr_msg
    path="${deliverable%%::*}"
    errfile="$(mktemp)" || { echo "UNKNOWN $path (mktemp failed)"; return 2; }

    if [[ "$deliverable" == *"::"* ]]; then
        pattern="${deliverable#*::}"
        content="$(git show "$base_ref:$path" 2>"$errfile")"
        git_status=$?
        stderr_msg="$(cat "$errfile")"
        rm -f "$errfile"
        if (( git_status != 0 )); then
            if [[ "$stderr_msg" == *"does not exist in"* ]]; then
                echo "MISSING $path (no match for /$pattern/)"
                return 1
            fi
            echo "UNKNOWN $path (git show failed: $stderr_msg)"
            return 2
        fi
        if grep -qE "$pattern" <<<"$content"; then
            echo "PRESENT $path (matches /$pattern/)"
            return 0
        fi
        echo "MISSING $path (no match for /$pattern/)"
        return 1
    fi

    git cat-file -e "$base_ref:$path" 2>"$errfile"
    git_status=$?
    stderr_msg="$(cat "$errfile")"
    rm -f "$errfile"
    if (( git_status == 0 )); then
        echo "PRESENT $path"
        return 0
    fi
    if [[ "$stderr_msg" == *"does not exist in"* ]]; then
        echo "MISSING $path"
        return 1
    fi
    echo "UNKNOWN $path (git cat-file failed: $stderr_msg)"
    return 2
}

shipped_check() {
    local issue_num="$1" repo="$2"
    shift 2
    local -a deliverables=("$@")
    SHIPPED_STATUS="UNKNOWN"
    SHIPPED_DETAIL=""

    # Resolve the repo's actual default branch via the remote-tracking HEAD
    # symref -- never a hardcoded origin/master, which silently returns
    # UNKNOWN (fails closed, but uselessly) on a repo whose default is
    # origin/main, and could inspect a stale/wrong ref if one happened to
    # exist locally under that name.
    local base_ref
    base_ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
    if [[ -z "$base_ref" ]]; then
        SHIPPED_DETAIL="origin/HEAD not resolvable locally -- run 'git remote set-head origin -a' or fetch first"
        return
    fi
    if ! git rev-parse --verify -q "${base_ref}^{commit}" >/dev/null; then
        SHIPPED_DETAIL="$base_ref not resolvable locally -- fetch it first"
        return
    fi

    if (( ${#deliverables[@]} == 0 )); then
        SHIPPED_DETAIL="no deliverables supplied -- nothing to content-test"
        return
    fi

    # closingIssuesReferences over is:pr WITHOUT is:open: a merged PR can close
    # the issue with an empty link (measured on #509), so this is supplementary
    # evidence only, reported alongside the content probe -- never the deciding
    # signal, and never restricted to is:open (a merged PR is never "open").
    local link_json
    if ! link_json="$(gh pr list --repo "$repo" --search "$issue_num" --state all \
            --json number,state,closingIssuesReferences --limit 50 2>/dev/null)"; then
        SHIPPED_DETAIL="gh pr list failed -- cannot read link evidence"
        return
    fi
    local linked_merged
    if ! linked_merged="$(jq -r --argjson n "$issue_num" \
            '[.[] | select(.state=="MERGED" and (.closingIssuesReferences[]?.number==$n))][0].number // empty' \
            <<<"$link_json" 2>/dev/null)"; then
        SHIPPED_DETAIL="jq could not parse gh pr list output"
        return
    fi

    local present=0 missing=0 lines="" d line
    for d in "${deliverables[@]}"; do
        if line="$(_shipped_probe_one "$base_ref" "$d")"; then
            present=$((present + 1))
        else
            missing=$((missing + 1))
        fi
        lines+="$line"$'\n'
    done

    local link_note="no merged PR linked this issue via closingIssuesReferences"
    [[ -n "$linked_merged" ]] && link_note="merged PR #$linked_merged links this issue via closingIssuesReferences"

    if (( missing == 0 )); then
        SHIPPED_STATUS="SHIPPED"
    else
        # Present > 0 here is "partially shipped (N of M)" -- s:intake-shipped
        # derives that wording from the present/missing tally below; the gate
        # itself only distinguishes shipped-in-full from not-shipped-in-full.
        SHIPPED_STATUS="OPEN"
    fi
    SHIPPED_DETAIL="$link_note"$'\n'"${lines%$'\n'}"$'\n'"present=$present missing=$missing of $((present + missing))"
}
