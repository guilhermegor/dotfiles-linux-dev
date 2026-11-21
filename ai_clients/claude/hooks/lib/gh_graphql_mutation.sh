#!/bin/bash
# The one door for GraphQL-ONLY GitHub mutations (dotfiles-linux-dev#1072): the operations that
# have no REST equivalent (arming auto-merge, resolving a review thread, Projects v2 writes).
# Tier order is REST first, this door second, the Chrome extension last; the routing table and the
# Chrome procedure live in skills/gh-api-tiering.md.
#
# Contract: `gh_graphql_mutation OP gh-api-graphql-args...` checks the budget FIRST
# (gh_budget_poll_allowed, which reads the 403 latch - the latch is never re-derived here). Under the
# latch, or when GitHub refuses the call itself, it returns GH_GQL_DEFERRED (75) and prints ONE line
# on stderr naming OP and its GitHub web UI path, instead of a generic failure. It NEVER drives a
# browser: hooks run unattended, and handing the step to the Chrome extension is a decision the
# interactive session makes after reading that line.
#
# Return codes: 0 done (stdout = the call's output) | 75 deferred (latched or refused, see the
# stderr line) | 2 unknown OP (refused, no call made) | any other = the call's own failure,
# stderr passed through. 75 is gh_budget_with_backoff's "rate limited" status: one meaning.
set -u

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	echo "gh_graphql_mutation.sh is meant to be sourced, not executed." >&2
	exit 1
fi

_ggm_dir="${BASH_SOURCE[0]%/*}" # no slash (sourced by bare filename): the dir is cwd
[[ "$_ggm_dir" == "${BASH_SOURCE[0]}" ]] && _ggm_dir=.
# shellcheck source=gh_budget.sh
source "$_ggm_dir/gh_budget.sh"

GH_GQL_DEFERRED=75

# gh_graphql_ui_path OP
# Prints the GitHub web UI path for a GraphQL-only OP; returns 1 for an op not in the table. The
# table is the single source: an op is allowed through the door only when it appears here.
gh_graphql_ui_path() {
	case "$1" in
	enablePullRequestAutoMerge) echo "PR page > merge box > Enable auto-merge > pick method > Confirm" ;;
	resolveReviewThread) echo "PR page > Conversation or Files changed > the thread > Resolve conversation" ;;
	updateProjectV2ItemFieldValue) echo "Project board > the card > edit the field cell (or drag the card to the column)" ;;
	addProjectV2ItemById) echo "Project board > + Add item > search and pick the issue or PR" ;;
	*) return 1 ;;
	esac
}

# _ggm_defer OP WHY - the one deferred line (stderr) and the distinct status.
_ggm_defer() {
	echo "DEFERRED $1: $2 - do it in the GitHub UI: $(gh_graphql_ui_path "$1")" >&2
	return "$GH_GQL_DEFERRED"
}

# gh_graphql_mutation OP ARG...
# ARGs go to `gh api graphql` verbatim (-f query=..., -f id=..., --jq ...).
gh_graphql_mutation() {
	local op="${1:-}" out err_file rc
	[ "$#" -ge 1 ] || {
		echo "gh_graphql_mutation: usage: OP gh-api-graphql-args..." >&2
		return 2
	}
	shift
	if ! gh_graphql_ui_path "$op" >/dev/null; then
		echo "gh_graphql_mutation: '$op' is not a registered GraphQL-only op - use REST" >&2
		return 2
	fi
	if ! gh_budget_poll_allowed; then
		_ggm_defer "$op" "$GH_BUDGET_POLL_REASON"
		return
	fi
	err_file="$(mktemp)" || err_file=/dev/null
	gh_budget_log_spend 0 # one GraphQL request; cost unexposed (#922)
	out="$(gh api graphql "$@" 2>"$err_file")"
	rc=$?
	if [ "$rc" -eq 0 ]; then
		[ "$err_file" = /dev/null ] || rm -f "$err_file"
		printf '%s\n' "$out"
		return 0
	fi
	gh_budget_classify "$(cat "$err_file" 2>/dev/null) $out"
	if gh_budget_is_terminal; then
		gh_budget_latch_write "$(gh_budget_reset_ttl)" || true
		[ "$err_file" = /dev/null ] || rm -f "$err_file"
		_ggm_defer "$op" "GitHub refused the call (rate limit), latched"
		return
	fi
	cat "$err_file" >&2 2>/dev/null
	[ "$err_file" = /dev/null ] || rm -f "$err_file"
	[ -n "$out" ] && printf '%s\n' "$out"
	return "$rc"
}
