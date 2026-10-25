#!/bin/bash
# Budget gate + per-repo plan cache for the main-session Stop guards (dotfiles-linux-dev#814).
#
# Stop runs after EVERY main-session turn, including one-line acknowledgements. Each run used to
# re-plan from scratch (dozens of GraphQL points a turn) and the #445 latch never covered it, so a
# long /dev-loop session drained the shared 5000/h GraphQL bucket in minutes — leaving none for
# `gh pr merge --auto`, the review-thread gate, or closingIssuesReferences.
#
#   stop_budget_gate    — latch active, or GraphQL under a floor => print BUDGET-LOW once, return 1.
#                         The caller PASSES (exit 0): never block a turn on a blind board.
#   stop_plan_cache_*   — one planner result per repo, reused until a TTL lapses or the transcript
#                         shows something that changes the board (push, PR open/merge, Agent dispatch).
set -u

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	echo "stop_budget.sh is meant to be sourced, not executed." >&2
	exit 1
fi

# shellcheck source=gh_budget.sh
source "$(dirname "${BASH_SOURCE[0]}")/gh_budget.sh"

# stop_budget_gate
# Order matters: the latch is a file read (no gh); only an unlatched call spends one FREE
# `gh api rate_limit` read, and a floor breach writes the latch so later Stops skip even that.
stop_budget_gate() {
	local floor="${STOP_GRAPHQL_FLOOR:-100}" json remaining reset now until
	if ! gh_budget_latch_active; then
		json="$(gh api rate_limit 2>/dev/null)" || return 0 # unreadable => not proven low
		remaining="$(printf '%s' "$json" | jq -r '.resources.graphql.remaining // empty' 2>/dev/null)"
		reset="$(printf '%s' "$json" | jq -r '.resources.graphql.reset // empty' 2>/dev/null)"
		[[ "$remaining" =~ ^[0-9]+$ ]] && [[ "$reset" =~ ^[0-9]+$ ]] || return 0
		[ "$remaining" -lt "$floor" ] || return 0
		now="$(date +%s)"
		gh_budget_latch_write "$((reset > now ? reset - now : 45))" || true
	fi
	until="$(cat "$(gh_budget_latch_path)" 2>/dev/null)"
	# Once per latch window: the marker remembers which reset was already announced.
	if [ "$(cat "$(gh_budget_latch_path).noticed" 2>/dev/null)" != "$until" ]; then
		local when="soon"
		[[ "$until" =~ ^[0-9]+$ ]] && when="$(date -u -d "@$until" +%H:%MZ 2>/dev/null)"
		echo "BUDGET-LOW (resets $when) — Stop guard skipped, not blocking (dotfiles-linux-dev#814)." >&2
		printf '%s\n' "$until" >"$(gh_budget_latch_path).noticed" 2>/dev/null || true
	fi
	return 1
}

# stop_plan_cache_dir CWD — per repo, shared by every worktree of it.
stop_plan_cache_dir() {
	local common
	common="$(cd "$1" 2>/dev/null && /usr/bin/git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
	printf '%s\n' "$common/stop-plan-cache"
}

# _stop_plan_cache_key NAME TRANSCRIPT — one entry per session: the line offset below is only
# meaningful against the transcript that produced it. Cross-session staleness is bounded by the
# TTL plus the claims-registry check in stop_plan_cache_read.
_stop_plan_cache_key() {
	local sid
	sid="$(basename "$2" .jsonl)"
	printf '%s.%s\n' "$1" "${sid//[^A-Za-z0-9_-]/_}"
}

# stop_plan_cache_read NAME CWD TRANSCRIPT
# Prints the cached plan and returns 0 on a fresh hit. Meta file: "<write epoch> <transcript lines>".
# Invalid when older than the TTL, or when the transcript lines added since the write mention a
# push, a PR create/merge, or an Agent dispatch. The grep is deliberately loose — over-invalidating
# costs one re-plan, under-invalidating serves a stale board.
stop_plan_cache_read() {
	local name dir ttl="${STOP_PLAN_CACHE_TTL:-180}" wrote lines
	name="$(_stop_plan_cache_key "$1" "$3")"
	dir="$(stop_plan_cache_dir "$2")" || return 1
	[ -r "$dir/$name.json" ] && [ -r "$dir/$name.meta" ] || return 1
	read -r wrote lines <"$dir/$name.meta"
	[[ "$wrote" =~ ^[0-9]+$ ]] && [[ "$lines" =~ ^[0-9]+$ ]] || return 1
	[ "$(($(date +%s) - wrote))" -lt "$ttl" ] || return 1
	[ "$(wc -l <"$3")" -ge "$lines" ] || return 1
	# Another session claiming files changes the board without touching this transcript.
	[ ! "$dir/../dispatch-claims.tsv" -nt "$dir/$name.meta" ] || return 1
	tail -n "+$((lines + 1))" "$3" |
		grep -qE '"name": *"Agent"|git push|gh (pr|issue|label)|gh api [^"]*(pulls|issues|labels)' && return 1
	cat "$dir/$name.json"
}

# stop_plan_cache_write NAME CWD TRANSCRIPT PLAN — callers pass only a plan they validated.
stop_plan_cache_write() {
	local name dir
	name="$(_stop_plan_cache_key "$1" "$3")"
	dir="$(stop_plan_cache_dir "$2")" || return 0
	mkdir -p "$dir" 2>/dev/null || return 0
	printf '%s' "$4" >"$dir/$name.json.$$" && mv -f "$dir/$name.json.$$" "$dir/$name.json"
	printf '%s %s\n' "$(date +%s)" "$(wc -l <"$3")" >"$dir/$name.meta.$$" && mv -f "$dir/$name.meta.$$" "$dir/$name.meta"
}
