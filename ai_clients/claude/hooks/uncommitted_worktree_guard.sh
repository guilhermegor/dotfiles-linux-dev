#!/bin/bash
# Stop hook: refuse to end the turn while the worktree has uncommitted changes.
#
# dotfiles-linux-dev#167's "commit-early" mechanism, enforcement half. The measured
# failure: three subagents were killed mid-session holding 662, 694, and 256
# lines of uncommitted work — rescued only because a human happened to notice
# before the worktree was discarded. The loss was never caused by running out
# of budget; it was caused by work sitting uncommitted until the very end. A
# prose "commit early" rule in agent-brief guidance is the probabilistic half
# of the fix; this hook is the deterministic half — it cannot forget to check.
#
# ⚠️ /usr/bin/git, never the rtk proxy: a clean tree can come back through the
# proxy as the literal string "ok", which downstream tooling has miscounted
# as 1 uncommitted file. Judging git state through anything but the real
# binary is the exact trap dotfiles-linux-dev#167's sweep hook also had to avoid.
#
# Fails OPEN on everything it cannot resolve (no git repo, detached/bare
# worktree) — a guard that blocks on its own blindness gets disabled, same
# rule as open_review_threads_nudge.sh.
set -u

GIT=/usr/bin/git
command -v jq >/dev/null 2>&1 || exit 0

# shellcheck source=lib/dispatch_claims.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/dispatch_claims.sh"

# report_if_parked CWD SESSION_ID
# A worktree declared parked on the owner (dotfiles-linux-dev#1139, lib/dispatch_claims.sh) is
# reported ONCE per session instead of blocking every turn: the agent cannot finish it, and a
# guard that re-demands the impossible is ignored. Returns (so the caller blocks as before) unless
# a live entry matched. The entry is live only while the worktree HEAD still equals its anchor.
# Fails CLOSED: no HEAD, no toplevel, an unreadable file all mean "not parked", never "parked".
report_if_parked() {
	local cwd="$1" session="$2" top head lines
	top="$($GIT -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || return 0
	head="$($GIT -C "$cwd" rev-parse HEAD 2>/dev/null)" || return 0
	lines="$(cd "$cwd" && parked_owner_lookup worktree "$top" "$head")" || return 0
	# exit 1, never 0: a Stop hook surfaces stderr on any non-zero but discards it on 0.
	parked_owner_announce_once "$session" worktree "$lines" || exit 0
	{
		echo "Worktree at $top has uncommitted changes, parked on the owner (not blocking):"
		echo
		printf '%s\n' "$lines" | awk -F'\t' '{ print "  reason: " $4; print "  backup: " $5 }'
		echo
		echo "Said once per session. The declaration expires when this worktree HEAD moves"
		echo "(parked-owner.tsv, dotfiles-linux-dev#1139); uncommitted work with no declaration blocks."
	} >&2
	exit 1
}

main() {
	local payload active cwd dirty

	payload="$(cat)"

	# Never block a stop that a hook already caused — one nudge per turn.
	active="$(printf '%s' "$payload" | jq -r '.stop_hook_active // false' 2>/dev/null)"
	[[ "$active" == "true" ]] && exit 0

	cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
	[ -n "$cwd" ] || cwd="${CLAUDE_PROJECT_DIR:-$PWD}"

	$GIT -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

	dirty="$($GIT -C "$cwd" status --porcelain 2>/dev/null)"
	[ -z "$dirty" ] && exit 0

	report_if_parked "$cwd" "$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"

	{
		echo "Worktree at $cwd has uncommitted changes — do not stop here."
		echo
		echo "$dirty"
		echo
		echo "Commit (and push, if a remote is configured) before ending the turn. Work"
		echo "left uncommitted in a worktree is destroyed when that worktree is torn down —"
		echo "three agents lost 662/694/256 lines this way in one session (dotfiles-linux-dev#167)."
		echo "A kill part-way through costs the same whether it happens now or later, so"
		echo "commit at the first coherent point rather than saving it for the end."
	} >&2
	exit 2
}

main "$@"
