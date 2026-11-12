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
#   4. nothing beyond build noise: untracked __pycache__/ .venv/ *.pyc .pytest_cache/
#      node_modules/ are noise; any other untracked or modified file means KEEP. Git-ignored
#      files (which `worktree remove` also deletes) pass unless secret-shaped (.env*, keys, *.local). A staged-only index counts as stale only when `git write-tree`
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
# shellcheck source=branch_prune.sh
source "$_PRUNE_DIR/branch_prune.sh"

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

# Names a human keeps on purpose even when git ignores them: env files, keys, local overrides.
prune_is_secret_shaped() {
	case "${1%/}" in
	*.env | *.env.* | .env* | */.env* | *.local | *.pem | *.key | *secret* | *credential* | *token*) return 0 ;;
	esac
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
	st="$(git -C "$path" status --porcelain=v1 --untracked-files=normal --ignored=traditional 2>/dev/null)" \
		|| { printf 'status unreadable'; return 1; }
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		xy="${line:0:2}"
		f="${line:3}"
		if [ "$xy" = "??" ]; then
			prune_is_noise_path "$f" || { printf 'untracked %s' "$f"; return 1; }
			continue
		fi
		if [ "$xy" = "!!" ]; then
			# worktree remove deletes ignored files too: only noise, or git-ignored files that
			# are not secret-shaped (.env, keys, *.local), may go.
			prune_is_noise_path "$f" && continue
			prune_is_secret_shaped "$f" && { printf 'ignored file %s (secret-shaped)' "$f"; return 1; }
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
	local enc
	enc="$(jq -rn --arg b "$owner:$branch" '$b|@uri')" || return 1
	# OPEN is what blocks a delete, so ask for it directly: never lost to a page limit on state=all.
	out="$(gh api "repos/$slug/pulls?state=open&per_page=1&head=$enc" --jq 'length' 2>/dev/null)" || return 1
	[ "$out" = 0 ] || { [[ "$out" =~ ^[0-9]+$ ]] && echo open && return 0; return 1; }
	out="$(gh api --paginate "repos/$slug/pulls?state=all&per_page=100&head=$enc" \
		--jq 'map(if .state=="open" then "open" elif .merged_at then "merged" else "closed" end) | unique | join(" ")' 2>/dev/null)" || return 1
	case " $out " in
	*" open "*) echo open ;;
	*merged*) echo merged ;;
	*closed*) echo closed ;;
	*) echo none ;;
	esac
}

# "<branch>\t<head.sha>" for each PR from <branch> MERGED INTO <db>; rc 1 = forge unreadable.
# A merge into any other base never reached the default branch, so it proves nothing.
# REST only (no GraphQL budget). Fetches a head object the clone lacks so the ancestor test
# in merged_pr_covers_head can run; a failed fetch leaves it absent, which reads as not covered.
# $4 (optional commit sha) is for a detached worktree: <branch> is then only a label and the PRs
# are those the forge associates with that commit (#988).
# Overridden by tests.
prune_merged_heads() {
	local cwd="$1" branch="$2" db="$3" at="${4:-}" slug owner enc out shas sha
	slug="$(fanout_repo_slug "$cwd")" || return 1
	owner="${slug%%/*}"
	if [ -n "$at" ]; then
		out="$(gh api "repos/$slug/commits/$at/pulls?per_page=100" 2>/dev/null)" || return 1
	else
		enc="$(jq -rn --arg b "$owner:$branch" '$b|@uri')" || return 1
		out="$(gh api "repos/$slug/pulls?state=all&per_page=100&head=$enc" 2>/dev/null)" || return 1
	fi
	shas="$(jq -r --arg db "$db" '.[] | select(.merged_at and .base.ref == $db) | .head.sha' <<<"$out" 2>/dev/null)" || return 1
	while IFS= read -r sha; do
		[ -n "$sha" ] || continue
		git -C "$cwd" cat-file -e "$sha^{commit}" 2>/dev/null \
			|| GIT_TERMINAL_PROMPT=0 timeout 60 git -C "$cwd" fetch -q --no-write-fetch-head origin "$sha" 2>/dev/null
		printf '%s\t%s\n' "$branch" "$sha"
	done <<<"$shas"
}

# Prints "open" when any OPEN PR contains commit <sha>, else "none"; rc 1 = forge unreadable.
# A detached worktree has no branch for prune_pr_state, and a merged PR proves nothing while a
# follow-up PR over the same commit is still open (#988). Overridden by tests.
prune_detached_pr_state() {
	local cwd="$1" sha="$2" slug out
	slug="$(fanout_repo_slug "$cwd")" || return 1
	out="$(gh api "repos/$slug/commits/$sha/pulls?per_page=100" --jq '[.[]|select(.state=="open")]|length' 2>/dev/null)" || return 1
	[[ "$out" =~ ^[0-9]+$ ]] || return 1
	[ "$out" = 0 ] && echo none || echo open
}

prune_recently_touched() {
	local path="$1" min_age="$2" now m newest=0 gd f hit
	now="$(date +%s)"
	gd="$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null)"
	[ -n "$gd" ] || return 0
	for f in "$path" "$gd/index" "$gd/HEAD"; do
		m="$(stat -c %Y "$f" 2>/dev/null)" || continue
		[ "$m" -gt "$newest" ] && newest="$m"
	done
	# Unreadable timestamps are "recent", never "old": fail closed.
	[ "$newest" -gt 0 ] || return 0
	[ $((now - newest)) -lt "$min_age" ] && return 0
	# An edit below the top level does not move the directory mtime: look at every file.
	hit="$(find "$path" \( -name .git -o -name .venv -o -name node_modules -o -name __pycache__ \) -prune \
		-o -type f -mmin "-$(( (min_age + 59) / 60 ))" -print -quit 2>/dev/null)" || return 0
	[ -n "$hit" ]
}

# Prints "PRUNE|KEEP<TAB>reason" for one worktree; rc 0 = prunable.
prune_classify() {
	local cwd="$1" path="$2" branch="$3" db="$4" min_age="$5" why state remote local_sha base
	if prune_recently_touched "$path" "$min_age"; then echo "touched within ${min_age}s (live agent?)"; return 1; fi
	# branch_content_shipped is vacuously true for a fresh branch at origin tip (empty path list
	# makes it compare whole trees, which are equal): demand real work to have shipped.
	base="$(git -C "$path" merge-base "origin/$db" HEAD 2>/dev/null)" || { echo "no merge-base"; return 1; }
	if git -C "$path" diff --quiet "$base" HEAD 2>/dev/null; then echo "no commits beyond merge-base (fresh branch?)"; return 1; fi
	if ! branch_content_shipped "$path" "$db"; then
		# Once master edits a squash-merged file the byte-identical test fails forever
		# (#946/#947): the forge's MERGED PR head is the proof instead (same predicate the
		# fan-out uses). A closed-unmerged head proves nothing shipped. A merged-then-reverted
		# PR still counts: the owner's merge decided it, and refs/pull/<n>/head keeps the commits.
		local heads label="${branch:-(detached)}" at=""
		# A detached worktree has no branch to look PRs up by: ask by its HEAD sha (#988).
		[ -n "$branch" ] || at="$(git -C "$path" rev-parse HEAD 2>/dev/null)" || at=""
		[ -n "$branch" ] || [ -n "$at" ] || { echo "content not on origin/$db (or undecidable)"; return 1; }
		heads="$(prune_merged_heads "$cwd" "$label" "$db" "$at")" || { echo "forge unreadable"; return 1; }
		merged_pr_covers_head "$path" "$label" "$heads" \
			|| { echo "content not on origin/$db (or undecidable)"; return 1; }
		if [ -z "$branch" ]; then
			state="$(prune_detached_pr_state "$cwd" "$at")" || { echo "forge unreadable"; return 1; }
			[ "$state" = open ] && { echo "PR is OPEN"; return 1; }
		fi
	fi
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

# Unattended: a credential or passphrase prompt must fail and a stalled network must time out.
# A configured core.sshCommand, GIT_SSH_COMMAND or GIT_SSH (a per-repo identity or wrapper) is kept.
# Usage: prune_git_remote <repo> <git args…>
prune_git_remote() {
	local repo="$1"
	shift
	local -a envp=()
	if [ -z "${GIT_SSH_COMMAND:-}" ]; then
		if git -C "$repo" config core.sshCommand >/dev/null 2>&1; then
			# An exported empty GIT_SSH_COMMAND still beats core.sshCommand in git: drop it for the child.
			[ -z "${GIT_SSH_COMMAND+x}" ] || envp=(env -u GIT_SSH_COMMAND)
		elif [ -z "${GIT_SSH:-}" ]; then
			# GIT_SSH_COMMAND outranks GIT_SSH, so the batch default only goes in when neither is set.
			envp=(env GIT_SSH_COMMAND='ssh -oBatchMode=yes')
		fi
	fi
	GIT_TERMINAL_PROMPT=0 timeout -k 5 "${WORKTREE_PRUNE_REMOTE_TIMEOUT:-60}" ${envp[@]+"${envp[@]}"} "${PRUNE_GIT_BIN:-git}" -C "$repo" "$@"
}

# Removes worktree, local branch, then origin branch; each step only if the one before succeeded.
# $4 is HEAD read just before prune_classify ran: a commit landing since then was never classified.
prune_apply_one() {
	local cwd="$1" path="$2" branch="$3" classified="$4" sha remote
	local why
	sha="$classified"
	# Probe origin before anything destructive: an unreadable or moved remote leaves everything in place.
	if [ -n "$branch" ]; then
		local errf
		errf="$(mktemp)" || { echo "remote unreadable (no tmp), nothing pruned"; return 1; }
		local rc=0 msg
		remote="$(prune_git_remote "$cwd" ls-remote origin "refs/heads/$branch" 2>"$errf")" || rc=$?
		msg="$(tail -1 "$errf")"
		rm -f "$errf"
		[ "$rc" = 0 ] || { echo "remote unreadable (${msg:-exit $rc}), nothing pruned"; return 1; }
		remote="$(awk -v r="refs/heads/$branch" '$2 == r {print $1}' <<<"$remote")"
		[ -z "$remote" ] || [ "$remote" = "$sha" ] || { echo "remote moved, nothing pruned"; return 1; }
	fi
	# Re-screened after the probe, right before the remove: the probe can take up to its timeout,
	# and a commit or an edit landing in that window was never classified.
	[ "$(git -C "$path" rev-parse HEAD 2>/dev/null)" = "$classified" ] \
		|| { echo "HEAD moved since classification, nothing pruned"; return 1; }
	why="$(prune_tree_is_noise_only "$path")" || { echo "$why, nothing pruned"; return 1; }
	# --force is needed for the untracked noise; ignored/secret-shaped files were screened out.
	git -C "$cwd" worktree remove --force "$path" 2>/dev/null || { echo "worktree remove failed"; return 1; }
	[ -n "$branch" ] || return 0
	git -C "$cwd" branch -D "$branch" >/dev/null 2>&1 || { echo "branch -D failed"; return 1; }
	if [ -n "$remote" ]; then
		# Lease on the classified sha: a push landing since the probe makes the delete fail.
		local err
		err="$(prune_git_remote "$cwd" push --force-with-lease="refs/heads/$branch:$sha" origin --delete "refs/heads/$branch" 2>&1 >/dev/null)" \
			|| { echo "push --delete failed (${err##*$'\n'}), origin/$branch state unconfirmed; deleted local branch was at $sha"; return 1; }
	fi
}

prune_worktrees() {
	local cwd="$1" apply="$2" db self main="" path="" branch="" line why head locked=0 failed=0 rpath rmain
	local min_age="${WORKTREE_PRUNE_MIN_AGE:-900}" pruned=0 kept=0 verb="WOULD-PRUNE"
	[ "$apply" = 1 ] && verb="PRUNED"

	db="$(prune_default_branch "$cwd")" || { echo "[prune] no origin default branch — nothing pruned"; return 1; }
	self="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || { echo "[prune] not a git repo"; return 1; }
	self="$(realpath "$self")" || return 1
	if ! gate_live_agent_surface "$cwd" || [ "$LIVE_AGENT_STATUS" != ok ]; then
		echo "[prune] live-agent surface UNKNOWN — keeping every worktree"
		return 1
	fi

	while IFS= read -r line; do
		case "$line" in
		"worktree "*) path="${line#worktree }"; branch=""; locked=0; [ -n "$main" ] || main="$path" ;;
		"branch "*) branch="${line#branch refs/heads/}" ;;
		"locked"*) locked=1 ;;
		"")
			if [ -n "$path" ]; then
				rpath="$(realpath "$path" 2>/dev/null)" || rpath="$path"
				rmain="$(realpath "$main" 2>/dev/null)" || rmain="$main"
				if [ "$rpath" = "$rmain" ] || [ "$rpath" = "$self" ] || [ "$branch" = "$db" ]; then
					:
				elif [ ! -d "$path" ]; then
					:
				elif [ "$locked" = 1 ]; then
					printf 'KEEP %s: locked\n' "$path"
					kept=$((kept + 1))
				elif ! head="$(git -C "$path" rev-parse HEAD 2>/dev/null)"; then
					printf 'KEEP %s: HEAD unreadable\n' "$path"
					kept=$((kept + 1))
				elif why="$(prune_classify "$cwd" "$path" "$branch" "$db" "$min_age")"; then
					if [ "$apply" = 1 ] && ! why="$(prune_apply_one "$cwd" "$path" "$branch" "$head")"; then
						# Past the probes the worktree may already be gone: say so, never "KEEP".
						case "$why" in
						*"nothing pruned") printf 'KEEP %s: %s\n' "$path" "$why"; kept=$((kept + 1)) ;;
						*) printf 'PARTIAL %s: %s\n' "$path" "$why"; failed=$((failed + 1)) ;;
						esac
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
	printf '[prune] %s: %d prunable, %d kept, %d partial%s\n' "$verb" "$pruned" "$kept" "$failed" \
		"$([ "$apply" = 1 ] || echo ' (dry-run; re-run with --apply)')"
	[ "$failed" = 0 ]
}

main() {
	local apply="${WORKTREE_PRUNE_APPLY:-0}" cwd="$PWD" a
	for a in "$@"; do
		case "$a" in
		--apply) apply=1 ;;
		*) cwd="$a" ;;
		esac
	done
	local rc=0 brc=0
	prune_worktrees "$cwd" "$apply" || rc=1
	# Branches with no worktree (#948), after the worktrees so theirs are already gone.
	# brc 2 = pass skipped on an unreadable forge/remote: kept, not a failure.
	prune_branches "$cwd" "$apply" || brc=$?
	[ "$brc" = 0 ] || [ "$brc" = 2 ] || rc=1
	return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
