#!/bin/bash
# Standalone report (NOT a wired hook) for dotfiles-linux-dev#441: PR-body scratch files that
# pr_template_guard.sh's own error message tells an author to create — `$root/.git-pr-*.md`,
# already git-ignored — accumulate with no lifecycle once the PR is opened or the draft is
# abandoned. This is the "deterministic half" the issue asks for: it finds `.git-pr-*.md`
# files with no corresponding PR, matched by CONTENT (a filename like `issue_rmw.md` tells you
# nothing about which PR it belongs to — matching by name would mis-pair).
#
# Report-only. Never deletes anything (explicit non-goal in #441: "Report first, reap only
# once the matching is trusted"). Fails CLOSED on any uncertainty — gh/jq missing, or the `gh`
# call itself failing (rate limit, network, auth) — every file in that run is UNKNOWN, never
# reported as orphaned. A false "no PR" verdict from a broken read is worse than leaving the
# files alone: it is exactly the mistake a future reaper must never make silently.
#
# Usage: pr_body_orphan_check.sh [repo-root]     (default: git toplevel of the cwd)
set -uo pipefail

# Above this many PRs the scan cannot see the whole history, so it reports UNKNOWN rather
# than calling an unseen PR's scratch file an orphan.
PR_BODY_SCAN_CEILING="${PR_BODY_SCAN_CEILING:-1000}"

main() {
    local root="${1:-}"
    [[ -n "$root" ]] || root="$(git rev-parse --show-toplevel 2>/dev/null)"
    [[ -n "$root" && -d "$root" ]] || { echo "not a git repo: ${1:-.}" >&2; return 1; }

    local -a files
    mapfile -t files < <(find "$root" -maxdepth 1 -iname '.git-pr-*.md' 2>/dev/null | sort)
    if [[ ${#files[@]} -eq 0 ]]; then
        echo "No .git-pr-*.md scratch files found under $root."
        return 0
    fi

    if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        report_unknown "${files[@]}"
        return 0
    fi

    # --repo, derived from $root's OWN remote: the scratch files come from $root, so the PR
    # bodies must come from $root's repository. Without it `gh` resolves the repo from the
    # CALLER's cwd, and a run with an explicit repo-root from elsewhere compares one
    # checkout's files against another repository's PRs.
    local slug
    slug="$(git -C "$root" remote get-url origin 2>/dev/null |
        sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')"
    if [[ -z "$slug" ]]; then
        report_unknown "${files[@]}"
        return 0
    fi

    # Ask for one MORE than the ceiling so a saturated result is detectable: at the cap,
    # older PRs are silently absent and their scratch files would read as orphans. Same
    # fail-closed ceiling shape as orphaned_issues.sh. Measured 2026-09-23: this repo had
    # 476 PRs against the previous hardcoded --limit 200.
    local pr_bodies
    pr_bodies="$(gh pr list --repo "$slug" --state all \
        --limit "$((PR_BODY_SCAN_CEILING + 1))" --json body 2>/dev/null)"
    if [[ $? -ne 0 || -z "$pr_bodies" ]]; then
        report_unknown "${files[@]}"
        return 0
    fi
    local pr_count
    pr_count="$(printf '%s' "$pr_bodies" | jq -r 'length' 2>/dev/null)" || pr_count=""
    if [[ -z "$pr_count" || "$pr_count" -gt "$PR_BODY_SCAN_CEILING" ]]; then
        report_unknown "${files[@]}"
        return 0
    fi

    local -a matched=() unmatched=()
    local f
    for f in "${files[@]}"; do
        if body_has_match "$f" "$pr_bodies"; then
            matched+=("$f")
        else
            unmatched+=("$f")
        fi
    done

    if [[ ${#matched[@]} -gt 0 ]]; then
        echo "MATCHED (content found in an existing PR body — safe to reap later):"
        printf '  %s\n' "${matched[@]}"
    fi
    if [[ ${#unmatched[@]} -gt 0 ]]; then
        echo "NO MATCHING PR FOUND (possibly drafted and abandoned — reported, not deleted):"
        printf '  %s\n' "${unmatched[@]}"
    fi
    return 0
}

# $1: path to a .git-pr-*.md file. $2: `gh pr list --json body` output (a JSON array).
# Normalises whitespace on both sides so a trailing-newline or indentation difference doesn't
# produce a false "no match" — an exact-text match is still the strictest rule that never
# needs live judgment, which is the whole point of a deterministic check.
body_has_match() {
    local file="$1" prs="$2" norm line body_norm
    norm="$(tr -s '[:space:]' ' ' < "$file" | sed -e 's/^ *//' -e 's/ *$//')"
    # `jq -c` (compact) keeps each PR's body on exactly ONE output line, escaping any internal
    # newline as a literal \n — `jq -r` here would instead emit the DECODED body, whose own
    # internal newlines break the while-read loop into one iteration per line of ONE PR body,
    # comparing sentence fragments instead of the whole document.
    while IFS= read -r line; do
        body_norm="$(printf '%s' "$line" | jq -r '.' | tr -s '[:space:]' ' ' | sed -e 's/^ *//' -e 's/ *$//')"
        [[ "$body_norm" == "$norm" ]] && return 0
    done < <(printf '%s' "$prs" | jq -c '.[].body')
    return 1
}

report_unknown() {
    echo "UNKNOWN (could not query gh — never treated as orphaned):"
    printf '  %s\n' "$@"
}

main "$@"
