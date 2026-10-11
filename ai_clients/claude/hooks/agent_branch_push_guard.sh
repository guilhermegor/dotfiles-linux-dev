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

main() {
	local payload cwd cmd branch gitdir

	payload="$(cat)"
	cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
	[[ "$cmd" =~ (^|[[:space:];&|])git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?commit([[:space:]]|$) ]] || exit 0

	cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
	[ -n "$cwd" ] || cwd="${CLAUDE_PROJECT_DIR:-$PWD}"

	gitdir="$($GIT -C "$cwd" rev-parse --absolute-git-dir 2>/dev/null)" || exit 0
	[ "$gitdir" != "$($GIT -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ] || exit 0

	branch="$($GIT -C "$cwd" symbolic-ref --short -q HEAD)" || exit 0
	[[ "$branch" =~ $LOOP_BRANCH_RE ]] || exit 0

	if $GIT -C "$cwd" push -q -u origin "$branch" >/dev/null 2>&1; then
		rm -f "$gitdir/pending-push"
	else
		date +%s >"$gitdir/pending-push"
		echo "agent_branch_push_guard: push of $branch failed; pending, retried on the next commit." >&2
	fi
	exit 0
}

main "$@"
