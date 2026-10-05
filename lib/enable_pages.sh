#!/bin/bash
#
# lib/enable_pages.sh
#
# Point GitHub Pages at the gh-pages branch (mike's deploy target) - once.
# Guarded: no-op with a message until gh-pages exists (the first docs deploy
# creates it). Idempotent: probes whether a Pages site exists to choose
# POST (create) vs PUT (update). Never fails the caller (gh missing, not
# authenticated, or not repo-admin all warn and return 0).
# Ported from blueprintx templates/python-common/bin/enable_pages.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

PAGES_BRANCH="gh-pages"

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
    repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
    if [ -z "$repo" ]; then
        print_status "warning" "No GitHub remote resolved - skipping Pages enablement"
        return 0
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
