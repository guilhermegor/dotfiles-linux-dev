#!/bin/bash
# Shared stale-local-ref gate: decides whether a bare local branch name is
# safe to check out (or add as a worktree), or whether it is STALE against
# `origin/<branch>` and must be refused (dotfiles-linux-dev#410).
#
# Why this exists: `git worktree add <path> fix/precommit-ci-parity-384` — a
# bare local branch name — checked out a ref 3 commits behind the real PR
# head. The file under review did not exist at that revision, so a review
# pass publicly refuted three real CodeRabbit findings (two Major) as "not in
# this PR" and resolved all three threads on that false premise
# (blueprintx#512). The wrong answer read as plausible, not an error — the
# same class of bug as dotfiles-linux-dev#229 (an unref'd `git describe` describing
# a checkout 16 tags behind `origin/main`). Comparing against a local ref
# must either name `origin/<base>` or refuse; this gate is the "refuse" half.
#
# Contract: call `gate_stale_local_ref BRANCH`. It sets two globals and
# returns nothing meaningful (check STALE_REF_STATUS):
#   STALE_REF_STATUS = fresh | ahead | stale | no_remote | no_local | unreadable
#   STALE_REF_DETAIL  = human-readable detail (empty only for fresh/ahead)
# The three states a caller must never collapse into one message: "stale"
# (behind — refuse), "no_remote" (nothing to compare — allow), "unreadable"
# (refs could not be read at all — allow, fails open like every other gate
# here, but says so instead of passing in silence).
# shellcheck disable=SC2034 # both are read by every caller after the call returns
set -u

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	echo "stale_local_ref_gate.sh is meant to be sourced, not executed." >&2
	exit 1
fi

_stale_strip_heredoc_bodies() {
	# Drop heredoc bodies so a git verb written inside one (an issue/PR body)
	# is not read as a command. Copy of the helper in
	# branch_requires_issue_guard.sh — hooks are intentionally self-contained;
	# keep the two in sync.
	local line delim="" trimmed in_body=0
	while IFS= read -r line || [[ -n "$line" ]]; do
		if ((in_body)); then
			trimmed="${line#"${line%%[!$'\t']*}"}"
			[[ "$trimmed" == "$delim" ]] && in_body=0
			continue
		fi
		if [[ "$line" =~ \<\<-?[[:space:]]*[\"\'\\]?([[:alnum:]_]+) ]]; then
			delim="${BASH_REMATCH[1]}"
			in_body=1
		fi
		printf '%s\n' "$line"
	done
}

_stale_segment_commands() {
	# One shell command segment per line, so the regexes below anchor to a
	# segment START and never span two chained commands.
	sed -E 's/(\|\||&&|[;|])/\n/g'
}

# stale_ref_target COMMAND
# Emit the branch/commit-ish token from a `git checkout <ref>`, `git switch
# <ref>`, or `git worktree add <path> <ref>` command segment, or return 1
# when the command does not name an existing-ref checkout. Branch CREATION
# (`checkout -b`, `switch -c`, `worktree add -b`) is a different case, already
# covered by branch_requires_issue_guard.sh, and is deliberately skipped here.
# ponytail: a regex over segments, not a full shell parse — same residual as
# branch_requires_issue_guard.sh (a short-flag form like `worktree add -f
# <path> <ref>` is not recognised and fails open, the safe miss).
stale_ref_target() {
	local cmd seg
	cmd="$(printf '%s\n' "$1" | _stale_strip_heredoc_bodies)"

	while IFS= read -r seg || [[ -n "$seg" ]]; do
		seg="${seg#"${seg%%[![:space:]]*}"}"
		_stale_ref_from_segment "$seg" && return 0
	done < <(printf '%s' "$cmd" | _stale_segment_commands)

	return 1
}

_stale_ref_from_segment() {
	local seg="$1" re val

	if [[ "$seg" =~ ^(rtk[[:space:]]+)?git[[:space:]]+worktree[[:space:]]+add([[:space:]]|$) ]]; then
		# -b/-B creates a NEW branch from a start-point — not a stale-ref read.
		[[ "$seg" == *' -b '* || "$seg" == *' -B '* ]] && return 1
		re='^(rtk[[:space:]]+)?git[[:space:]]+worktree[[:space:]]+add[[:space:]]+(--[A-Za-z-]+[[:space:]]+)*("[^"]*"|'\''[^'\'']*'\''|[^[:space:]-][^[:space:]]*)[[:space:]]+("[^"]*"|'\''[^'\'']*'\''|[^[:space:]-][^[:space:]]*)[[:space:]]*$'
		[[ "$seg" =~ $re ]] || return 1
		val="${BASH_REMATCH[4]}"
	else
		re='^(rtk[[:space:]]+)?git[[:space:]]+(checkout|switch)[[:space:]]+("[^"]*"|'\''[^'\'']*'\''|[^[:space:]-][^[:space:]]*)[[:space:]]*$'
		[[ "$seg" =~ $re ]] || return 1
		val="${BASH_REMATCH[3]}"
	fi

	val="${val#[\"\']}"
	val="${val%[\"\']}"
	case "$val" in
	*'$'* | *'`'*) return 1 ;; # dynamic name — cannot resolve statically
	esac

	printf '%s' "$val"
}

# gate_stale_local_ref BRANCH
gate_stale_local_ref() {
	local branch="$1" local_sha origin_sha
	STALE_REF_STATUS="unreadable"
	STALE_REF_DETAIL="could not read either ref: no branch name given"
	[ -n "$branch" ] || return 0

	git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
		STALE_REF_DETAIL="could not read either ref: not inside a git working tree"
		return 0
	}

	local_sha="$(git rev-parse --verify --quiet "refs/heads/$branch" 2>/dev/null)"
	if [ -z "$local_sha" ]; then
		STALE_REF_STATUS="no_local"
		STALE_REF_DETAIL="'$branch' is not a local branch — nothing to compare"
		return 0
	fi

	origin_sha="$(git rev-parse --verify --quiet "refs/remotes/origin/$branch" 2>/dev/null)"
	if [ -z "$origin_sha" ]; then
		STALE_REF_STATUS="no_remote"
		STALE_REF_DETAIL="no such remote branch 'origin/$branch' — nothing to compare"
		return 0
	fi

	if [ "$local_sha" = "$origin_sha" ]; then
		STALE_REF_STATUS="fresh"
		STALE_REF_DETAIL=""
		return 0
	fi

	if git merge-base --is-ancestor "$origin_sha" "$local_sha" 2>/dev/null; then
		STALE_REF_STATUS="ahead"
		STALE_REF_DETAIL="local '$branch' (${local_sha:0:12}) is ahead of origin/$branch (${origin_sha:0:12}) — ordinary unpushed work, not stale"
		return 0
	fi

	STALE_REF_STATUS="stale"
	STALE_REF_DETAIL="local ref is behind origin: '$branch' is at ${local_sha:0:12}, origin/$branch is at ${origin_sha:0:12}. Fetch and use origin/$branch instead of the bare local name."
}
