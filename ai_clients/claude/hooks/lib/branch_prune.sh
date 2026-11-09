#!/bin/bash
# Branch PRUNE (dotfiles-linux-dev#948): worktree_prune.sh only examines branches that still have a
# worktree. This pass covers the rest — local branches with no worktree and origin branches —
# deleting one ONLY when content proves it shipped, and failing closed on any unreadable state.
#
# Sourced by worktree_prune.sh (which supplies prune_default_branch, prune_git_remote, prune_pr_state
# and the worktree_fanout.sh helpers); it is a library, never run directly. Dry run unless apply=1.
#
# Local branch (not default, gh-pages, nor checked out by any worktree) is deleted when
#   - its tip is an ancestor of origin/<default>, or
#   - its tip is contained in the head ref of a PR MERGED into <default>;
#   and the forge shows no OPEN PR from it.
# Origin branch (same exclusions, plus any branch a worktree holds), classified by the REST PR list:
#   - an OPEN PR                          -> keep
#   - a MERGED PR whose head holds the tip -> delete
#   - closed-unmerged or no PR            -> delete only when every line its commits add is on
#     origin/<default> and every binary file it changes equals origin/<default>'s; otherwise REPORT
#     what is missing (a superseded line is a person's call).
# Every delete re-reads the branch's PR state live right before acting (an unreadable read or an OPEN
# PR keeps it) and is conditional on the classified sha. The forge list is REST (a GraphQL latch must
# not blind it). An unreadable list skips the whole pass. PR heads are fetched into the private
# refs/prune-pr/* namespace, never refs/remotes/origin/pr/*, which may hold real branches.

BRANCH_PRUNE_PROTECTED=(gh-pages)
# Raw git: the rtk proxy has collapsed output mid-audit, and this parser reads diff headers.
BRANCH_PRUNE_GIT="${BRANCH_PRUNE_GIT:-/usr/bin/git}"
[ -x "$BRANCH_PRUNE_GIT" ] || BRANCH_PRUNE_GIT="$(command -v git)"
BRANCH_PRUNE_PR_NS="refs/prune-pr"

bp_git() { "$BRANCH_PRUNE_GIT" "$@"; }

# "<head-ref>\t<open|merged|closed>\t<base>\t<head-sha>\t<number>" per same-repo PR; rc 1 = unreadable.
# Overridden by tests.
branch_prune_pr_list() {
	local cwd="$1" slug
	local -a st
	slug="$(fanout_repo_slug "$cwd")" || return 1
	gh api --paginate "repos/$slug/pulls?state=all&per_page=100" 2>/dev/null \
		| jq -r --arg slug "$slug" '.[] | select(.head.repo.full_name == $slug)
			| [.head.ref, (if .state=="open" then "open" elif .merged_at then "merged" else "closed" end),
			   .base.ref, .head.sha, .number] | @tsv' 2>/dev/null
	st=("${PIPESTATUS[@]}")
	[ "${st[0]:-1}" = 0 ] && [ "${st[1]:-1}" = 0 ]
}

branch_prune_is_protected() {
	local name="$1" db="$2" p
	[ "$name" = "$db" ] && return 0
	for p in "${BRANCH_PRUNE_PROTECTED[@]}"; do
		[ "$name" = "$p" ] && return 0
	done
	return 1
}

# Branches any worktree has checked out, one per line.
branch_prune_checked_out() {
	bp_git -C "$1" worktree list --porcelain 2>/dev/null | sed -n 's|^branch refs/heads/||p'
}

# Prints what base..tip changes that origin/<db> lacks: one "path: line" per added line missing
# (first 5 per file) and one "path: binary content differs" per differing binary.
# rc 0 = nothing missing, 1 = missing (printed), 2 = unreadable (reason printed).
branch_prune_missing_lines() {
	local cwd="$1" db="$2" tip="$3" base diff_out num_out file="" line miss=0 out="" db_file in_hunk=0
	local a b path
	base="$(bp_git -C "$cwd" merge-base "origin/$db" "$tip" 2>/dev/null)" || { echo "no merge-base"; return 2; }
	diff_out="$(bp_git -C "$cwd" diff --no-color --no-ext-diff --no-renames -U0 "$base" "$tip" 2>/dev/null)" \
		|| { echo "diff unreadable"; return 2; }
	num_out="$(bp_git -C "$cwd" diff --no-ext-diff --no-renames --numstat "$base" "$tip" 2>/dev/null)" \
		|| { echo "diff unreadable"; return 2; }
	# Binary files carry no added lines: demand the exact blob on origin/<db>.
	while IFS=$'\t' read -r a b path; do
		[ "$a" = "-" ] && [ "$b" = "-" ] || continue
		[ "$(bp_git -C "$cwd" rev-parse "$tip:$path" 2>/dev/null)" = "$(bp_git -C "$cwd" rev-parse "origin/$db:$path" 2>/dev/null)" ] \
			&& [ -n "$(bp_git -C "$cwd" rev-parse "$tip:$path" 2>/dev/null)" ] && continue
		out+="${path}: binary content differs"$'\n'
	done <<<"$num_out"
	# Header lines are only those before a hunk: a content line "+++x" (an added "++x") is content.
	while IFS= read -r line; do
		case "$line" in
		"diff --git "*) in_hunk=0; file=""; continue ;;
		"@@ "*) in_hunk=1; continue ;;
		esac
		if [ "$in_hunk" = 0 ]; then
			case "$line" in
			"+++ b/"*)
				file="${line#+++ b/}"
				miss=0
				db_file="$(bp_git -C "$cwd" show "origin/$db:$file" 2>/dev/null)" || db_file=""
				;;
			esac
			continue
		fi
		case "$line" in
		"+"*)
			[ -n "$file" ] || continue
			line="${line#+}"
			[ -n "${line//[[:space:]]/}" ] || continue
			if ! grep -Fxq -- "$line" <<<"$db_file"; then
				miss=$((miss + 1))
				[ "$miss" -le 5 ] && out+="${file}: ${line}"$'\n'
			fi
			;;
		esac
	done <<<"$diff_out"
	[ -z "$out" ] && return 0
	printf '%s' "$out"
	return 1
}

# True when sha is contained in a merged-into-<db> PR head for this branch (rows from pr_list).
branch_prune_merged_covers() {
	local cwd="$1" branch="$2" sha="$3" db="$4" rows="$5" b st base hsha num
	while IFS=$'\t' read -r b st base hsha num; do
		[ "$b" = "$branch" ] && [ "$st" = merged ] && [ "$base" = "$db" ] || continue
		bp_git -C "$cwd" merge-base --is-ancestor "$sha" "$BRANCH_PRUNE_PR_NS/$num" 2>/dev/null && return 0
		bp_git -C "$cwd" merge-base --is-ancestor "$sha" "$hsha" 2>/dev/null && return 0
	done <<<"$rows"
	return 1
}

branch_prune_has_open_pr() {
	awk -F'\t' -v b="$2" '$1 == b && $2 == "open" {f=1} END {exit !f}' <<<"$1"
}

# Any merged-into-<db> PR head contains sha (the local test: a local name need not match a PR head).
branch_prune_any_merged_covers() {
	local cwd="$1" sha="$2" db="$3" rows="$4" b st base hsha num
	while IFS=$'\t' read -r b st base hsha num; do
		[ "$st" = merged ] && [ "$base" = "$db" ] || continue
		bp_git -C "$cwd" merge-base --is-ancestor "$sha" "$BRANCH_PRUNE_PR_NS/$num" 2>/dev/null && return 0
	done <<<"$rows"
	return 1
}

# Live re-read right before a delete: a PR opened after the snapshot must keep its head branch.
# rc 0 = safe (no open PR); prints the reason and rc 1 otherwise.
branch_prune_recheck_pr() {
	local state
	state="$(prune_pr_state "$1" "$2")" || { echo "forge unreadable on re-check"; return 1; }
	[ "$state" != open ] || { echo "PR opened since the snapshot"; return 1; }
}

branch_prune_local() {
	local cwd="$1" apply="$2" db="$3" rows="$4" checked="$5" name sha reason why verb="WOULD-DELETE-LOCAL"
	[ "$apply" = 1 ] && verb="DELETED-LOCAL"
	while IFS=$'\t' read -r name sha; do
		[ -n "$name" ] || continue
		branch_prune_is_protected "$name" "$db" && continue
		[[ $'\n'"$checked"$'\n' == *$'\n'"$name"$'\n'* ]] && continue
		if branch_prune_has_open_pr "$rows" "$name"; then
			printf 'KEEP-LOCAL %s: PR is OPEN\n' "$name"; continue
		fi
		if bp_git -C "$cwd" merge-base --is-ancestor "$sha" "origin/$db" 2>/dev/null; then
			reason="tip is an ancestor of origin/$db"
		elif branch_prune_any_merged_covers "$cwd" "$sha" "$db" "$rows"; then
			reason="tip is contained in a PR head merged into $db"
		else
			printf 'KEEP-LOCAL %s: not proven shipped\n' "$name"; continue
		fi
		if [ "$apply" = 1 ]; then
			why="$(branch_prune_recheck_pr "$cwd" "$name")" || { printf 'KEEP-LOCAL %s: %s\n' "$name" "$why"; continue; }
			# Worktrees re-read just before the delete; update-ref deletes only if the tip is still $sha.
			if [[ $'\n'"$(branch_prune_checked_out "$cwd")"$'\n' == *$'\n'"$name"$'\n'* ]]; then
				printf 'KEEP-LOCAL %s: checked out since the snapshot\n' "$name"; continue
			fi
			if ! bp_git -C "$cwd" update-ref -d "refs/heads/$name" "$sha" 2>/dev/null; then
				printf 'KEEP-LOCAL %s: tip moved or delete failed\n' "$name"; BRANCH_PRUNE_FAILED=$((BRANCH_PRUNE_FAILED + 1)); continue
			fi
		fi
		printf '%s %s: %s\n' "$verb" "$name" "$reason"
		BRANCH_PRUNE_DONE=$((BRANCH_PRUNE_DONE + 1))
	done < <(bp_git -C "$cwd" for-each-ref --format='%(refname:short)	%(objectname)' refs/heads 2>/dev/null)
}

branch_prune_remote() {
	local cwd="$1" apply="$2" db="$3" rows="$4" checked="$5" name sha reason missing rc why err verb="WOULD-DELETE-REMOTE"
	[ "$apply" = 1 ] && verb="DELETED-REMOTE"
	while IFS=$'\t' read -r name sha; do
		name="${name#origin/}"
		case "$name" in HEAD | origin) continue ;; esac
		branch_prune_is_protected "$name" "$db" && continue
		if [[ $'\n'"$checked"$'\n' == *$'\n'"$name"$'\n'* ]]; then
			printf 'KEEP-REMOTE %s: held by a worktree\n' "$name"; continue
		fi
		if branch_prune_has_open_pr "$rows" "$name"; then
			printf 'KEEP-REMOTE %s: PR is OPEN\n' "$name"; continue
		fi
		if bp_git -C "$cwd" merge-base --is-ancestor "$sha" "origin/$db" 2>/dev/null; then
			reason="tip is an ancestor of origin/$db"
		elif branch_prune_merged_covers "$cwd" "$name" "$sha" "$db" "$rows"; then
			reason="tip is contained in a merged PR head"
		else
			rc=0
			missing="$(branch_prune_missing_lines "$cwd" "$db" "$sha")" || rc=$?
			if [ "$rc" != 0 ]; then
				if [ "$rc" = 1 ]; then
					printf 'REPORT-REMOTE %s: content missing from origin/%s (judgement call, not deleted):\n' "$name" "$db"
					sed 's/^/    /' <<<"$missing"
				else
					printf 'KEEP-REMOTE %s: %s\n' "$name" "$missing"
				fi
				continue
			fi
			reason="every added line is on origin/$db"
		fi
		if [ "$apply" = 1 ]; then
			why="$(branch_prune_recheck_pr "$cwd" "$name")" || { printf 'KEEP-REMOTE %s: %s\n' "$name" "$why"; continue; }
			err="$(prune_git_remote "$cwd" push --force-with-lease="refs/heads/$name:$sha" origin --delete "refs/heads/$name" 2>&1 >/dev/null)" \
				|| { printf 'KEEP-REMOTE %s: push --delete failed (%s)\n' "$name" "${err##*$'\n'}"; BRANCH_PRUNE_FAILED=$((BRANCH_PRUNE_FAILED + 1)); continue; }
		fi
		printf '%s %s: %s\n' "$verb" "$name" "$reason"
		BRANCH_PRUNE_DONE=$((BRANCH_PRUNE_DONE + 1))
	done < <(bp_git -C "$cwd" for-each-ref --format='%(refname:short)	%(objectname)' refs/remotes/origin 2>/dev/null)
}

# Drops the private PR-head refs so nothing lingers after the pass.
branch_prune_drop_pr_refs() {
	local ref
	while IFS= read -r ref; do
		[ -n "$ref" ] && bp_git -C "$1" update-ref -d "$ref" 2>/dev/null
	done < <(bp_git -C "$1" for-each-ref --format='%(refname)' "$BRANCH_PRUNE_PR_NS" 2>/dev/null)
	return 0
}

# Usage: prune_branches <repo> <apply 0|1>; rc 1 = a delete failed, rc 2 = pass skipped (unreadable).
prune_branches() {
	local cwd="$1" apply="$2" db rows checked
	# Read by prune_git_remote (worktree_prune.sh) through bash dynamic scope: raw git for fetch/push.
	# shellcheck disable=SC2034
	local PRUNE_GIT_BIN="$BRANCH_PRUNE_GIT"
	BRANCH_PRUNE_DONE=0
	BRANCH_PRUNE_FAILED=0
	db="$(prune_default_branch "$cwd")" || { echo "[branch-prune] no origin default branch — skipped"; return 2; }
	branch_prune_drop_pr_refs "$cwd"
	prune_git_remote "$cwd" fetch -q --prune origin 2>/dev/null \
		|| { echo "[branch-prune] fetch --prune failed — skipped"; return 2; }
	if ! prune_git_remote "$cwd" fetch -q origin "+refs/pull/*/head:$BRANCH_PRUNE_PR_NS/*" 2>/dev/null; then
		branch_prune_drop_pr_refs "$cwd"
		echo "[branch-prune] fetch of PR heads failed — skipped"
		return 2
	fi
	if ! rows="$(branch_prune_pr_list "$cwd")"; then
		branch_prune_drop_pr_refs "$cwd"
		echo "[branch-prune] forge PR list unreadable — skipped"
		return 2
	fi
	checked="$(branch_prune_checked_out "$cwd")"
	branch_prune_local "$cwd" "$apply" "$db" "$rows" "$checked"
	branch_prune_remote "$cwd" "$apply" "$db" "$rows" "$checked"
	branch_prune_drop_pr_refs "$cwd"
	printf '[branch-prune] %d branch(es) %s, %d failed%s\n' "$BRANCH_PRUNE_DONE" \
		"$([ "$apply" = 1 ] && echo deleted || echo deletable)" "$BRANCH_PRUNE_FAILED" \
		"$([ "$apply" = 1 ] || echo ' (dry-run; re-run with --apply)')"
	[ "$BRANCH_PRUNE_FAILED" = 0 ]
}
