#!/bin/bash
# "Is there anything the dev-loop can act on?" (dotfiles-linux-dev#1003) — the predicate behind
# s:dev-loop's self-disarm. Prints `IDLE` or `ACTIVE`, then one reason line per item examined:
#   `ACTIVE (unknown: <why>)`  any read failure — a wrong IDLE silently stops the loop, so every
#                              unreadable input fails toward continuing.
# IDLE needs ALL of: 0 open PRs (REST), nothing for worktree_fanout.sh to rescue, no live agent
# holding files, and an empty dispatch_plan.py set with every open issue carrying a NAMED blocker
# (`blocked:`, `HITL:`, or a `PARENT:` whose children are still open). UNDECLARED, claimed, hot-file
# and UNKNOWN reasons are actionable or unreadable, never blockers. Nothing here re-derives a gate:
# the worktree walk, liveness and blocker reads are the shared libs'.
#
# Source it and call `loop_idle [repo-dir]`, or run it directly (read-only) from a checkout.
# Exit 0 = IDLE, 1 = ACTIVE. Overrides: LOOP_IDLE_PLANNER (a dispatch_plan.py stand-in, tests).
set -u

LOOP_IDLE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$LOOP_IDLE_LIB_DIR/worktree_fanout.sh"

_loop_idle_say() { # verdict, then reasons
	printf '%s\n' "$1"
	shift
	[ "$#" -eq 0 ] || printf '%s\n' "$@"
}

# One REST call: the newest 100 PRs in fanout_pr_json's shape, so fanout_worktrees still sees
# merged heads (its own reader is GraphQL `gh pr list`, off-limits while the budget is latched).
_loop_idle_pr_json() {
	gh api "repos/$1/pulls?state=all&per_page=100" --jq \
		'[.[] | {headRefName: .head.ref, headRefOid: .head.sha,
		 state: (if .merged_at then "MERGED" elif .state == "open" then "OPEN" else "CLOSED" end)}]'
}

loop_idle() {
	local cwd="${1:-$PWD}" slug open_prs json rescue plan blockers actionable held live
	local -a lines
	local planner="${LOOP_IDLE_PLANNER:-$LOOP_IDLE_LIB_DIR/dispatch_plan.py}"

	slug="$(fanout_repo_slug "$cwd" 2>/dev/null)" || slug=""
	if [ -z "$slug" ]; then
		_loop_idle_say "ACTIVE (unknown: no GitHub origin)"
		return 1
	fi

	open_prs="$(gh api "repos/$slug/pulls?state=open&per_page=1" --jq length 2>/dev/null)"
	if ! [[ "$open_prs" =~ ^[0-9]+$ ]]; then
		_loop_idle_say "ACTIVE (unknown: open-PR count unreadable)"
		return 1
	fi
	if [ "$open_prs" -gt 0 ]; then
		_loop_idle_say "ACTIVE" "open-prs: at least $open_prs open"
		return 1
	fi

	json="$(_loop_idle_pr_json "$slug" 2>/dev/null)"
	if ! printf '%s' "$json" | jq -e 'type=="array"' >/dev/null 2>&1; then
		_loop_idle_say "ACTIVE (unknown: PR list unreadable for the worktree walk)"
		return 1
	fi
	rescue="$(fanout_worktrees "$cwd" 1 "$json" 2>/dev/null | grep -v 'stale revert' || true)"
	if [ -n "$rescue" ]; then
		_loop_idle_say "ACTIVE" "rescue: $(printf '%s' "$rescue" | head -1)"
		return 1
	fi

	if ! plan="$(cd "$cwd" && python3 "$planner" --idle 2>/dev/null)" \
		|| ! printf '%s' "$plan" | jq -e '(.dispatchable|type=="array") and (.excluded|type=="array")' >/dev/null 2>&1; then
		_loop_idle_say "ACTIVE (unknown: dispatch plan unreadable or budget-latched)"
		return 1
	fi
	if [ "$(printf '%s' "$plan" | jq -r '.live_ok')" != "true" ]; then
		_loop_idle_say "ACTIVE (unknown: live-agent liveness unreadable)"
		return 1
	fi
	held="$(printf '%s' "$plan" | jq -r '.live_held | length')"
	if [ "$held" -gt 0 ]; then
		_loop_idle_say "ACTIVE" "live-agent: $held path(s) held by a live worktree"
		return 1
	fi
	live="$(printf '%s' "$plan" | jq -r '[.dispatchable[].issue | "#\(.)"] | join(", ")')"
	if [ -n "$live" ]; then
		_loop_idle_say "ACTIVE" "dispatchable: $live"
		return 1
	fi

	# A named blocker is a reason a person or another repo must clear. "ready to close" parents are
	# actionable; everything else (UNDECLARED, claimed, UNKNOWN, ...) is not a blocker.
	actionable="$(printf '%s' "$plan" | jq -r '.excluded[]
		| select((.reason | test("^(blocked: |HITL: |PARENT: )")) and (.reason | test("ready to close") | not) | not)
		| "#\(.issue): \(.reason | sub(" [(—].*"; ""))"')"
	if [ -n "$actionable" ]; then
		mapfile -t lines <<<"$actionable"
		if printf '%s' "$plan" | jq -e '.excluded[] | select(.reason | test("UNKNOWN|UNREADABLE"))' >/dev/null; then
			_loop_idle_say "ACTIVE (unknown: an open issue's state could not be read)" "${lines[@]}"
		else
			_loop_idle_say "ACTIVE" "${lines[@]}"
		fi
		return 1
	fi

	blockers="$(printf '%s' "$plan" | jq -r '.excluded | sort_by(.issue)[]
		| "#\(.issue): \(.reason | sub(" [(—].*"; ""))"')"
	mapfile -t lines <<<"$blockers"
	if [ -z "$blockers" ]; then
		_loop_idle_say "IDLE" "blocked: 0 open issues"
	else
		_loop_idle_say "IDLE" "${lines[@]}"
	fi
	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	loop_idle "$@"
fi
