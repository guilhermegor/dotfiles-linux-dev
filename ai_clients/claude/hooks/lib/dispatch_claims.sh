#!/bin/bash
# Agent-vs-agent claims registry (dotfiles-linux-dev#405 scope 1 and 5).
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
#   claim_review_ask
#       The shared, cross-agent primary-rung review-ask budget (dotfiles-linux-dev#548). Atomic
#       check-and-stamp, prints exactly one of:
#           GRANTED    — go ahead and post the @coderabbitai ask
#           BUSY       — another reader already spent this window's ask
#           UNKNOWN    — could not be decided (no flock, no git dir); treat like BUSY
#       Returns 0 only on GRANTED.
#
# ⚠️ ONE gate read per round, never one per agent (dotfiles-linux-dev#405 scope 5). Measured
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
# session limit killed agents twice on 2026-09-17 (dotfiles-linux-dev#405 scope 3).
DISPATCH_MAX_CONCURRENT="${DISPATCH_MAX_CONCURRENT:-8}"

# A claim whose agent died without calling release_claims would otherwise wedge its paths — and
# a registry that reads "everything is in flight" forever is the #404 defect (a guard that never
# fires) with a different cause. ponytail: a wall-clock TTL, not a liveness probe, because no
# bash hook can read another process's state; an agent takes ~10 minutes, so 2h is ~12x slack.
# Upgrade path: drop the TTL the day the harness exposes a running-agent registry.
DISPATCH_CLAIM_TTL="${DISPATCH_CLAIM_TTL:-7200}"

# The token every UNDECLARED report is matched on — the shell half of a one-word contract whose
# other half is dispatch_plan.py's UNDECLARED_TOKEN (it emits, the guard greps). An issue with no
# declared surface is REPORTED, never assumed free. The CONVENTION itself (a fenced ```surface
# block today; a scope label once blueprintx#314 lands) is named in exactly one place, and it is
# not here: dispatch_plan.py's SURFACE_LABEL_PREFIX, the file that actually reads the issue.
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

# No REPO_DIR parameter, unlike dispatch_claims_file: every caller works in the repo it is
# claiming for, and dispatch_state_dir already defaults to $PWD — a forwarded "${1:-$PWD}" was
# byte-for-byte the same call with an argument nobody passed (SC2120).
dispatch_pr_held_file() {
	local dir
	dir="$(dispatch_state_dir)" || return 1
	printf '%s/pr-held-paths.tsv\n' "$dir"
}

# dispatch_claims_lock
# A lock file of its own, never the registry. Locking the registry itself looks right and is
# broken: a writer replaces it by `mv` (the only way to rewrite it atomically), so the next
# claimer opens and locks the NEW inode while the current holder still holds the old one — two
# agents inside the critical section, which is exactly the race being prevented. This file is
# only ever locked, never rewritten, so every racer locks the same inode.
# Takes no REPO_DIR either, for the same reason as dispatch_pr_held_file above.
dispatch_claims_lock() {
	local dir
	dir="$(dispatch_state_dir)" || return 1
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

# The shared, cross-agent half of dev-loop.md step 4b item 4's "one ask per invocation on the
# primary rung" cap (dotfiles-linux-dev#548). That prose binds only the reader of the skill file — a
# dispatched subagent that asks for review on its own PR is invisible to it, so N subagents each
# asking once is an N-ask burst against CodeRabbit's one ACCOUNT-level quota. Measured 2026-09-27:
# four asks in five minutes (one orchestrator tick, three subagents) pushed the reviewer window
# from 11:22Z to 12:21Z although the orchestrator itself asked zero times that round.
#
# Scope is PER REPO, not per PR — the account quota the cap defends does not care which PR the
# ask was for, only how many landed. TTL is the step's own dedicated-tick cadence (`8,28,48 * * *
# * *` in dev-loop.md) rather than a fresh constant: a second ask inside the SAME tick window is
# the burst this cap exists to stop, and a later tick asking again is the legitimate re-spend
# dotfiles-linux-dev#477 already carved out for a BUSY/UNKNOWN slot.
DISPATCH_REVIEW_ASK_TTL="${DISPATCH_REVIEW_ASK_TTL:-1200}"
# A non-integer TTL (`abc`, `10m`) makes the `((…))` check below fail, which falls through to
# GRANTED — fail-open on the very budget this cap defends. Reset it rather than trust it.
[[ "$DISPATCH_REVIEW_ASK_TTL" =~ ^[0-9]+$ ]] || DISPATCH_REVIEW_ASK_TTL=1200

dispatch_review_ask_file() {
	local dir
	dir="$(dispatch_state_dir)" || return 1
	printf '%s/dispatch-review-ask.tsv\n' "$dir"
}

# claim_review_ask
# Atomic check-and-stamp for the shared one-ask budget. Prints exactly one of:
#     GRANTED   — no ask was recorded within DISPATCH_REVIEW_ASK_TTL; the stamp is now this
#                 call's — go ahead and post the @coderabbitai ask.
#     BUSY      — another reader (orchestrator or subagent) already spent this window's ask.
#     UNKNOWN   — could not be decided (no flock, no git dir); treat exactly like BUSY, never ask.
# Returns 0 only on GRANTED. Reuses claim_files's own lock (dispatch_claims_lock) rather than a
# second lock file of its own — a dedicated lock would let a claim_files writer and a
# claim_review_ask writer interleave across the two registries independently, which is the same
# race the single critical section above exists to prevent, just against a different pair of
# files.
claim_review_ask() {
	command -v flock >/dev/null 2>&1 || {
		echo "UNKNOWN"
		return 1
	}
	local file lock
	file="$(dispatch_review_ask_file)" || {
		echo "UNKNOWN"
		return 1
	}
	lock="$(dispatch_claims_lock)" || {
		echo "UNKNOWN"
		return 1
	}

	(
		flock -w "${DISPATCH_CLAIM_LOCK_WAIT:-10}" 9 || {
			echo "UNKNOWN"
			exit 1
		}

		local now stamp
		now="$(date +%s)"
		stamp=""
		if [ -s "$file" ]; then
			stamp="$(cat "$file" 2>/dev/null)"
		fi
		if [[ "$stamp" =~ ^[0-9]+$ ]] && ((now - stamp < DISPATCH_REVIEW_ASK_TTL)); then
			echo "BUSY"
			exit 1
		fi

		printf '%s\n' "$now" >"$file.tmp"
		mv -f "$file.tmp" "$file"
		echo "GRANTED"
	) 9>>"$lock"
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
