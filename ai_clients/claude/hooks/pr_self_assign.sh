#!/bin/bash
# PostToolUse (Bash matcher) hook: after a `gh pr create` that succeeded, assign the PR to its
# author (`@me`) so every PR opened in a session is findable via `gh pr list --assignee @me` and
# by assignee-driven board automation, instead of depending on whoever composed the command that
# time to remember `--assignee` (dotfiles-linux-dev#153).
#
# Match the VERB, then resolve the PR via gh — never scrape a flag out of the raw command string
# (hook-command-string-scraping-fragile, same rule kanban_lifecycle.sh already documents). The one
# exception is an explicit `--repo owner/repo` on the create command itself: honoured verbatim so
# `gh pr view`/`gh pr edit` resolve the SAME repo the PR was actually opened in, rather than
# whatever the cwd's `origin` happens to be.
#
# `--draft` PRs are included on purpose: a draft is still yours in flight, and excluding it would
# make "what am I holding?" wrong for exactly the PRs still being iterated on.
#
# Hook I/O contract: PostToolUse, so `gh pr create` already ran — this never blocks it. It is a
# convenience, not a gate (a guard that blocks PR creation over an assignment nicety would be worse
# than no hook at all), so it fails OPEN AND SILENT everywhere it cannot apply or cannot assign: no
# gh/jq, no PR resolvable for HEAD (no push rights, a fork, network down), or the `gh pr edit` call
# itself failing. Never exits non-zero, never writes to stderr, never blocks.

set -u

command -v jq >/dev/null 2>&1 || exit 0
command -v gh >/dev/null 2>&1 || exit 0

main() {
    local payload tool command repo_flag view number

    payload="$(cat)"
    tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"
    [[ "$tool" == "Bash" ]] || exit 0

    command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    [[ -n "$command" ]] || exit 0

    printf '%s' "$command" \
        | grep -Eq '^[[:space:]]*(rtk[[:space:]]+)?gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)' \
        || exit 0

    repo_flag="$(repo_from_command "$command")"

    view="$(gh_repo pr view "$repo_flag" --json number 2>/dev/null)" || exit 0
    number="$(printf '%s' "$view" | jq -r '.number // empty' 2>/dev/null)"
    [[ -n "$number" ]] || exit 0     # no PR resolvable → nothing to assign

    gh_repo pr edit "$repo_flag" "$number" --add-assignee @me >/dev/null 2>&1 || exit 0
}

repo_from_command() {
    # Echo the value of an explicit `--repo`/`--repo=` flag on the create command, or nothing.
    printf '%s' "$1" | grep -oE -- '--repo[= ]+[^ ]+' | head -n1 | sed -E 's/--repo[= ]+//'
}

gh_repo() {
    # Run `gh <args...>`, inserting `--repo <repo_flag>` right after the args if it was given.
    # repo_flag is always the second-to-last positional arg here (caller convention below).
    local sub="$1" verb="$2" repo="$3"
    shift 3
    if [[ -n "$repo" ]]; then
        gh "$sub" "$verb" --repo "$repo" "$@"
    else
        gh "$sub" "$verb" "$@"
    fi
}

main "$@"
