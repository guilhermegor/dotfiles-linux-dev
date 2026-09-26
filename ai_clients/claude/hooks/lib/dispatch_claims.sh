#!/bin/bash
# Agent-vs-agent claims registry (dotfiles-dev#405 scope 1 and 5).
#
# The free-surface gate (lib/free_surface.sh) and the planner (lib/dispatch_plan.py) both see
# only PRs and worktrees. Two agents dispatched in the SAME batch are invisible to each other
# until one of them opens a PR — there is no shared state saying "I am writing this file right
# now". This file is that state: one line per claimed path, appended under `flock` so a whole
# batch of agents racing the same path produces exactly one winner.
#
# Contract:
#
#   claim_files ISSUE PATH...
#       Atomic check-and-append. Prints exactly one of:
#           CLAIMED                     — every path is now this issue's, exclusively
#           HELD:<holder>:<path>        — refused; <holder> is `open-pr` or `#<issue>`
#           UNKNOWN                     — could not be decided (no flock, no git dir)
#       Returns 0 only on CLAIMED. Re-claiming a path this same issue already holds is
#       idempotent (it refreshes the timestamp), so a resumed agent is never blocked by itself.
#
#   release_claims ISSUE
#       Drops every line for ISSUE. Called when the agent's PR opens (the PR now holds the
#       paths, and the gate can see it) or when the agent stops without one.
#
#   dispatch_claimed_issues
#       Newline-separated issue numbers holding a live claim — the per-issue `in_flight` half
#       of dispatch_free_surface_guard.sh's coverage rule.
#
#   refresh_pr_held_paths OWNER REPO
#       Runs gate_free_surface ONCE and writes its held-path union to the registry directory.
#
# ⚠️ ONE gate read per round, never one per agent (dotfiles-dev#405 scope 5). Measured
# 2026-09-17: 8 agents dispatched in one batch each ran `gate_free_surface` inside their own
# claim step; it compares every branch against the default branch (33 branches, one API call
# each) and the shared 5000/h GitHub quota hit 0 within seconds, twice. Every claim then failed
# closed — correctly — and the whole wave stalled. So `claim_files` makes ZERO API calls: it
# reads `pr-held-paths.tsv`, which the orchestrator refreshes once per round with
# `refresh_pr_held_paths`, plus the registry itself.
#
# Both files live in `$(git rev-parse --git-common-dir)` — shared by every worktree of the
# repo (which is the point: the racing agents each have their own worktree) and never tracked.
#
# Fails CLOSED everywhere: an undecidable claim prints UNKNOWN and returns non-zero, because a
# claim that cannot be proven exclusive must not be treated as granted — that is the input that
# produces two agents in one file.
set -u

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	echo "lib/dispatch_claims.sh is meant to be sourced, not executed." >&2
	exit 1
fi

DISPATCH_CLAIMS_GIT=/usr/bin/git

# Concurrency cap. The cap THROTTLES, it never drops an issue: dispatch_free_surface_guard.sh
# reports everything over it as queued, and demands it as soon as a slot frees. 8 because the
# session limit killed agents twice on 2026-09-17 (dotfiles-dev#405 scope 3).
DISPATCH_MAX_CONCURRENT="${DISPATCH_MAX_CONCURRENT:-8}"

# A claim whose agent died without calling release_claims would otherwise wedge its paths — and
# a registry that reads "everything is in flight" forever is the #404 defect (a guard that never
# fires) with a different cause. ponytail: a wall-clock TTL, not a liveness probe, because no
# bash hook can read another process's state; an agent takes ~10 minutes, so 2h is ~12x slack.
# Upgrade path: drop the TTL the day the harness exposes a running-agent registry.
DISPATCH_CLAIM_TTL="${DISPATCH_CLAIM_TTL:-7200}"

# blueprintx#314's declared-surface convention (a scope LABEL on the issue) does not exist yet.
# dispatch_plan.py reads the surface from a fenced ```surface block today; when #314 lands, the
# label prefix goes here and nowhere else — one edit, not a hunt (dotfiles-dev#405 scope 2).
# Empty means "the label convention has not shipped", never "the issue declared nothing".
DISPATCH_SURFACE_LABEL_PREFIX="${DISPATCH_SURFACE_LABEL_PREFIX:-}"

# The token every UNDECLARED report is matched on. An issue with no declared surface is
# REPORTED, never assumed free — dispatch_plan.py emits this token in its exclusion reason and
# the guard greps for it, so the two cannot drift.
# shellcheck disable=SC2034  # read by dispatch_free_surface_guard.sh, which sources this file
DISPATCH_UNDECLARED_TOKEN="UNDECLARED"

# dispatch_state_dir [REPO_DIR]
# The git common dir — shared by every worktree, never tracked. Empty output + non-zero when
# REPO_DIR is not a repo.
dispatch_state_dir() {
	local repo_dir="${1:-$PWD}" dir
	dir="$($DISPATCH_CLAIMS_GIT -C "$repo_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
	[ -n "$dir" ] || return 1
	printf '%s\n' "$dir"
}

dispatch_claims_file() {
	local dir
	dir="$(dispatch_state_dir "${1:-$PWD}")" || return 1
	printf '%s/dispatch-claims.tsv\n' "$dir"
}

dispatch_pr_held_file() {
	local dir
	dir="$(dispatch_state_dir "${1:-$PWD}")" || return 1
	printf '%s/pr-held-paths.tsv\n' "$dir"
}

# dispatch_claims_lock [REPO_DIR]
# A lock file of its own, never the registry. Locking the registry itself looks right and is
# broken: a writer replaces it by `mv` (the only way to rewrite it atomically), so the next
# claimer opens and locks the NEW inode while the current holder still holds the old one — two
# agents inside the critical section, which is exactly the race being prevented. This file is
# only ever locked, never rewritten, so every racer locks the same inode.
dispatch_claims_lock() {
	local dir
	dir="$(dispatch_state_dir "${1:-$PWD}")" || return 1
	printf '%s/dispatch-claims.lock\n' "$dir"
}

# _dispatch_live_claims FILE
# FILE's lines with the expired ones dropped. Pruning on every read AND rewriting on every
# write keeps the TTL from needing a sweeper of its own.
_dispatch_live_claims() {
	local file="$1" now
	[ -s "$file" ] || return 0
	now="$(date +%s)"
	awk -F'\t' -v now="$now" -v ttl="$DISPATCH_CLAIM_TTL" \
		'NF == 3 && ($1 + ttl) > now' "$file"
}

# _dispatch_holder PR_HELD_FILE LIVE_CLAIMS ISSUE PATH
# Who holds PATH against ISSUE, or empty when nobody does. An open PR wins the report because
# it is the older, non-negotiable claim; a path this same ISSUE already holds is not a holder.
_dispatch_holder() {
	local pr_held="$1" live="$2" issue="$3" path="$4"
	if [ -s "$pr_held" ] && cut -f2 "$pr_held" | grep -qxF -- "$path"; then
		printf 'open-pr\n'
		return 0
	fi
	printf '%s\n' "$live" | awk -F'\t' -v p="$path" -v me="$issue" \
		'$3 == p && $2 != me { print "#" $2; exit }'
}

# claim_files ISSUE PATH...
claim_files() {
	local issue="$1"
	shift
	[ "$#" -gt 0 ] || {
		echo "UNKNOWN"
		return 1
	}
	command -v flock >/dev/null 2>&1 || {
		echo "UNKNOWN"
		return 1
	}

	local claims pr_held lock live holder path now
	claims="$(dispatch_claims_file)" || {
		echo "UNKNOWN"
		return 1
	}
	pr_held="$(dispatch_pr_held_file)" || {
		echo "UNKNOWN"
		return 1
	}
	lock="$(dispatch_claims_lock)" || {
		echo "UNKNOWN"
		return 1
	}

	# The lock is held across the read AND the append — that single critical section is the
	# whole mechanism. A check outside the lock followed by an append inside it grants the same
	# path to every racer, which is the bug this file exists to prevent.
	(
		flock -w "${DISPATCH_CLAIM_LOCK_WAIT:-10}" 9 || {
			echo "UNKNOWN"
			exit 1
		}

		live="$(_dispatch_live_claims "$claims")"
		for path in "$@"; do
			holder="$(_dispatch_holder "$pr_held" "$live" "$issue" "$path")"
			if [ -n "$holder" ]; then
				printf 'HELD:%s:%s\n' "$holder" "$path"
				exit 1
			fi
		done

		now="$(date +%s)"
		{
			printf '%s\n' "$live" | awk -F'\t' -v me="$issue" 'NF == 3 && $2 != me'
			for path in "$@"; do
				printf '%s\t%s\t%s\n' "$now" "$issue" "$path"
			done
		} >"$claims.tmp"
		mv -f "$claims.tmp" "$claims"
		echo "CLAIMED"
	) 9>>"$lock"
}

# release_claims ISSUE
release_claims() {
	local issue="$1" claims lock
	command -v flock >/dev/null 2>&1 || return 1
	claims="$(dispatch_claims_file)" || return 1
	lock="$(dispatch_claims_lock)" || return 1
	[ -e "$claims" ] || return 0
	(
		flock -w "${DISPATCH_CLAIM_LOCK_WAIT:-10}" 9 || exit 1
		_dispatch_live_claims "$claims" | awk -F'\t' -v me="$issue" 'NF == 3 && $2 != me' >"$claims.tmp"
		mv -f "$claims.tmp" "$claims"
	) 9>>"$lock"
}

# dispatch_claimed_issues [REPO_DIR]
dispatch_claimed_issues() {
	local claims
	claims="$(dispatch_claims_file "${1:-$PWD}")" || return 1
	_dispatch_live_claims "$claims" | cut -f2 | sort -un
}

# refresh_pr_held_paths OWNER REPO
# The ONE gate read per round (scope 5). Requires lib/free_surface.sh to be sourced already —
# it is the gate's own file and this one does not duplicate it. Writes `<holder>\t<path>`.
#
# ponytail: the holder column is the literal `open-pr`, not a PR number — gate_free_surface
# returns a flat, deduped union across every open PR and every pushed-branch-without-a-PR, with
# no per-PR attribution. A refused agent needs the PATH (that is what it cannot write);
# `gh pr list --search <path>` finds the number. Upgrade path: per-PR attribution inside
# _free_held_paths, if a caller ever needs the number itself.
refresh_pr_held_paths() {
	local owner="$1" repo="$2" pr_held
	declare -F gate_free_surface >/dev/null 2>&1 || return 1
	pr_held="$(dispatch_pr_held_file)" || return 1
	gate_free_surface "$owner" "$repo" || return 1
	printf '%s\n' "$FREE_HELD_PATHS" | sed '/^$/d' | sed 's/^/open-pr\t/' >"$pr_held.tmp"
	mv -f "$pr_held.tmp" "$pr_held"
}
