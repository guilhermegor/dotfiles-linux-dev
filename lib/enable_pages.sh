#!/bin/bash
#
# lib/enable_pages.sh
#
# Point GitHub Pages at the gh-pages branch (mike's deploy target) - once.
# Guarded: no-op with a message until gh-pages exists (the first docs deploy
# creates it). Idempotent: probes whether a Pages site exists to choose
# POST (create) vs PUT (update). gh missing, not authenticated, or not
# repo-admin warn and return 0; an unresolvable repo is an error (non-zero),
# never read as a routine skip (#662).
# Ported from blueprintx templates/python-common/bin/enable_pages.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

PAGES_BRANCH="gh-pages"

# owner/repo from the origin URL (https, git@github.com:, ssh://), with no API
# call: `gh repo view` is GraphQL, and a rate-limited empty answer was read as
# "no remote" (#662). `gh repo view` is only the fallback for a missing origin.
resolve_repo() {
    local url
    if url="$(git remote get-url origin 2>/dev/null)"; then
        url="${url%.git}"
        case "$url" in
            *github.com[:/]*/*) printf '%s\n' "${url#*github.com[:/]}"; return 0 ;;
        esac
    fi
    gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null
}

enable_pages() {
    if ! command -v gh >/dev/null 2>&1; then
        print_status "warning" "gh CLI not found - skipping Pages enablement"
        return 0
    fi
    if ! gh auth status >/dev/null 2>&1; then
        print_status "warning" "gh not authenticated - run 'gh auth login', then 'make enable_pages'"
        return 0
    fi

    local repo
    repo="$(resolve_repo)" || repo=""
    if [ -z "$repo" ]; then
        print_status "error" "Could not resolve the GitHub repo (no github.com origin, and gh repo view failed) - Pages not configured"
        return 1
    fi

    if ! gh api "repos/$repo/branches/$PAGES_BRANCH" >/dev/null 2>&1; then
        print_status "info" "No '$PAGES_BRANCH' branch yet - leaving Pages untouched (merge to master, let the docs deploy create it, then re-run 'make enable_pages')"
        return 0
    fi

    local method="POST" current=""
    current="$(gh api "repos/$repo/pages" --jq '.source.branch' 2>/dev/null)" && method="PUT"
    if [ "$method" = "PUT" ] && [ "$current" = "$PAGES_BRANCH" ]; then
        print_status "success" "Pages already serves '$PAGES_BRANCH' for $repo - nothing to do"
        return 0
    fi

    if printf '{"source":{"branch":"%s","path":"/"}}' "$PAGES_BRANCH" \
        | gh api -X "$method" "repos/$repo/pages" --input - >/dev/null 2>&1; then
        print_status "success" "GitHub Pages now serves '$PAGES_BRANCH' for $repo"
    else
        print_status "warning" "Could not set the Pages source for $repo (needs repo-admin rights) - set it in Settings -> Pages"
    fi
}

main() {
    enable_pages
}

main "$@"
