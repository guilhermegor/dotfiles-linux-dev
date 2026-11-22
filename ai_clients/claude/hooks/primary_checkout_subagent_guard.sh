#!/bin/bash
# PreToolUse (Bash matcher) hook: refuse `git reset` / `git checkout` / `git switch`
# issued by a SUBAGENT inside the PRIMARY checkout while it sits on the default
# branch — dotfiles-linux-dev#1081.
#
# Measured 2026-11-01 (blueprintx): `review-pr-916` hit the 5h limit before editing and
# the harness removed its unchanged worktree. On `SendMessage` resume its cwd was gone,
# so it ran "reset my branch to the PR head" in the primary checkout: `main` moved to
# `origin/feat/914-...` and back 21 s later (reflog), and the rescue sweep in that
# window reported `main dirty=0 unpushed=2`.
#
# A subagent is recognised by the `agent_id` the harness puts in the hook payload; the
# primary checkout by `--git-dir` == `--git-common-dir`. Branch-preserving forms
# (`git checkout -- <file>`, `git checkout .`) are allowed.
#
# Hook I/O contract: silent on stdout; exit 2 + stderr to block. Fails OPEN on
# anything it cannot resolve (no jq, no cwd, not a repo, detached HEAD).
# Escape hatch: prefix the command with ALLOW_PRIMARY_CHECKOUT_MOVE=1.
set -u

command -v jq >/dev/null 2>&1 || exit 0

ESCAPE_HATCH='ALLOW_PRIMARY_CHECKOUT_MOVE=1'
MOVES_HEAD_RE='(^|[;&|[:space:]])git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?(reset|switch|checkout)([[:space:]]|$)'
BRANCH_PRESERVING_RE='git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?checkout[[:space:]]+(--|\.)([[:space:]]|$)'

is_primary_on_default_branch() {
	local cwd="$1" gdir common branch default
	gdir="$(git -C "$cwd" rev-parse --path-format=absolute --git-dir 2>/dev/null)" || return 1
	common="$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
	[[ "$gdir" == "$common" ]] || return 1
	branch="$(git -C "$cwd" symbolic-ref --quiet --short HEAD 2>/dev/null)" || return 1
	default="$(git -C "$cwd" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
	default="${default#origin/}"
	[[ "$branch" == "$default" || "$branch" == "master" || "$branch" == "main" ]]
}

main() {
	local payload command cwd agent
	payload="$(cat)"
	[[ "$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)" == "Bash" ]] || exit 0

	agent="$(printf '%s' "$payload" | jq -r '.agent_id // empty' 2>/dev/null)"
	[[ -n "$agent" ]] || exit 0

	command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
	[[ "$command" == *"$ESCAPE_HATCH"* ]] && exit 0
	[[ "$command" =~ $MOVES_HEAD_RE ]] || exit 0
	[[ "$command" =~ $BRANCH_PRESERVING_RE ]] && exit 0

	cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
	[[ -n "$cwd" && -d "$cwd" ]] || exit 0
	is_primary_on_default_branch "$cwd" || exit 0

	cat >&2 <<EOF
BLOCKED: a subagent ($agent) tried to move HEAD in the PRIMARY checkout ($cwd).
If your worktree was torn down (you were resumed after a limit), do not fall back to
the primary checkout: create your own worktree by explicit path first, e.g.
  git -C $cwd worktree add <absolute-path> origin/<branch>
then run every git command with that path. (dotfiles-linux-dev#1081)
Deliberate move: prefix the command with $ESCAPE_HATCH.
EOF
	exit 2
}

main "$@"
