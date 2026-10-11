#!/bin/bash
# is_loop_branch BRANCH: a branch a dispatch created, <type>/<slug>-<issue> (dotfiles-linux-dev#715).
LOOP_BRANCH_RE='^(feat|fix|chore|docs|refactor|test|hotfix)/.+-[0-9]+$'

is_loop_branch() {
	[[ "$1" =~ $LOOP_BRANCH_RE ]]
}
