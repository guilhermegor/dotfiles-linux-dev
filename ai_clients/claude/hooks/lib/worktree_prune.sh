#!/bin/bash
# Worktree PRUNE (dotfiles-linux-dev#882): remove a worktree, its local branch and its origin
# branch ONLY when the content proves the work already shipped. s:dev-loop step 1 (RESCUE)
# reports every dirty or diverged worktree and nothing ever removed the shipped ones, so the one
# real rescue drowned in noise.
#
# This DELETES, so everything fails closed: dry-run unless --apply / WORKTREE_PRUNE_APPLY=1, and
# any read that fails (forge, remote, git) keeps the worktree.
#
# A worktree is prunable only when ALL hold:
#   1. not the main worktree, not the cwd's worktree, not the default branch;
#   2. the live-agent gate answered (gate_live_agent_surface) and the worktree was not touched
#      within WORKTREE_PRUNE_MIN_AGE seconds (default 900) — a live agent keeps writing;
#   3. content shipped: branch_content_shipped (worktree_fanout.sh, #837/#840) — every path the
#      branch changed is byte-identical on origin/<default>. Never ancestry: a squash is no ancestor;
#   4. nothing beyond build noise: ignored files (git's own rules) are invisible; untracked
#      __pycache__/ .venv/ *.pyc .pytest_cache/ node_modules/ are noise; any other untracked or
#      modified file means KEEP. A staged-only index counts as stale only when `git write-tree`
#      equals the tree of an existing commit on the branch's history;
#   5. the forge reports no OPEN PR for the branch (merged, closed or none); a failed read keeps;
#   6. the remote branch, if present, has exactly the local sha — otherwise KEEP everything.
# Usage: worktree_prune.sh [--apply] [repo-path]    (also sourceable for tests)
set -u

_PRUNE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=worktree_fanout.sh
source "$_PRUNE_DIR/worktree_fanout.sh"
# shellcheck source=free_surface.sh
source "$_PRUNE_DIR/free_surface.sh"

PRUNE_NOISE_GLOBS=('__pycache__' '.venv' '.pytest_cache' 'node_modules')

# One untracked status path (`dir/` or `file`) is noise when any component is a noise dir or it is *.pyc.
prune_is_noise_path() {
	local p="${1%/}" part n
	[[ "$p" == *.pyc ]] && return 0
	local IFS=/
	for part in $p; do
		for n in "${PRUNE_NOISE_GLOBS[@]}"; do
			[ "$part" = "$n" ] && return 0
		done
	done
	return 1
}

# True when the staged tree equals the tree of an existing commit on HEAD's history.
prune_index_is_stale() {
	local path="$1" tree
	tree="$(git -C "$path" write-tree 2>/dev/null)" || return 1
	[ -n "$tree" ] || return 1
	git -C "$path" log --format=%T HEAD 2>/dev/null | grep -qxF "$tree"
}

# 0 = nothing beyond build noise / a stale index. Prints a reason on stdout when dirty (rc 1).
prune_tree_is_noise_only() {
	local path="$1" line xy f staged=0 st
	st="$(git -C "$path" status --porcelain=v1 --untracked-files=normal 2>/dev/null)" \
		|| { printf 'status unreadable'; return 1; }
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		xy="${line:0:2}"
		f="${line:3}"
		if [ "$xy" = "??" ]; then
			prune_is_noise_path "$f" || { printf 'untracked %s' "$f"; return 1; }
			continue
		fi
		[ "${xy:1:1}" = " " ] || { printf 'unstaged change %s' "$f"; return 1; }
		staged=1
	done <<<"$st"
	[ "$staged" = 0 ] && return 0
	prune_index_is_stale "$path" || { printf 'staged work not in branch history'; return 1; }
}

# open | merged | closed | none; rc 1 = forge unreadable. Overridden by tests.
prune_pr_state() {
	local cwd="$1" branch="$2" slug owner out
	slug="$(fanout_repo_slug "$cwd")" || return 1
	owner="${slug%%/*}"
	out="$(gh api "repos/$slug/pulls?state=all&per_page=100&head=$owner:$branch" \
		--jq 'map(if .state=="open" then "open" elif .merged_at then "merged" else "closed" end) | unique | join(" ")' 2>/dev/null)" || return 1
	case " $out " in
	*" open "*) echo open ;;
	*merged*) echo merged ;;
	*closed*) echo closed ;;
	*) echo none ;;
	esac
}

prune_recently_touched() {
	local path="$1" min_age="$2" now m newest=0 gd
	now="$(date +%s)"
	gd="$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null)"
	for f in "$path" "$gd/index" "$gd/HEAD"; do
		m="$(stat -c %Y "$f" 2>/dev/null)" || continue
		[ "$m" -gt "$newest" ] && newest="$m"
	done
	[ $((now - newest)) -lt "$min_age" ]
}

# Prints "PRUNE|KEEP<TAB>reason" for one worktree; rc 0 = prunable.
prune_classify() {
	local cwd="$1" path="$2" branch="$3" db="$4" min_age="$5" why state remote local_sha
	if prune_recently_touched "$path" "$min_age"; then echo "touched within ${min_age}s (live agent?)"; return 1; fi
	branch_content_shipped "$path" "$db" || { echo "content not on origin/$db (or undecidable)"; return 1; }
	why="$(prune_tree_is_noise_only "$path")" || { echo "$why"; return 1; }
	if [ -n "$branch" ]; then
		state="$(prune_pr_state "$cwd" "$branch")" || { echo "forge unreadable"; return 1; }
		[ "$state" = open ] && { echo "PR is OPEN"; return 1; }
		remote="$(git -C "$cwd" ls-remote origin "refs/heads/$branch" 2>/dev/null)" || { echo "remote unreadable"; return 1; }
		local_sha="$(git -C "$cwd" rev-parse "refs/heads/$branch" 2>/dev/null)" || { echo "branch unreadable"; return 1; }
		if [ -n "$remote" ] && [ "${remote%%[[:space:]]*}" != "$local_sha" ]; then
			echo "origin/$branch sha differs from local"
			return 1
		fi
		echo "PR ${state}, content shipped"
		return 0
	fi
	echo "detached, content shipped"
}

prune_default_branch() {
	local cwd="$1" db c
	db="$(git -C "$cwd" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
	db="${db#origin/}"
	if [ -z "$db" ] || ! git -C "$cwd" rev-parse --verify --quiet "refs/remotes/origin/$db" >/dev/null 2>&1; then
		db=""
		for c in main master; do
			git -C "$cwd" rev-parse --verify --quiet "refs/remotes/origin/$c" >/dev/null 2>&1 && { db="$c"; break; }
		done
	fi
	[ -n "$db" ] && echo "$db"
}

# Removes worktree, local branch, then origin branch; each step only if the one before succeeded.
prune_apply_one() {
	local cwd="$1" path="$2" branch="$3"
	git -C "$cwd" worktree remove --force "$path" 2>/dev/null || { echo "worktree remove failed"; return 1; }
	[ -n "$branch" ] || return 0
	git -C "$cwd" branch -D "$branch" >/dev/null 2>&1 || { echo "branch -D failed"; return 1; }
	if [ -n "$(git -C "$cwd" ls-remote origin "refs/heads/$branch" 2>/dev/null)" ]; then
		git -C "$cwd" push origin --delete "$branch" >/dev/null 2>&1 || { echo "push --delete failed"; return 1; }
	fi
}

prune_worktrees() {
	local cwd="$1" apply="$2" db self main="" path="" branch="" line why
	local min_age="${WORKTREE_PRUNE_MIN_AGE:-900}" pruned=0 kept=0 verb="WOULD-PRUNE"
	[ "$apply" = 1 ] && verb="PRUNED"

	db="$(prune_default_branch "$cwd")" || { echo "[prune] no origin default branch — nothing pruned"; return 1; }
	self="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || { echo "[prune] not a git repo"; return 1; }
	if ! gate_live_agent_surface "$cwd" || [ "$LIVE_AGENT_STATUS" != ok ]; then
		echo "[prune] live-agent surface UNKNOWN — keeping every worktree"
		return 1
	fi

	while IFS= read -r line; do
		case "$line" in
		"worktree "*) path="${line#worktree }"; branch=""; [ -n "$main" ] || main="$path" ;;
		"branch "*) branch="${line#branch refs/heads/}" ;;
		"")
			if [ -n "$path" ]; then
				if [ "$path" = "$main" ] || [ "$path" = "$self" ] || [ "$branch" = "$db" ]; then
					:
				elif [ ! -d "$path" ]; then
					:
				elif why="$(prune_classify "$cwd" "$path" "$branch" "$db" "$min_age")"; then
					if [ "$apply" = 1 ] && ! why="$(prune_apply_one "$cwd" "$path" "$branch")"; then
						printf 'KEEP %s: %s\n' "$path" "$why"
						kept=$((kept + 1))
					else
						printf '%s %s [%s]\n' "$verb" "$path" "${branch:-detached}"
						pruned=$((pruned + 1))
					fi
				else
					printf 'KEEP %s: %s\n' "$path" "$why"
					kept=$((kept + 1))
				fi
			fi
			path=""
			branch=""
			;;
		esac
	done < <(git -C "$cwd" worktree list --porcelain 2>/dev/null; printf '\n')

	# Entries whose directory is already gone: metadata only, so safe under --apply.
	if [ "$apply" = 1 ]; then
		git -C "$cwd" worktree prune 2>/dev/null
	else
		git -C "$cwd" worktree prune --dry-run -v 2>&1 | sed 's/^/WOULD-PRUNE-ENTRY /'
	fi
	printf '[prune] %s: %d prunable, %d kept%s\n' "$verb" "$pruned" "$kept" \
		"$([ "$apply" = 1 ] || echo ' (dry-run; re-run with --apply)')"
}

main() {
	local apply="${WORKTREE_PRUNE_APPLY:-0}" cwd="$PWD" a
	for a in "$@"; do
		case "$a" in
		--apply) apply=1 ;;
		*) cwd="$a" ;;
		esac
	done
	prune_worktrees "$cwd" "$apply"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
