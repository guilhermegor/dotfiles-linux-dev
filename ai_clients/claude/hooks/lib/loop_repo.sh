#!/bin/bash
# Which repo did the dev-loop actually run against? (dotfiles-linux-dev#1125)
#
# The four dev-loop Stop guards (round_dispatch_guard, dispatch_free_surface_guard,
# review_fanout_guard, open_review_threads_nudge) used to judge the repo of the Stop payload's
# `.cwd`. An orchestrator that `cd`s into another repo only to read an issue moved the guards
# onto that repo: measured 2026-11-23, `/dev-loop blueprintx` plus a `cd ~/github/greenfield`
# made both dispatch guards demand 11 greenfield issues on every turn end, none of them asked for.
#
# This is the ONE implementation all four call. The repo is read from what the loop was told,
# not from where the shell happens to stand:
#
#   1. the args of the LAST dev-loop invocation in the transcript — a Skill tool_use
#      (`dev-loop` / `s:dev-loop`, `.input.args`) or a `/dev-loop` slash command
#      (`<command-args>…</command-args>`), whichever came last;
#   2. fallback to the caller's cwd, announced as a fallback, when no invocation is recorded or
#      the invocation names no repo (`/dev-loop` bare, or free text such as "resolve the open
#      issue" whose first word is no checkout).
#
# What counts as "naming a repo" is the FIRST word of the args:
#   ~/x/y, /x/y         a path: must be a git work tree, else UNKNOWN
#   owner/name          looked up as <root>/name (root: $DEV_LOOP_REPOS_ROOT, default ~/github):
#                       must be a git work tree, else UNKNOWN
#   name                the same lookup, but a miss is "named no repo" (cwd fallback), because a
#                       bare word is indistinguishable from free text
# UNKNOWN is never a silent pass on the cwd repo: the caller blocks once with
# loop_repo_unknown_message (the repo's gate contract, ai_clients/CLAUDE.md).
#
# Sets, on every call:
#   LOOP_REPO_DIR     the directory to judge (empty on UNKNOWN)
#   LOOP_REPO_SOURCE  invocation | cwd | unknown
#   LOOP_REPO_LABEL   one line naming the repo and where it came from, for every guard message
set -u
LOOP_REPO_LABEL="${LOOP_REPO_LABEL:-}"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	echo "loop_repo.sh is meant to be sourced, not executed." >&2
	exit 1
fi

# loop_invocation_args TRANSCRIPT
# Prints one line per dev-loop invocation, in transcript order: the args (tabs and newlines
# flattened), possibly empty. No output = no invocation recorded. Parsed with jq, never grepped:
# key-value spacing is not part of the JSONL contract.
loop_invocation_args() {
	jq -R -r '
		fromjson?
		| .message.content? as $content
		| ( $content[]?
			| select(type == "object" and .type == "tool_use" and .name == "Skill"
				and (.input.skill == "dev-loop" or .input.skill == "s:dev-loop"))
			| (.input.args // "") | gsub("[\n\t]"; " ") ),
		  ( select(.type == "user")
			| ($content | if type == "string" then .
				else ([.[]? | select(type == "object" and .type == "text") | .text // ""] | join("\n")) end)
			| select(test("<command-name>/([A-Za-z0-9_-]+:)?dev-loop</command-name>"))
			| (capture("<command-args>(?<a>[^<]*)</command-args>")? // {a: ""}).a
			| gsub("[\n\t]"; " ") )
	' "$1" 2>/dev/null
}

# LOOP_ROUND_JQ - jq defs, the ONE recogniser of "this record is a dev-loop round" (#1135).
# `loop_round($c)` emits "LOOP" once per invocation in a record's message.content `$c`:
# a Skill tool_use named `dev-loop` / `s:dev-loop`, or a user turn carrying the
# `<command-name>/dev-loop</command-name>` (or `/s:dev-loop`) marker. A user turn that merely
# mentions `/dev-loop` has no marker and does not count. Guards needing the stream in order
# (round_dispatch_guard) prepend this to their own program; the rest call loop_round_invoked.
# `loop_block` is the per-block half (a Skill tool_use), `loop_command($c)` the per-record half
# (a user turn), split so a caller walking blocks in order can interleave its own tokens.
LOOP_ROUND_JQ='def loop_block:
	select(type == "object" and .type == "tool_use" and .name == "Skill"
		and (.input.skill == "dev-loop" or .input.skill == "s:dev-loop"))
	| "LOOP";
def loop_command($c):
	select(.type == "user")
	| ($c | if type == "string" then .
		else ([.[]? | select(type == "object" and .type == "text") | .text // ""] | join("\n")) end)
	| select(test("<command-name>/([A-Za-z0-9_-]+:)?dev-loop</command-name>"))
	| "LOOP";
def loop_round($c): ($c[]? | loop_block), loop_command($c);
'

# loop_round_invoked TRANSCRIPT
# True when the transcript ever ran a dev-loop round, in any of the four shapes.
loop_round_invoked() {
	[ -r "$1" ] || return 1
	jq -r "$LOOP_ROUND_JQ"'select(.message.content != null) | loop_round(.message.content)' \
		"$1" 2>/dev/null | grep -q LOOP
}

# _loop_repo_first_word ARGS — first whitespace-delimited word, minus quotes and trailing punctuation.
_loop_repo_first_word() {
	local word="${1#"${1%%[![:space:]]*}"}"
	word="${word%%[[:space:]]*}"
	word="${word#[\"\'\`]}"
	word="${word%[\"\'\`,;:.]}"
	printf '%s' "$word"
}

_loop_repo_is_checkout() {
	# `--is-inside-work-tree` exits 0 and prints "false" inside a .git dir or a bare repo.
	[ -d "$1" ] && [ "$("${GIT:-git}" -C "$1" rev-parse --is-inside-work-tree 2>/dev/null)" = true ]
}

# _loop_repo_candidate WORD
# Prints "<kind> <dir>" (kind: path | repo | bare) for a word that could name a checkout,
# nothing for one that cannot.
_loop_repo_candidate() {
	local word="$1" root="${DEV_LOOP_REPOS_ROOT:-$HOME/github}"
	case "$word" in
	\~/*) printf 'path %s\n' "$HOME/${word#\~/}" ;;
	/*) printf 'path %s\n' "$word" ;;
	*)
		if [[ "$word" == ./* || "$word" == ../* ]]; then
			: # a relative path names no repo under the root; fall back to the cwd
		elif [[ "$word" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
			printf 'repo %s\n' "$root/${word#*/}"
		elif [[ "$word" =~ ^[A-Za-z0-9._-]+$ ]]; then
			printf 'bare %s\n' "$root/$word"
		fi
		;;
	esac
}

# loop_repo_resolve TRANSCRIPT CWD
# Returns 0 and sets the three globals, or returns 1 with LOOP_REPO_SOURCE=unknown.
# The globals are read by the sourcing guard, which shellcheck cannot see.
# shellcheck disable=SC2034
loop_repo_resolve() {
	local transcript="$1" cwd="$2" args word candidate kind dir reason invocations

	LOOP_REPO_DIR="$cwd"
	LOOP_REPO_SOURCE="cwd"
	reason="no /dev-loop invocation is recorded in the transcript"

	if [ -r "$transcript" ]; then
		mapfile -t invocations < <(loop_invocation_args "$transcript")
		args=""
		if [ "${#invocations[@]}" -gt 0 ]; then
			args="${invocations[-1]}"
			reason="the last /dev-loop invocation named no repo"
		fi
		word="$(_loop_repo_first_word "$args")"
		candidate="$([ -n "$word" ] && _loop_repo_candidate "$word")"
		if [ -n "$candidate" ]; then
			kind="${candidate%% *}"
			dir="${candidate#* }"
			if _loop_repo_is_checkout "$dir"; then
				LOOP_REPO_DIR="$dir"
				LOOP_REPO_SOURCE="invocation"
				LOOP_REPO_LABEL="repo judged: $dir (from the /dev-loop invocation: '$word')"
				return 0
			fi
			if [ "$kind" != "bare" ]; then
				LOOP_REPO_DIR=""
				LOOP_REPO_SOURCE="unknown"
				LOOP_REPO_LABEL="repo judged: UNKNOWN — the /dev-loop invocation named '$word' but $dir is not a git checkout"
				return 1
			fi
		fi
	fi

	LOOP_REPO_LABEL="repo judged: $cwd (cwd fallback: $reason)"
	return 0
}

# loop_repo_unknown_message GUARD — what a guard prints before it blocks on an UNKNOWN repo.
loop_repo_unknown_message() {
	{
		echo "$1: $LOOP_REPO_LABEL"
		echo
		echo "The guard cannot tell which repo this dev-loop round belongs to, so it did NOT"
		echo "judge the cwd repo instead — that is exactly the wrong-repo answer #1125 removed."
		echo "Re-invoke the loop with a checkout path (/dev-loop ~/github/<repo>) or run it from"
		echo "inside the repo."
	} >&2
}
