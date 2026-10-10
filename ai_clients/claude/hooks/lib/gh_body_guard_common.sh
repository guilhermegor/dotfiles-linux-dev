#!/bin/bash
# Shared primitive for gh body-editing guards (pr_template_guard.sh, issue_template_guard.sh):
# find and tokenize a `gh <noun> create|edit` invocation inside a raw shell command string.
#
# Extracted so both guards share ONE implementation of command matching, body extraction, and
# repo-target resolution instead of each carrying its own copy that drifts the way
# commit_command_matcher.sh's header already documents for the three commit guards
# (dotfiles-linux-dev#324) — and the way this exact file drifted from its own regex-based predecessor
# (CodeRabbit review on PR #371, dotfiles-dev): a regex anchored to the START of the command
# string, matched against raw un-tokenized text, missed every invocation chained after `;`,
# `&&`, `||`, `|`, `&`, or a newline, and could be fooled by the SAME flag text appearing inside
# an unrelated quoted argument (e.g. `--repo` mentioned inside `--title`). Real argv parsing
# (gh_cmd_match.py) fixes both classes of bug at once, instead of patching the regex per case.
#
# Deliberately NOT extracted: the BLOCKED/message-formatting functions. Their wording differs
# meaningfully between "PR body" and "issue body" and each caller's existing tests are pinned to
# its own exact text — a shared parameterized formatter would risk both for a few lines of prose.

set -u

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "gh_body_guard_common.sh is meant to be sourced, not executed." >&2
    exit 1
fi

_GH_BODY_GUARD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# $1: owner/name. True when the cwd checkout's `origin` URL (github.com only, https or ssh, with
# or without .git or a trailing slash) names that repo, compared case-insensitively. Lets both
# guards accept the cwd checkout for a `--repo` target even when its directory name differs from
# the repo name (dotfiles-linux-dev#701).
origin_names_repo() {
    local url slug
    url="$(git remote get-url origin 2>/dev/null)" || return 1
    url="${url%/}"
    url="${url%.git}"
    # Anchored to github.com: a gitlab/GHE remote or a nested path must not match a github.com
    # target.
    slug="$(printf '%s' "$url" | sed -nE 's#^([a-z+]+://)?([^@/]+@)?github\.com[:/]([^/:]+/[^/:]+)$#\3#p')"
    [[ -n "$slug" && "${slug,,}" == "${1,,}" ]]
}

# Run gh_cmd_match.py against $1 (the raw command string) for $2 (noun: "pr" or "issue") and
# populate these globals:
#   GH_MATCHED       "true"/"false" — was a `[rtk] gh <noun> create|edit` segment found at all
#   GH_REPO          --repo/-R value, or empty
#   GH_HAS_BODY      "true"/"false" — was --body/-b given
#   GH_BODY          --body/-b value, or empty
#   GH_HAS_BODY_FILE "true"/"false" — was --body-file/-F given
#   GH_BODY_FILE     --body-file/-F value, or empty
#   GH_LABELS        array of --label/-l/--add-label values (comma-separated values split out)
#
# Returns 1 if python3 is unavailable or the command could not be tokenized at all (an
# unbalanced quote or unterminated heredoc) — the caller MUST treat that as "unknown" and fail
# OPEN (exit 0), never as "no gh command found", since a verdict from unparseable input is a
# guess, not a check.
resolve_gh_command() {
    local command="$1" noun="$2" json rc
    GH_MATCHED=false GH_REPO="" GH_HAS_BODY=false GH_BODY=""
    GH_HAS_BODY_FILE=false GH_BODY_FILE=""
    GH_LABELS=()

    command -v python3 >/dev/null 2>&1 || return 1

    json="$(printf '%s' "$command" | python3 "$_GH_BODY_GUARD_LIB_DIR/gh_cmd_match.py" "$noun" 2>/dev/null)"
    rc=$?
    [[ $rc -eq 0 && -n "$json" ]] || return 1

    GH_MATCHED="$(printf '%s' "$json" | jq -r '.matched' 2>/dev/null)"
    [[ "$GH_MATCHED" == "true" ]] || return 0

    # These globals are consumed by the sourcing guard script (pr_template_guard.sh /
    # issue_template_guard.sh), not within this file — shellcheck can't see across a `source`,
    # the same reason SC1091 is excluded repo-wide; SC2034 is disabled per-line here instead.
    # shellcheck disable=SC2034
    GH_REPO="$(printf '%s' "$json" | jq -r '.repo // empty')"
    # shellcheck disable=SC2034
    GH_HAS_BODY="$(printf '%s' "$json" | jq -r '.has_body')"
    # shellcheck disable=SC2034
    GH_BODY="$(printf '%s' "$json" | jq -r '.body // empty')"
    # shellcheck disable=SC2034
    GH_HAS_BODY_FILE="$(printf '%s' "$json" | jq -r '.has_body_file')"
    # shellcheck disable=SC2034
    GH_BODY_FILE="$(printf '%s' "$json" | jq -r '.body_file // empty')"
    # shellcheck disable=SC2034
    mapfile -t GH_LABELS < <(printf '%s' "$json" | jq -r '.labels[]?')
    return 0
}
