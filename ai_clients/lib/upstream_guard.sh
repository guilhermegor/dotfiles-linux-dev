#!/bin/bash
#
# ai_clients/lib/upstream_guard.sh
#
# Refuses to deploy from a checkout that is behind its upstream (#643): a
# deploy from a stale master silently reverted a merged fix in ~/.claude.
# Sourced by ai_clients/main.sh and every client main.sh.
#
#   ai_clients_upstream_guard [repo_dir]
#     0  up to date or ahead, no upstream to compare, or fetch failed (warns)
#     1  behind upstream (refused)
#
# Escape hatch: AI_CLIENTS_ALLOW_STALE=1 downgrades the refusal to a warning.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "upstream_guard.sh is meant to be sourced, not executed." >&2
    exit 1
fi

ai_clients_upstream_guard() {
    local repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

    # The router already checked; its child client scripts need not refetch.
    [[ -n "${AI_CLIENTS_UPSTREAM_CHECKED:-}" ]] && return 0

    local upstream
    if ! upstream="$(git -C "$repo" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)"; then
        print_status "warning" "No upstream for $repo; skipping stale-checkout check"
        return 0
    fi

    export AI_CLIENTS_UPSTREAM_CHECKED=1

    # Offline must not wedge a deploy: warn and carry on with the local state.
    if ! timeout 20 git -C "$repo" fetch --quiet 2>/dev/null; then
        print_status "warning" "Could not fetch $upstream; staleness check skipped"
        return 0
    fi

    local behind
    behind="$(git -C "$repo" rev-list --count "HEAD..$upstream")"
    [[ "$behind" -eq 0 ]] && return 0

    if [[ "${AI_CLIENTS_ALLOW_STALE:-}" == "1" ]]; then
        print_status "warning" "Checkout is $behind commit(s) behind $upstream; deploying anyway (AI_CLIENTS_ALLOW_STALE=1)"
        return 0
    fi

    print_status "error" "Checkout is $behind commit(s) behind $upstream; deploying would revert merged fixes."
    print_status "info" "Run 'git pull', or set AI_CLIENTS_ALLOW_STALE=1 to override."
    return 1
}
