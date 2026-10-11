#!/bin/bash
# PostToolUse(Bash) hook: push a loop-owned agent branch after every `git commit`.
#
# Push = claim (dotfiles-linux-dev#715): the pushed branch is the machine-neutral
# "in progress" marker. Loop-owned means a LINKED worktree on a branch named
# <feat|fix|chore|docs|refactor|test|hotfix>/<slug>-<issue number>. Anything else
# (main checkout, ad-hoc branches) is untouched. Never blocks: a failed push
# leaves <git-dir>/pending-push and the next commit retries. See docs/ for the rule.
set -u

GIT=/usr/bin/git
command -v jq >/dev/null 2>&1 || exit 0

LOOP_BRANCH_RE='^(feat|fix|chore|docs|refactor|test|hotfix)/.+-[0-9]+$'

# _resolve_dir BASE DIR: strip quotes, expand a leading ~, anchor a relative DIR at BASE.
_resolve_dir() {
	local base="$1" d="$2"

	d="${d%[\"\']}"
	d="${d#[\"\']}"
	d="${d/#\~/$HOME}"
	case "$d" in
		/*) printf '%s' "$d" ;;
		*) printf '%s/%s' "$base" "$d" ;;
	esac
}

main() {
	local payload cwd cmd branch gitdir prefix dir pre

	payload="$(cat)"
	cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
	# "/" is a boundary so /usr/bin/git commit matches too.
	[[ "$cmd" =~ (^|[[:space:];\&\|/])git[[:space:]]+(-C[[:space:]]+(\"[^\"]*\"|\'[^\']*\'|[^[:space:]]+)[[:space:]]+)?commit([[:space:]]|$) ]] || exit 0
	prefix="${cmd%%"${BASH_REMATCH[0]}"*}"
	dir="${BASH_REMATCH[3]}"

	cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
	[ -n "$cwd" ] || cwd="${CLAUDE_PROJECT_DIR:-$PWD}"

	# The commit lands where the command points it, not where the shell sits:
	# apply every `cd <dir>` before it in order (each relative to the last),
	# then `git -C <dir>` on top. A cd right after `||` only runs if the left
	# side failed, so it is not guaranteed and is skipped.
	# ponytail: unquoted cd targets only.
	while [[ "$prefix" =~ (^|[[:space:];\&\|])cd[[:space:]]+([^[:space:];\&\|]+)(.*)$ ]]; do
		pre="${prefix%"${BASH_REMATCH[0]}"}"
		pre="${pre%"${pre##*[![:space:]]}"}"
		[[ "$pre" == *'|' || "${BASH_REMATCH[1]}" == '|' ]] || cwd="$(_resolve_dir "$cwd" "${BASH_REMATCH[2]}")"
		prefix="${BASH_REMATCH[3]}"
	done
	[ -z "$dir" ] || cwd="$(_resolve_dir "$cwd" "$dir")"

	gitdir="$($GIT -C "$cwd" rev-parse --absolute-git-dir 2>/dev/null)" || exit 0
	[ "$gitdir" != "$($GIT -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ] || exit 0

	branch="$($GIT -C "$cwd" symbolic-ref --short -q HEAD)" || exit 0
	[[ "$branch" =~ $LOOP_BRANCH_RE ]] || exit 0

	# Bounded and prompt-free: a stalled remote must reach the pending-push branch, not hang the hook.
	if GIT_TERMINAL_PROMPT=0 timeout 30 $GIT -C "$cwd" push -q -u origin "$branch" >/dev/null 2>&1; then
		rm -f "$gitdir/pending-push"
	else
		date +%s >"$gitdir/pending-push"
		echo "agent_branch_push_guard: push of $branch failed; pending, retried on the next commit." >&2
	fi
	exit 0
}

main "$@"
