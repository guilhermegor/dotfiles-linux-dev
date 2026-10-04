#!/bin/bash
# Shared worktree rescue fan-out (dotfiles-linux-dev#383): ONE implementation of "walk every worktree
# of this repo and classify its dirty state", extracted out of session_start_context.sh so a
# second hook (quota_gap_rescue.sh, a UserPromptSubmit hook re-running the same check after a
# quota gap) can call it instead of re-deriving the classifier — same shared-lib pattern as
# hooks/lib/free_surface.sh and hooks/lib/review_thread_gate.sh, and the same reason: a sweep
# that re-implements a gate "inherited its bug plus one of its own".
#
# session_start_context.sh sources this file and its output is unchanged by the extraction
# (regression bar; see tests/session_start_context.bats, which still exercises these two
# functions through that file unmodified).
set -u

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	echo "worktree_fanout.sh is meant to be sourced, not executed." >&2
	exit 1
fi

# Classifies a dirty worktree's diff against HEAD as "interrupted" (net new work worth
# resuming) or "stale" (a revert of content already shipped on the default branch) — the
# SIGN of the diff is the signal, not the file count (dotfiles-linux-dev#318; lessons-claude-toolchain:
# a-staged-deletion-set-is-a-stale-revert-not-lost-work.md — four worktrees reporting 42/39/
# 90/42 dirty files were stale reverts, the one holding real work reported 5). Prints
# "<verdict>\t<insertions>\t<deletions>". Fails open to "interrupted" on any ambiguity or
# lookup failure — silently hiding real work is the worse mistake for a report nobody blocks on.
classify_worktree_diff() {
	local path="$1" default_branch="$2"
	local numstat ins=0 del=0 untracked a d

	numstat="$(git -C "$path" diff HEAD --numstat 2>/dev/null)"
	if [ -n "$numstat" ]; then
		while IFS=$'\t' read -r a d _; do
			[[ "$a" =~ ^[0-9]+$ ]] && ins=$((ins + a))
			[[ "$d" =~ ^[0-9]+$ ]] && del=$((del + d))
		done <<<"$numstat"
	fi
	untracked="$(git -C "$path" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d '[:space:]')"
	[ -n "$untracked" ] || untracked=0

	if [ "$untracked" -gt 0 ] || [ "$ins" -gt "$del" ]; then
		printf 'interrupted\t%s\t%s\n' "$ins" "$del"
		return
	fi

	if [ "$del" -gt "$ins" ] && [ -n "$default_branch" ]; then
		# Confirm before calling it stale: do the deleted paths already exist on
		# origin/<default_branch>? Capped at 5 lookups — this hook must stay fast.
		local deleted p checked=0 confirmed=0
		deleted="$(git -C "$path" diff HEAD --name-status 2>/dev/null | awk '$1=="D"{print $2}')"
		while IFS= read -r p; do
			[ -z "$p" ] && continue
			checked=$((checked + 1))
			git -C "$path" cat-file -e "origin/$default_branch:$p" 2>/dev/null && confirmed=$((confirmed + 1))
			[ "$checked" -ge 5 ] && break
		done <<<"$deleted"
		if [ "$confirmed" -gt 0 ]; then
			printf 'stale\t%s\t%s\n' "$ins" "$del"
			return
		fi
	fi

	printf 'interrupted\t%s\t%s\n' "$ins" "$del"
}

# owner/repo parsed from the origin remote URL, no network call. Empty when there is no
# GitHub origin (a non-GitHub repo skips the whole GitHub half, silently).
fanout_repo_slug() {
	local cwd="$1" url
	url="$(git -C "$cwd" remote get-url origin 2>/dev/null)" || return 1
	[ -n "$url" ] || return 1
	url="${url%.git}"
	case "$url" in
	*github.com[:/]*) printf '%s\n' "${url#*github.com}" | sed 's#^[:/]##' ;;
	*) return 1 ;;
	esac
}

# The PR payload fanout_worktrees() and fanout_pr_summary() read, shared by every caller so
# none re-derives the query (dotfiles-linux-dev#616: quota_gap_rescue.sh hard-coded "forge
# unreadable" and never ran the merged-PR exclusion). Prints the raw JSON, or nothing when
# gh is missing/fails — callers test `jq -e 'type=="array"'` before trusting it.
fanout_pr_json() {
	local slug="$1"
	# gh pr list returns 30 PRs when --limit is omitted. The worktree walk matches local
	# branches against this list (merged heads, branches without a PR), and a live agent
	# worktree can belong to a PR further back than 30 (dotfiles-dev#606). A branch the list
	# misses is still reported, so a short list adds noise, never a missed rescue.
	local pr_limit="${FANOUT_PR_LIMIT:-100}"
	if command -v timeout >/dev/null 2>&1; then
		timeout 8 gh pr list --repo "$slug" --state all --limit "$pr_limit" \
			--json number,url,state,headRefName,headRefOid,reviews,createdAt 2>/dev/null
	else
		gh pr list --repo "$slug" --state all --limit "$pr_limit" \
			--json number,url,state,headRefName,headRefOid,reviews,createdAt 2>/dev/null
	fi
}

# True when a MERGED PR for <branch> shipped everything the worktree at <path> holds: the
# local HEAD IS the merged head, or an ANCESTOR of it (the agent pushed more commits after
# this worktree's last one — dotfiles-linux-dev#616). $3 is the "<branch>\t<headRefOid>" list.
# The ancestor test needs the merged head object locally; when it is absent the check fails
# toward reporting, never toward hiding work.
merged_pr_covers_head() {
	local path="$1" branch="$2" merged_heads="$3" head oid
	head="$(git -C "$path" rev-parse HEAD 2>/dev/null)" || return 1
	while IFS=$'\t' read -r b oid; do
		[ "$b" = "$branch" ] && [ -n "$oid" ] || continue
		[ "$oid" = "$head" ] && return 0
		git -C "$path" merge-base --is-ancestor "$head" "$oid" 2>/dev/null && return 0
	done <<<"$merged_heads"
	return 1
}

# `git worktree list` entries for THIS repo (parallel-agent worktrees included) — unpushed
# commits, classified dirty state, and (when the GitHub half answered) a branch that was
# pushed but never got a PR. One walk, no per-branch `gh` calls.
fanout_worktrees() {
	local cwd="$1" github_ok="$2" json="$3"
	local pr_branches="" merged_heads="" default_branch path="" branch="" name uncommitted ahead pushed
	local has_upstream never_pushed
	local -a interrupted_names=()

	if [ "$github_ok" = "1" ]; then
		pr_branches="$(printf '%s' "$json" | jq -r '.[].headRefName' 2>/dev/null)"
		# "<branch>\t<headRefOid>" of every merged PR, from the same query — no per-branch call.
		merged_heads="$(printf '%s' "$json" \
			| jq -r '.[] | select(.state=="MERGED") | "\(.headRefName)\t\(.headRefOid)"' 2>/dev/null)"
	fi
	default_branch="$(git -C "$cwd" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
	default_branch="${default_branch#origin/}"

	while IFS= read -r line; do
		case "$line" in
		"worktree "*)
			path="${line#worktree }"
			branch=""
			;;
		"branch "*)
			branch="${line#branch refs/heads/}"
			;;
		"")
			if [ -n "$path" ] && [ -d "$path" ]; then
				name="$(basename "$path")"
				uncommitted="$(git -C "$path" status --porcelain 2>/dev/null | wc -l | tr -d '[:space:]')"
				[ -n "$uncommitted" ] || uncommitted=0
				ahead=0
				pushed=0
				has_upstream=0
				if git -C "$path" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
					has_upstream=1
					ahead="$(git -C "$path" rev-list --count '@{upstream}..HEAD' 2>/dev/null)"
					[ -n "$ahead" ] || ahead=0
				fi
				# "Pushed" means the branch has ITS OWN remote ref, never merely that
				# `@{upstream}` resolves — a worktree created with
				# `git worktree add -b <name> origin/master` tracks origin/master as its
				# upstream from birth, with no ref of its own on the remote (dotfiles-linux-dev#457).
				# Same oracle subagent_stop_sweep.sh already uses for this predicate.
				if [ -n "$branch" ] \
					&& git -C "$path" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null 2>&1; then
					pushed=1
				fi

				[ "$ahead" -gt 0 ] && printf '[fan-out] worktree %s: %s commit(s) not pushed\n' "$name" "$ahead"

				# Neither `@{upstream}` nor a remote ref of its own: a branch that was NEVER
				# pushed (dotfiles-linux-dev#571 — the most common thing a killed agent leaves
				# behind: it committed, then died before `git push -u`). Count only commits
				# whose patch isn't already on origin/<default> (`git cherry`, "+" = not yet
				# applied there). That drops a ONE-commit squash merge only: squashing several
				# commits yields a patch-id equal to none of them, so every one stays "+"
				# (dotfiles-linux-dev#606). The forge settles that case — a MERGED PR for this branch
				# whose headRefOid is the local HEAD (or contains it as an ancestor) shipped what is here. With the
				# forge unreadable (github_ok=0) merged_heads is empty, so it keeps reporting.
				if [ "$has_upstream" = "0" ] && [ "$pushed" = "0" ] && [ -n "$branch" ] \
					&& [ -n "$default_branch" ] && [ "$branch" != "$default_branch" ] \
					&& ! merged_pr_covers_head "$path" "$branch" "$merged_heads"; then
					never_pushed="$(git -C "$path" cherry "origin/$default_branch" HEAD 2>/dev/null \
						| grep -c '^+')"
					[ -n "$never_pushed" ] || never_pushed=0
					if [ "$never_pushed" -gt 0 ]; then
						printf '[fan-out] worktree %s: %s commit(s) never pushed — no upstream\n' \
							"$name" "$never_pushed"
						interrupted_names+=("$name")
					fi
				fi

				if [ "$uncommitted" -gt 0 ]; then
					local verdict ins del anon_note=""
					IFS=$'\t' read -r verdict ins del <<<"$(classify_worktree_diff "$path" "$default_branch")"
					case "$branch" in
					worktree-agent-*) anon_note=" [anonymous branch, no issue reference]" ;;
					esac
					if [ "$verdict" = "stale" ]; then
						printf '[fan-out] worktree %s: %s uncommitted file(s) — stale revert, do NOT rescue (+%s/-%s already on origin)%s\n' \
							"$name" "$uncommitted" "$ins" "$del" "$anon_note"
					else
						printf '[fan-out] worktree %s: %s uncommitted file(s) — INTERRUPTED WORK, resume it (+%s/-%s)%s\n' \
							"$name" "$uncommitted" "$ins" "$del" "$anon_note"
						interrupted_names+=("$name")
					fi
				fi

				if [ "$github_ok" = "1" ] && [ "$pushed" = "1" ] && [ -n "$branch" ] \
					&& [ "$branch" != "$default_branch" ] \
					&& ! printf '%s\n' "$pr_branches" | grep -qxF "$branch"; then
					printf '[fan-out] branch %s pushed with NO PR\n' "$branch"
				fi
			fi
			path=""
			branch=""
			;;
		esac
	done < <(git -C "$cwd" worktree list --porcelain 2>/dev/null; printf '\n')

	if [ "${#interrupted_names[@]}" -gt 0 ]; then
		local joined
		joined="$(IFS=', '; printf '%s' "${interrupted_names[*]}")"
		printf '[fan-out] RESUME %s worktree(s) holding interrupted work: %s — SendMessage to each agent name, staggered; never a fresh Agent call.\n' \
			"${#interrupted_names[@]}" "$joined"
	fi
}
