#!/bin/bash
# Stop hook: refuse to end the turn when the free dispatch surface has
# unclaimed issues and nothing of this session's own is currently working
# them — the deterministic half of s:dev-loop step 6 (DISPATCH), sibling of
# uncommitted_worktree_guard.sh (dotfiles-dev#396).
#
# The owner asked four times why subagents were not dispatched in parallel.
# Two distinct causes, only one of them the model forgetting:
#   1. gate_free_surface itself failed closed on any repo with an orphan
#      branch and the caller read that failure as "nothing to do" — fixed at
#      the gate in #395. This hook is the OTHER half: even a correct gate is
#      still just prose someone has to remember to call.
#   2. DISPATCH lived only in a skill. uncommitted_worktree_guard.sh already
#      proved that a correct, written-down "commit early" rule still gets
#      skipped without a hook enforcing it — same defect, different step.
#
# ⚠️ UNKNOWN is reported loudly, never as routine silence. A gate that fails
# closed (#395) is the right behaviour for the gate; a caller that swallows
# that failure and falls through quiet turns it back into a disabled feature
# nobody can see — the exact shape of cause 1. So an unreadable gate blocks
# too, with its own wording, distinct from "issues are free, dispatch them".
#
# Fires only when the transcript shows this session actually ran s:dev-loop
# AND has no Agent-tool dispatch of its own still unresolved — both read
# from the transcript (data), never inferred from what the session "knows"
# about itself, the same decidability test the skill's own Do Not section
# applies to the (deliberately un-hooked) pre-dispatch budget judgement.
#
# Fails OPEN on everything it cannot resolve (no repo, no transcript, no
# dev-loop evidence) — a guard that blocks on its own blindness gets
# disabled, same rule as every sibling Stop hook here.
set -u

GIT=/usr/bin/git
command -v jq >/dev/null 2>&1 || exit 0
command -v gh >/dev/null 2>&1 || exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/free_surface.sh
source "$HOOK_DIR/lib/free_surface.sh"

# dev_loop_invoked TRANSCRIPT
# Pure data: did this session's transcript ever run s:dev-loop? Three shapes count, all
# measured off real transcripts (dotfiles-dev#404) — a session that never ran the loop in
# ANY of them is not this hook's concern, and must never fire:
#   1. a Skill tool_use, bare ("dev-loop") — the original, and still correct for a direct
#      Skill-tool invocation.
#   2. a Skill tool_use, fully-qualified ("s:dev-loop") — some invocation paths serialise the
#      namespaced form; nothing here is measured to prefer one over the other, so both count.
#   3. a `/dev-loop` slash-command invocation — typed directly, or replayed from a CronCreate
#      schedule (the step-0 cron this guard exists to make routine). Both land as a plain
#      user-role message carrying the literal `<command-name>/dev-loop</command-name>`
#      marker; message.content is ordinarily a bare string for this shape (never an array of
#      tool_use blocks), which is exactly why shape 1's `.message.content[]?` walk sees zero
#      of these — `[]?` over a string yields nothing, not an error, so the miss was silent.
# Parsed with jq, never grepped for the whole object: key-value spacing is not part of the
# JSONL contract, so a literal '"skill":"dev-loop"' match silently misses a record serialized
# as '"skill": "dev-loop"'.
dev_loop_invoked() {
	local transcript="$1"
	[ -r "$transcript" ] || return 1

	if jq -e 'select(.message.content != null)
		| .message.content[]?
		| select(.type == "tool_use"
			and .name == "Skill"
			and (.input.skill == "dev-loop" or .input.skill == "s:dev-loop"))' \
		"$transcript" >/dev/null 2>&1
	then
		return 0
	fi

	# `select(contains(...))` at the tail, never a bare `contains(...)`: `jq -e`'s exit status
	# reflects only the LAST value this program emits across the whole JSONL stream, and every
	# other user-role message in a real transcript (e.g. an Agent's tool_result, which is also
	# `.type == "user"`) reaches this same pipeline and would emit an explicit `false` — which,
	# landing after a real match, would flip -e's verdict back to failure. `select` instead
	# emits NOTHING for a non-matching line, the same "backtrack, don't emit false" contract
	# shape 1's chain of `select`s already relies on — so only a real match can be the last
	# (or only) value on the stream (dotfiles-dev#404, caught by this fix's own repro).
	jq -e 'select(.type == "user" and .message.content != null)
		| .message.content
		| if type == "string" then .
		  else ([.[]? | select(.type == "text") | .text // ""] | join("\n"))
		  end
		| select(contains("<command-name>/dev-loop</command-name>"))' \
		"$transcript" >/dev/null 2>&1
}

# _agent_result_text TRANSCRIPT ID
# The literal text of the tool_result matching a dispatched Agent's tool_use id, or empty if
# none has landed yet. content is normalised the same way for both shapes seen in real
# transcripts: a plain string, or an array of blocks with a .text field.
_agent_result_text() {
	local transcript="$1" id="$2"
	jq -r --arg id "$id" 'select(.message.content != null)
		| .message.content[]?
		| select(.type == "tool_result" and .tool_use_id == $id)
		| .content
		| if type == "string" then .
		  else ([.[]? | .text // ""] | join("\n"))
		  end' "$transcript" 2>/dev/null
}

# _task_notification_status TRANSCRIPT ID
# The last completed|failed <status> of a <task-notification> naming this tool-use-id,
# scanned across every JSON record in the transcript regardless of which field carries the
# text — measured on real transcripts, the identical <task-notification> blob shows up under
# `.content` (a `queue-operation` record, both on enqueue AND on removal), under `.prompt`
# (an `attachment` record), and eventually inside an ordinary delivered message. `.. | strings`
# walks every string leaf of the record instead of assuming any one of those field names, so a
# harness change to which shape delivers it can't silently blind this the way shape 3 above
# blinded dev_loop_invoked.
_task_notification_status() {
	local transcript="$1" id="$2"
	jq -r --arg needle "<tool-use-id>${id}</tool-use-id>" '
		.. | strings
		| select(contains($needle))
		| capture("<status>(?<s>completed|failed)</status>").s
	' "$transcript" 2>/dev/null | tail -1
}

# subagents_running TRANSCRIPT
# Also sets FAILED_BACKGROUND_AGENTS (newline-separated names/descriptions, possibly empty) —
# always, even when this returns "still running" for a different dispatch, so main() never has
# to re-walk the transcript to find the RESCUE case.
#
# A dispatched Agent tool_use with NO tool_result yet is still in flight — ponytail: this is a
# proxy for "is a subagent running" (no live process list is readable from a bash hook), so
# silence reads as running, including the one turn between dispatch and the harness appending
# a result. Upgrade path: a real running-agent registry, if the harness ever exposes one.
#
# A tool_result IS present but is a background dispatch's own launch acknowledgement ("Async
# agent launched successfully...", measured verbatim off a real transcript, dotfiles-dev#404) —
# that text is delivered synchronously on launch, before the agent has done any work, so
# treating its mere presence as "resolved" is exactly the defect this issue reports: every
# background dispatch reads as finished the instant it starts. Only a LATER <task-notification>
# for the same tool_use id settles it: status=completed means done; no notification yet means
# still working, same as no tool_result at all; status=failed means neither — a quota kill is
# not "running", it is the RESCUE case (resume it, don't dispatch a duplicate), so it is
# recorded in FAILED_BACKGROUND_AGENTS and does NOT count as still-running.
#
# Anything else (a synchronous call's real result already landed) is resolved, plainly.
subagents_running() {
	local transcript="$1"
	FAILED_BACKGROUND_AGENTS=""
	[ -r "$transcript" ] || return 1

	local dispatched id result status desc still_running=1
	dispatched="$(jq -r 'select(.message.content != null) | .message.content[]? | select(.type=="tool_use" and .name=="Agent") | .id' "$transcript" 2>/dev/null)"
	[ -n "$dispatched" ] || return 1

	while read -r id; do
		[ -n "$id" ] || continue
		result="$(_agent_result_text "$transcript" "$id")"
		if [ -z "$result" ]; then
			still_running=0
			continue
		fi
		case "$result" in
		*"Async agent launched successfully"*)
			status="$(_task_notification_status "$transcript" "$id")"
			case "$status" in
			completed) ;;
			failed)
				desc="$(jq -r --arg id "$id" 'select(.message.content != null)
					| .message.content[]?
					| select(.type == "tool_use" and .id == $id)
					| (.input.name // .input.description // $id)' "$transcript" 2>/dev/null | head -1)"
				FAILED_BACKGROUND_AGENTS="$(printf '%s\n%s' "$FAILED_BACKGROUND_AGENTS" "$desc")"
				;;
			*) still_running=0 ;;
			esac
			;;
		esac
	done <<<"$dispatched"

	FAILED_BACKGROUND_AGENTS="$(printf '%s\n' "$FAILED_BACKGROUND_AGENTS" | sed '/^$/d')"
	[ "$still_running" -eq 0 ] && return 0
	return 1
}

# Every `gh` call this hook makes — its own, and every one inside
# gate_free_surface — goes through this wrapper. A Stop hook is synchronous and
# settings.json declares no timeout for it, and the GitHub CLI has no default
# request deadline, so one stalled request would hang the stop indefinitely. A
# timeout exits non-zero, which the gate already reads as UNREADABLE — the
# fail-closed path, never a false "clean".
# `timeout gh`, never `timeout command gh`: `command` is a shell builtin, so
# timeout would look for a binary of that name and exit 127 — every gh call
# failing silently. timeout execs from PATH and cannot see this function, so
# there is no recursion to guard against.
gh() {
	timeout "${DISPATCH_GUARD_GH_TIMEOUT:-20}" gh "$@"
}

main() {
	local payload active cwd transcript repo owner name

	payload="$(cat)"

	# Never block a stop that a hook already caused — one nudge per turn.
	active="$(printf '%s' "$payload" | jq -r '.stop_hook_active // false' 2>/dev/null)"
	[[ "$active" == "true" ]] && exit 0

	cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
	[ -n "$cwd" ] || cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
	transcript="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)"
	[ -n "$transcript" ] || exit 0

	$GIT -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

	dev_loop_invoked "$transcript" || exit 0
	subagents_running "$transcript" && exit 0

	repo="$(cd "$cwd" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
	[ -n "$repo" ] || exit 0
	owner="${repo%%/*}"
	name="${repo##*/}"

	if ! gate_free_surface "$owner" "$name"; then
		{
			# Name the actual cause. "gh API failure" for every failure is how a
			# missing lib/ file read as a network problem for four rounds
			# (dotfiles-dev, PR #400 review) — the gate was never even loaded.
			if ! declare -F gate_free_surface >/dev/null 2>&1; then
				echo "free surface UNREADABLE (gate not loaded — lib/free_surface.sh missing;" \
					"run 'make ai_clients') — not the same as empty."
			else
				echo "free surface UNREADABLE (gh call failed or timed out) — not the same as empty."
			fi
			echo
			echo "s:dev-loop step 6 (DISPATCH) cannot tell right now whether there is unclaimed"
			echo "work. Re-run the gate once the API answers, before reporting the board clear —"
			echo "a gate that fails closed and is then read as routine silence is exactly the"
			echo "defect this hook exists to catch (dotfiles-dev#396)."
		} >&2
		exit 2
	fi

	[ -n "$FREE_UNCLAIMED_ISSUES" ] || exit 0

	{
		if [ -n "$FAILED_BACKGROUND_AGENTS" ]; then
			echo "A background agent dispatched earlier this session FAILED (quota kill or"
			echo "crash) instead of finishing — that is the RESCUE case, not free capacity."
			echo "Resume it, don't dispatch a duplicate:"
			printf '%s\n' "$FAILED_BACKGROUND_AGENTS" | sed 's/^/  /'
			echo
		fi
		echo "Free dispatch surface is non-empty and nothing of this session's own is"
		echo "currently working it — do not stop here without dispatching."
		echo
		echo "Unclaimed open issues (no PR, open or merged, closes them):"
		printf '%s\n' "$FREE_UNCLAIMED_ISSUES" | sed 's/^/  #/'
		echo
		echo "Run s:dev-loop step 6 (DISPATCH): classify each issue's files with"
		echo "free_classify_files, confirm it is not already done, then dispatch what is free."
	} >&2
	exit 2
}

main "$@"
