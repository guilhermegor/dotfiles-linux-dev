#!/bin/bash
# is_loop_branch BRANCH: a branch a dispatch created (dotfiles-linux-dev#715, #830).
# Two shapes: <type>/<N>-<slug> (BlueprintX check_pr_policy.sh) and the older
# <type>/<slug>-<N>, kept so in-flight branches stay covered.
LOOP_BRANCH_RE='^(feat|fix|chore|docs|refactor|test|hotfix)/([0-9]+-.+|.+-[0-9]+)$'

is_loop_branch() {
	[[ "$1" =~ $LOOP_BRANCH_RE ]]
}

# branch_list_has_issue LIST N: does any branch in the newline-separated LIST carry issue
# number N, in either shape? Anchored on the "/" or "-" boundary so #5 never matches #15.
branch_list_has_issue() {
	local branch
	while IFS= read -r branch; do
		[[ "$branch" == */"$2"-* || "$branch" == *-"$2" ]] && return 0
	done <<<"$1"
	return 1
}
