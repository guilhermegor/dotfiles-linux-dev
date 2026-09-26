#!/bin/bash
# Stop hook: refuse to end the turn while EVERY dispatchable issue is not
# either in flight or throttled by the concurrency cap — the deterministic
# half of s:dev-loop step 6 (DISPATCH), sibling of
# uncommitted_worktree_guard.sh (dotfiles-dev#396, #405).
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
# ⚠️ COVERAGE, NOT PRESENCE (dotfiles-dev#405). Until #405 this hook exited 0
# the moment ANY dispatch of this session was unresolved, so it could only
# ever enforce "at least one agent is working" — the batch SIZE still
# depended on the model remembering, which is what the owner has now asked
# for in five separate rounds. The rule is a set difference instead:
#
#     block  ⟺  dispatchable − in_flight − queued_by_cap  ≠  ∅
#
#   dispatchable   — lib/dispatch_plan.py's answer, never re-derived here:
#                    unclaimed by any PR, declared surface free against open
#                    PRs, live agents and each other (#433).
#   in_flight      — per ISSUE, from two independent sources: a live claim in
#                    the shared registry (lib/dispatch_claims.sh) and an
#                    unresolved background dispatch naming `#N` (#404's
#                    notification-based detection). Either one counts.
#   queued_by_cap  — the part of the remainder over DISPATCH_MAX_CONCURRENT.
#                    The cap THROTTLES and never DROPS: the overflow is named
#                    in the message as queued and is demanded again as soon
#                    as a slot frees, which is also why no queue FILE exists
#                    — the order is recomputed from the plan every Stop, so
#                    there is nothing to pop and nothing to go stale.
#
# The message lists the missing issue NUMBERS, never a count.
#
# ⚠️ UNKNOWN is reported loudly, never as routine silence. A gate that fails
# closed (#395) is the right behaviour for the gate; a caller that swallows
# that failure and falls through quiet turns it back into a disabled feature
# nobody can see — the exact shape of cause 1. Two shapes of that block here:
# a plan that is not the documented object, and a plan whose exclusions say
# UNKNOWN (the planner's own fail-closed answer, which would otherwise reach
# this hook as an empty `dispatchable`, i.e. as "nothing to do").
#
# An issue with no declared surface is UNDECLARED: reported, never assumed
# free and never dispatched on a guess. It blocks only while a slot is free,
# because declaring the surface is refinement work the round can actually do.
#
# Fails OPEN on everything it cannot resolve (no repo, no transcript, no
# dev-loop evidence) — a guard that blocks on its own blindness gets
# disabled, same rule as every sibling Stop hook here.
set -u

GIT=/usr/bin/git
command -v jq >/dev/null 2>&1 || exit 0
command -v gh >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/dispatch_claims.sh
source "$HOOK_DIR/lib/dispatch_claims.sh"

PLANNER="${DISPATCH_GUARD_PLANNER:-$HOOK_DIR/lib/dispatch_plan.py}"
PLANNER_TIMEOUT="${DISPATCH_GUARD_PLANNER_TIMEOUT:-30}"

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

# DISPATCH_NAME_ISSUE_RE — a dispatch declares the ONE issue it covers in the Agent's `name`.
# ⚠️ Read the NAME only, never the description or the prompt. The first cut joined name +
# description + prompt and took every `#N` in the blob, which is wrong in two ways at once
# (review finding on this file, measured on a real transcript 2026-09-26):
#
#   1. COVERAGE. A brief legitimately cites sibling issues, prior art and blockers. Two real
#      dispatches this session yielded `#314 #404 #405 #479 #520` and `#405 #445 #479 #480
#      #511 #520` — 5 and 6 issues from ONE agent each. Every cited number read as covered, so
#      the guard would never demand a dispatch for any of them: presence masquerading as
#      coverage, which is the exact defect #405 exists to remove.
#   2. SLOTS. The old arithmetic subtracted the COUNT of extracted numbers from
#      DISPATCH_MAX_CONCURRENT, so one agent could consume six slots and the guard would report
#      real work as "queued by the cap" while the cap was not actually reached.
#
# The name is written by the DISPATCHER, so it is a declaration, not an inference. A prompt is
# prose, and keying on prose is the same weak-proxy mistake as reading `priority` for model
# capability or an author login for a comment's role. Same shape as review_fanout_guard.sh's
# REVIEW_DISPATCH_NAME_RE, deliberately: two guards asking "what is this agent for?" must not
# answer it two different ways.
DISPATCH_NAME_ISSUE_RE='^issue-([0-9]+)(-|$)'

# _agent_dispatch_issue TRANSCRIPT ID
# Prints the ONE issue number this dispatch declares, or nothing. Never more than one line.
_agent_dispatch_issue() {
	local name
	name="$(jq -r --arg id "$2" 'select(.message.content != null)
		| .message.content[]?
		| select(.type == "tool_use" and .name == "Agent" and .id == $id)
		| .input.name // ""' "$1" 2>/dev/null | head -1)"
	[[ "$name" =~ $DISPATCH_NAME_ISSUE_RE ]] || return 1
	printf '%s\n' "${BASH_REMATCH[1]}"
}

# inflight_dispatch_issues TRANSCRIPT
# Sets IN_FLIGHT_ISSUES (newline-separated issue numbers, possibly empty) and
# FAILED_BACKGROUND_AGENTS (newline-separated names, possibly empty).
#
# ⚠️ Per ISSUE, not per session (dotfiles-dev#405). The pre-#405 version of this function
# answered the yes/no question "is any subagent running", which made the whole guard a presence
# check: one live agent excused every other dispatchable issue in the same round. The set of
# issue numbers is the answer coverage needs.
#
# A dispatched Agent tool_use with NO tool_result yet is still in flight — ponytail: this is a
# proxy for "is a subagent running" (no live process list is readable from a bash hook), so
# silence reads as running, including the one turn between dispatch and the harness appending
# a result. Upgrade path: a real running-agent registry, if the harness ever exposes one.
#
# A tool_result IS present but is a background dispatch's own launch acknowledgement ("Async
# agent launched successfully...", measured verbatim off a real transcript, dotfiles-dev#404) —
# that text is delivered synchronously on launch, before the agent has done any work, so
# treating its mere presence as "resolved" is exactly the defect that issue reports: every
# background dispatch reads as finished the instant it starts. Only a LATER <task-notification>
# for the same tool_use id settles it: status=completed means done; no notification yet means
# still working, same as no tool_result at all; status=failed means neither — a quota kill is
# not "running", it is the RESCUE case (resume it, don't dispatch a duplicate), so it is
# recorded in FAILED_BACKGROUND_AGENTS and does NOT count as in flight.
#
# Anything else (a synchronous call's real result already landed) is resolved, plainly.
inflight_dispatch_issues() {
	local transcript="$1"
	IN_FLIGHT_ISSUES=""
	FAILED_BACKGROUND_AGENTS=""
	UNDECLARED_IN_FLIGHT=""
	IN_FLIGHT_AGENTS=0
	[ -r "$transcript" ] || return 0

	local dispatched id result status desc issue undeclared_name
	dispatched="$(jq -r 'select(.message.content != null) | .message.content[]? | select(.type=="tool_use" and .name=="Agent") | .id' "$transcript" 2>/dev/null)"
	[ -n "$dispatched" ] || return 0

	while read -r id; do
		[ -n "$id" ] || continue
		result="$(_agent_result_text "$transcript" "$id")"
		if [ -n "$result" ]; then
			case "$result" in
			*"Async agent launched successfully"*)
				status="$(_task_notification_status "$transcript" "$id")"
				case "$status" in
				completed) continue ;;
				failed)
					desc="$(jq -r --arg id "$id" 'select(.message.content != null)
						| .message.content[]?
						| select(.type == "tool_use" and .id == $id)
						| (.input.name // .input.description // $id)' "$transcript" 2>/dev/null | head -1)"
					FAILED_BACKGROUND_AGENTS="$(printf '%s\n%s' "$FAILED_BACKGROUND_AGENTS" "$desc")"
					continue
					;;
				esac
				;;
			*) continue ;;
			esac
		fi
		# Every unresolved dispatch costs a SLOT whether or not it declares an issue — a
		# running agent is running. Only a declared issue counts as COVERAGE. Keeping the two
		# counts separate is the whole point: conflating them is what let one agent both
		# excuse six issues and eat six slots.
		IN_FLIGHT_AGENTS=$((IN_FLIGHT_AGENTS + 1))
		if issue="$(_agent_dispatch_issue "$transcript" "$id")"; then
			IN_FLIGHT_ISSUES="$(printf '%s\n%s' "$IN_FLIGHT_ISSUES" "$issue")"
		else
			# Reported, never silently dropped: a dispatch whose name does not declare its
			# issue is invisible to coverage, and silence there is indistinguishable from
			# "nothing was dispatched" — the failure mode this guard exists to end.
			undeclared_name="$(jq -r --arg id "$id" 'select(.message.content != null)
				| .message.content[]?
				| select(.type == "tool_use" and .id == $id)
				| (.input.name // .input.description // $id)' "$transcript" 2>/dev/null | head -1)"
			UNDECLARED_IN_FLIGHT="$(printf '%s\n%s' "$UNDECLARED_IN_FLIGHT" "$undeclared_name")"
		fi
	done <<<"$dispatched"

	IN_FLIGHT_ISSUES="$(printf '%s\n' "$IN_FLIGHT_ISSUES" | sed '/^$/d' | sort -un)"
	UNDECLARED_IN_FLIGHT="$(printf '%s\n' "$UNDECLARED_IN_FLIGHT" | sed '/^$/d')"
	FAILED_BACKGROUND_AGENTS="$(printf '%s\n' "$FAILED_BACKGROUND_AGENTS" | sed '/^$/d')"
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

# report_unreadable DETAIL
# The fail-closed exit. Named separately because there are two distinct ways the plan can be
# unusable and both must block with the SAME loudness — a planner that fails and is then read as
# routine silence is the defect this hook exists to catch (dotfiles-dev#396).
report_unreadable() {
	{
		echo "free dispatch surface UNREADABLE ($1) — not the same as empty."
		echo
		echo "s:dev-loop step 6 (DISPATCH) cannot tell right now which issues are"
		echo "dispatchable. Re-run the planner (hooks/lib/dispatch_plan.py) before reporting"
		echo "the board clear."
	} >&2
	exit 2
}

# rescue_note
# Printed above every block message while a background dispatch of this session failed: a quota
# kill is not free capacity, and dispatching a duplicate over it loses the work twice.
rescue_note() {
	[ -n "$FAILED_BACKGROUND_AGENTS" ] || return 0
	echo "A background agent dispatched earlier this session FAILED (quota kill or"
	echo "crash) instead of finishing — that is the RESCUE case, not free capacity."
	echo "Resume it, don't dispatch a duplicate:"
	printf '%s\n' "$FAILED_BACKGROUND_AGENTS" | sed 's/^/  /'
	echo
}

main() {
	local payload active cwd transcript plan dispatchable undeclared
	local in_flight claimed remaining missing queued slots

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
	inflight_dispatch_issues "$transcript"

	plan="$(cd "$cwd" && timeout "$PLANNER_TIMEOUT" python3 "$PLANNER" 2>/dev/null)"
	# Shape, not just keys: `{"dispatchable":null,"excluded":{}}` has both keys, formats to
	# nothing, and would read as a false "nothing to dispatch". Same check
	# round_dispatch_guard.sh applies to the same planner.
	printf '%s' "$plan" | jq -e '
		(.dispatchable | type == "array") and (.excluded | type == "array")
		and all(.dispatchable[]; (.issue | type == "number"))
		and all(.excluded[]; (.issue | type == "number") and ((.reason // "") | length > 0))
	' >/dev/null 2>&1 ||
		report_unreadable "planner failed, timed out, or printed something else"

	# The planner's own fail-closed answer is an UNKNOWN reason on every issue, which arrives
	# here as an EMPTY dispatchable list — indistinguishable from a genuinely clear board by any
	# check that only counts candidates. It is read explicitly instead.
	if printf '%s' "$plan" | jq -e '.excluded[]? | select(.reason | test("UNKNOWN"))' >/dev/null 2>&1; then
		report_unreadable "the planner's gate or liveness read failed (UNKNOWN exclusions)"
	fi

	dispatchable="$(printf '%s' "$plan" | jq -r '.dispatchable[]? | .issue')"
	undeclared="$(printf '%s' "$plan" |
		jq -r --arg t "$DISPATCH_UNDECLARED_TOKEN" \
			'.excluded[]? | select(.reason | startswith($t)) | .issue')"

	# Two independent in-flight sources, unioned: this session's own unresolved dispatches, and
	# the cross-worktree claims registry (an agent of ANOTHER session holds those).
	claimed="$(cd "$cwd" && dispatch_claimed_issues)"
	in_flight="$(printf '%s\n%s\n' "$IN_FLIGHT_ISSUES" "$claimed" | sed '/^$/d' | sort -un)"

	remaining="$(printf '%s\n' "$dispatchable" | sed '/^$/d' |
		grep -vxF -f <(printf '%s\n' "$in_flight" | sed '/^$/d') || true)"

	# ⚠️ Slots are consumed by AGENTS, never by issue numbers. This session's own unresolved
	# dispatches are counted one apiece (IN_FLIGHT_AGENTS); each cross-worktree claim stands for
	# one agent of another session, which is why the claims are counted and not the union — the
	# union would double-count an issue that is both claimed and dispatched here.
	slots=$((DISPATCH_MAX_CONCURRENT - IN_FLIGHT_AGENTS \
		- $(printf '%s\n' "$claimed" | sed '/^$/d' | wc -l)))
	[ "$slots" -lt 0 ] && slots=0
	missing="$(printf '%s\n' "$remaining" | sed '/^$/d' | head -n "$slots")"
	queued="$(printf '%s\n' "$remaining" | sed '/^$/d' | tail -n +"$((slots + 1))")"

	if [ -n "$missing" ]; then
		{
			rescue_note
			echo "Dispatchable issues are not covered by anything in flight — do not stop here"
			echo "without dispatching one agent per issue below."
			echo
			echo "Missing (dispatchable, nothing working it, a slot is free):"
			printf '%s\n' "$missing" | sed 's/^/  #/'
			if [ -n "$queued" ]; then
				echo
				echo "Queued by the concurrency cap of $DISPATCH_MAX_CONCURRENT — throttled, NOT"
				echo "dropped; they are demanded again as soon as a slot frees:"
				printf '%s\n' "$queued" | sed 's/^/  #/'
			fi
			if [ -n "$UNDECLARED_IN_FLIGHT" ]; then
				echo
				echo "In flight but declaring NO issue in their Agent name — they hold a slot"
				echo "and cover nothing; name them 'issue-<N>-<slug>' so coverage can see them:"
				printf '%s\n' "$UNDECLARED_IN_FLIGHT" | sed 's/^/  /'
			fi
			if [ -n "$undeclared" ]; then
				echo
				echo "UNDECLARED file surface — reported, never assumed free. Declare a"
				echo "\`\`\`surface block on each, then they become dispatchable:"
				printf '%s\n' "$undeclared" | sed 's/^/  #/'
			fi
			echo
			echo "Each agent's brief starts with the claim step (hooks/lib/dispatch_claims.sh):"
			echo "  claim_files <issue> <paths…>   # CLAIMED, or HELD:<holder> — do not proceed"
		} >&2
		exit 2
	fi

	# Nothing to dispatch, but an issue nobody can plan and a free slot to plan it in. Silence
	# here is how 7 of 10 unclaimed issues read as "nothing to dispatch" (s:dev-loop step 6).
	if [ -n "$undeclared" ] && [ "$slots" -gt 0 ]; then
		{
			rescue_note
			echo "Nothing is dispatchable, but these issues have no declared file surface —"
			echo "UNDECLARED is reported, never assumed free, and never dispatched on a guess."
			echo
			printf '%s\n' "$undeclared" | sed 's/^/  #/'
			echo
			echo "Declaring the surface is refinement work this round can do: add a"
			echo "\`\`\`surface block listing the exact paths, then re-run the round."
		} >&2
		exit 2
	fi

	exit 0
}

main "$@"
