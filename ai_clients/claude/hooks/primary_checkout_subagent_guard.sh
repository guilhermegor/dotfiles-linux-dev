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

command -v jq >/dev/null 2>&1 || { echo "BLOCKED: jq not found in PATH - guard fails closed (#1162)" >&2; exit 2; }

ESCAPE_HATCH='ALLOW_PRIMARY_CHECKOUT_MOVE=1'
# `/` in the boundary class admits an absolute executable (`/usr/bin/git`); group 3 is the -C path.
MOVES_HEAD_RE='(^|[;&|/[:space:]])git[[:space:]]+(-C[[:space:]]+([^[:space:]]+)[[:space:]]+)?(reset|switch|checkout)([[:space:]]|$)'
BRANCH_PRESERVING_RE='git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?checkout[[:space:]]+(--|\.)([[:space:]]|$)'
CD_RE='^[[:space:]]*cd[[:space:]]+([^[:space:]]+)'

# Prints <base>/<path> (or <path> when absolute) and succeeds only when it is a directory.
resolve_dir() {
	local p="${2//[\"\']/}"
	[[ "$p" == /* ]] || p="$1/$p"
	[[ -d "$p" ]] || return 1
	printf '%s' "$p"
}

# Prints the first directory in which a segment of $1 moves HEAD while that directory is a
# primary checkout on its default branch; fails when there is none. Each `;`/`&`/`|`/newline
# segment is judged alone, so a branch-preserving `git checkout -- f` cannot exempt a `git reset`
# chained after it, and the target is the segment's `git -C <path>` (or an earlier `cd <path>`)
# rather than only the payload cwd. Unresolvable paths are skipped (fail open).
primary_move_target() {
	local command="$1" dir="$2" seg cpath target
	while IFS= read -r seg; do
		if [[ "$seg" =~ $CD_RE ]]; then
			dir="$(resolve_dir "$dir" "${BASH_REMATCH[1]}")" || return 1
			continue
		fi
		[[ "$seg" =~ $MOVES_HEAD_RE ]] || continue
		cpath="${BASH_REMATCH[3]}"
		[[ "$seg" =~ $BRANCH_PRESERVING_RE ]] && continue
		target="$dir"
		if [[ -n "$cpath" ]]; then
			target="$(resolve_dir "$dir" "$cpath")" || continue
		fi
		if is_primary_on_default_branch "$target"; then
			printf '%s' "$target"
			return 0
		fi
	done < <(printf '%s\n' "$command" | tr ';&|' '\n')
	return 1
}

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
	local payload command cwd agent target
	payload="$(cat)"
	[[ "$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)" == "Bash" ]] || exit 0

	agent="$(printf '%s' "$payload" | jq -r '.agent_id // empty' 2>/dev/null)"
	[[ -n "$agent" ]] || exit 0

	command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
	[[ "$command" == *"$ESCAPE_HATCH"* ]] && exit 0

	cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
	[[ -n "$cwd" && -d "$cwd" ]] || exit 0
	target="$(primary_move_target "$command" "$cwd")" || exit 0

	cat >&2 <<EOF
BLOCKED: a subagent ($agent) tried to move HEAD in the PRIMARY checkout ($target).
If your worktree was torn down (you were resumed after a limit), do not fall back to
the primary checkout: create your own worktree by explicit path first, e.g.
  git -C $target worktree add <absolute-path> origin/<branch>
then run every git command with that path. (dotfiles-linux-dev#1081)
Deliberate move: prefix the command with $ESCAPE_HATCH.
EOF
	exit 2
}

main "$@"
