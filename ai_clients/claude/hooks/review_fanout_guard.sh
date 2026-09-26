#!/bin/bash
# Stop hook: refuse to end a dev-loop round that had assignable open PRs and started no
# review agent — the deterministic half of s:dev-loop step 4b (REVIEW FAN-OUT), sibling of
# uncommitted_worktree_guard.sh, dispatch_free_surface_guard.sh and round_dispatch_guard.sh
# (dotfiles-dev#480).
#
# THE MEASUREMENT THIS FILE REMOVES. Step 4b's fan-out was entirely prose, and the prose was
# read into the opposite of its meaning. reviewer_ladder.sh states "one PR per invocation
# (there is no loop-over-PRs form of run_fallback_review)" — a correct blast-radius cap on a
# single call — and it was read as "no concurrency at all". N agents each invoking it once is
# N single-PR invocations, exactly what the rule permits as written. Nobody re-read the
# constraint against the case, 19 of 21 open PRs sat unreviewed, and the inference cost
# nothing to make and looked like discipline. That is precisely the failure a hook fixes and
# a sentence does not.
#
# How it differs from its three siblings, none of which it replaces:
#   uncommitted_worktree_guard.sh  — is work durable?            (step 1)
#   dispatch_free_surface_guard.sh — is the ISSUE surface free?   (step 6)
#   round_dispatch_guard.sh        — which ISSUES could go out?   (step 6)
#   this file                      — which open PRs need a REVIEWER? (step 4b)
# The two step-6 guards answer questions about issues and never look at an open PR's review
# state; this one answers only that, and is silent about issues.
#
# 🔴 SCHEDULING ONLY. This hook and its planner decide WHICH PRs get a reviewer. Neither ever
# accepts, applies or resolves a review finding — the dispatched agent still judges every
# finding against the current code, refutes what does not hold with measurement, and replies
# with rationale. A deterministic fan-out that auto-applied findings would industrialise the
# false positives and be strictly worse than the prose it replaces (#480).
#
# THE PLANNER CONTRACT (hooks/lib/review_fanout_plan.py). Invoked with no arguments, prints
# one JSON object on stdout:
#
#   {"rung":         {"status": "ok", "runtime": "qwen", "model": "…", "signal": "…"},
#    "dispatchable": [{"pr": 520, "head": "e131992…", "checks": {…}}],
#    "excluded":     [{"pr": 453, "reason": "already reviewed at the current head"}]}
#
# `dispatchable` non-empty and no review agent started => block. Empty is the legitimate zero
# case, and it is legitimate ONLY because every PR that did not make the cut is in `excluded`
# carrying its own named reason. The escape is per PR, never a flag — a gate with a bare
# override becomes a gate that cries wolf and gets switched off, which is this toolchain's own
# recorded failure mode.
#
# ⚠️ `rung.status` = "unknown" BLOCKS, with its own wording. "none" does not. The two are
# different claims and collapsing them is the #396 defect verbatim: "none" is a measured
# answer (the #479 probe ran and neither qwen nor codex is assignable) and becomes every PR's
# named exclusion reason, so nothing is hidden; "unknown" is blindness (the probe could not be
# run, or timed out), and a guard that reports its own blindness as routine silence is exactly
# what a fail-closed gate must not do.
#
# ⚠️ N is capped by API BUDGET, not by reviewer quota: five concurrent agents drained both the
# GitHub REST and GraphQL buckets (#445), and again at 09:49Z on 2026-09-23, blinding a thread
# sweep into reporting 21 PRs clean that it never read. #445's latch is the prerequisite for
# acting on a wide plan; this hook deliberately implements no latch of its own and no cap of
# its own — it reports the full assignable set and leaves the budget to the latch that owns it.
#
# Fails OPEN on everything it cannot resolve (no jq, no gh, no python3, no repo, no
# transcript, a session that never ran the loop) — a guard that blocks on unrelated sessions
# gets disabled, same rule as every sibling Stop hook here.
set -u

GIT=/usr/bin/git
command -v jq >/dev/null 2>&1 || exit 0
command -v gh >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLANNER="${REVIEW_FANOUT_PLANNER:-$HOOK_DIR/lib/review_fanout_plan.py}"
PLANNER_TIMEOUT="${REVIEW_FANOUT_PLANNER_TIMEOUT:-90}"

# dev_loop_invoked TRANSCRIPT
# Pure data: did this session's transcript ever run s:dev-loop? MIRRORS
# dispatch_free_surface_guard.sh's own function of the same name rather than sharing it —
# #405 holds that file, and a second writer on it is a guaranteed conflict. Three shapes
# count, all measured off real transcripts (dotfiles-dev#404); a session that never ran the
# loop in ANY of them is not this hook's concern and must never be blocked:
#   1. a Skill tool_use, bare ("dev-loop");
#   2. a Skill tool_use, fully-qualified ("s:dev-loop") — some invocation paths serialise the
#      namespaced form, and nothing is measured to prefer one, so both count;
#   3. a `/dev-loop` slash command, typed or replayed from a cron schedule. Both land as a
#      plain user-role message whose content is a bare STRING carrying the literal
#      <command-name>/dev-loop</command-name> marker — which is why shape 1's
#      `.message.content[]?` walk sees none of them: `[]?` over a string yields nothing
#      rather than an error, so the miss was silent.
# Parsed with jq, never grepped for the whole object: key-value spacing is not part of the
# JSONL contract, so a literal '"skill":"dev-loop"' match silently misses a record serialized
# as '"skill": "dev-loop"' and the hook never fires.
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
	# reflects only the LAST value the program emits across the whole JSONL stream, and every
	# other user-role record in a real transcript (an Agent's tool_result is also
	# `.type == "user"`) reaches this same pipeline and would emit an explicit `false` —
	# which, landing after a real match, flips -e's verdict back to failure. `select` emits
	# NOTHING for a non-match, so only a real match can be the last value on the stream.
	jq -e 'select(.type == "user" and .message.content != null)
		| .message.content
		| if type == "string" then .
		  else ([.[]? | select(.type == "text") | .text // ""] | join("\n"))
		  end
		| select(contains("<command-name>/dev-loop</command-name>"))' \
		"$transcript" >/dev/null 2>&1
}

# _agent_result_text TRANSCRIPT ID
# The literal text of the tool_result matching a dispatched Agent's tool_use id, or empty when
# none has landed yet. content is normalised for both shapes seen in real transcripts: a plain
# string, or an array of blocks with a .text field.
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
# The last completed|failed <status> of a <task-notification> naming this tool-use id, scanned
# across every string leaf of every record rather than one assumed field: measured on real
# transcripts the identical blob shows up under `.content` (a queue-operation record, on both
# enqueue AND removal), under `.prompt` (an attachment record), and eventually inside an
# ordinary delivered message. `.. | strings` walks them all, so a harness change to which
# shape delivers it cannot silently blind this the way shape 3 above blinded dev_loop_invoked.
_task_notification_status() {
	local transcript="$1" id="$2"
	jq -r --arg needle "<tool-use-id>${id}</tool-use-id>" '
		.. | strings
		| select(contains($needle))
		| capture("<status>(?<s>completed|failed)</status>").s
	' "$transcript" 2>/dev/null | tail -1
}

# subagents_running TRANSCRIPT
# True when a dispatch of this session's OWN is still unresolved. Mirrors
# dispatch_free_surface_guard.sh's function of the same name (see dev_loop_invoked above for
# why this is a mirror and not a shared helper).
#
# A dispatched Agent tool_use with NO tool_result yet is still in flight — ponytail: this is a
# proxy for "is a subagent running", since no live process list is readable from a bash hook,
# so silence reads as running, including the one turn between dispatch and the harness
# appending a result. Upgrade path: a real running-agent registry, if the harness ever exposes
# one.
#
# A tool_result that IS present but is a background dispatch's own launch acknowledgement
# ("Async agent launched successfully…", measured verbatim off a real transcript, #404) is
# delivered synchronously ON LAUNCH, before the agent has done any work — so reading its mere
# presence as "resolved" makes every background dispatch look finished the instant it starts.
# Only a LATER <task-notification> for the same id settles it: completed means done; no
# notification yet means still working; failed means NEITHER — a quota kill is not "running",
# it is the RESCUE case, so it does not count as still-running and the caller is told to
# resume rather than dispatch a duplicate.
subagents_running() {
	local transcript="$1"
	FAILED_BACKGROUND_AGENTS=""
	[ -r "$transcript" ] || return 1

	local dispatched id result status desc still_running=1
	dispatched="$(jq -r 'select(.message.content != null)
		| .message.content[]?
		| select(.type == "tool_use" and .name == "Agent")
		| .id' "$transcript" 2>/dev/null)"
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
					| (.input.name // .input.description // $id)' \
					"$transcript" 2>/dev/null | head -1)"
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

# block_unreadable REASON
# One exit path for every case where the plan could not be trusted. Distinct wording from the
# "there is work to do" message on purpose: an operator must be able to tell "the planner
# broke" from "you skipped the fan-out", because the two need opposite next actions.
block_unreadable() {
	{
		echo "review_fanout_guard: $1"
		echo
		echo "s:dev-loop step 4b (REVIEW FAN-OUT) cannot tell right now which open PRs need a"
		echo "reviewer. Re-run the planner before reporting the board reviewed — a planner that"
		echo "fails and is then read as routine silence is the defect this hook exists to catch"
		echo "(dotfiles-dev#480, same shape as #396 and #433)."
	} >&2
	exit 2
}

main() {
	local payload active cwd transcript plan rung_status dispatchable excluded

	payload="$(cat)"

	# Never block a stop that a hook already caused — one nudge per turn.
	active="$(printf '%s' "$payload" | jq -r '.stop_hook_active // false' 2>/dev/null)"
	[[ "$active" == "true" ]] && exit 0

	cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
	[ -n "$cwd" ] || cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
	transcript="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)"
	[ -n "$transcript" ] && [ -r "$transcript" ] || exit 0

	$GIT -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

	dev_loop_invoked "$transcript" || exit 0
	subagents_running "$transcript" && exit 0

	[ -r "$PLANNER" ] || block_unreadable "no review fan-out planner at $PLANNER (run 'make ai_clients')."

	# The planner runs in the repo the payload names, never this hook's ambient cwd: `gh pr
	# list` resolves its repo from the working directory, and the harness can reset cwd to a
	# DIFFERENT repository between calls (dotfiles-dev#229) — a plan computed against the
	# wrong repo is worse than no plan, because it reads as an answer.
	plan="$(cd "$cwd" && timeout "$PLANNER_TIMEOUT" python3 "$PLANNER" 2>/dev/null)"

	# Shape, not just keys: {"dispatchable":null,"excluded":{}} has both keys, formats to
	# nothing, and would exit 0 below as a false "nothing to review". Every dispatchable
	# record needs a PR number; every excluded record needs a non-empty reason — an exclusion
	# with no reason is exactly the silent skip this hook exists to refuse.
	if ! printf '%s' "$plan" | jq -e '
		(.rung.status | type == "string")
		and (.dispatchable | type == "array") and (.excluded | type == "array")
		and all(.dispatchable[]; (.pr | type == "number"))
		and all(.excluded[]; (.pr | type == "number") and ((.reason // "") | length > 0))
	' >/dev/null 2>&1; then
		block_unreadable "review fan-out plan UNREADABLE (planner failed, timed out, or printed something that is not the documented object) — not the same as empty."
	fi

	rung_status="$(printf '%s' "$plan" | jq -r '.rung.status')"
	case "$rung_status" in
	ok | none) ;;
	unknown)
		block_unreadable "reviewer rung UNKNOWN (the #479 probe could not be run or timed out) — not the same as no rung being available."
		;;
	*)
		block_unreadable "reviewer rung status '$rung_status' is not one of ok|none|unknown — the planner's contract changed and this hook has not been taught the new value."
		;;
	esac

	dispatchable="$(printf '%s' "$plan" | jq -r '
		.dispatchable[]?
		| "  #\(.pr)  head \((.head // "")[0:8])"
		  + (if ((.checks.failing // []) | length) > 0
		     then "  [failing: \((.checks.failing) | join(", "))]" else "" end)
		  + (if ((.checks.running // []) | length) > 0
		     then "  [still running: \((.checks.running) | join(", "))]" else "" end)
		  + (if ((.checks.ambiguous // []) | length) > 0
		     then "  [ambiguous check name: \((.checks.ambiguous) | join(", "))]" else "" end)')"
	[ -n "$dispatchable" ] || exit 0

	excluded="$(printf '%s' "$plan" | jq -r '.excluded[]? | "  #\(.pr)  \(.reason)"')"
	{
		echo "Open PRs need a reviewer on their CURRENT head and no review agent was started —"
		echo "do not stop here without dispatching the fan-out."
		echo
		if [ -n "$FAILED_BACKGROUND_AGENTS" ]; then
			echo "A background agent dispatched earlier this session FAILED (quota kill or crash)"
			echo "instead of finishing — that is the RESCUE case, not free capacity. Resume it,"
			echo "don't dispatch a duplicate:"
			printf '%s\n' "$FAILED_BACKGROUND_AGENTS" | sed 's/^/  /'
			echo
		fi
		echo "Reviewer rung: $(printf '%s' "$plan" | jq -r '.rung | "\(.status) \(.runtime) \(.model)"')"
		echo
		echo "Needs a reviewer now (one agent per PR — N single-PR ladder calls, which is what"
		echo "reviewer_ladder.sh's one-PR-per-invocation cap permits, never a loop inside one):"
		printf '%s\n' "$dispatchable"
		if [ -n "$excluded" ]; then
			echo
			echo "Excluded, with the reason each was excluded:"
			printf '%s\n' "$excluded"
		fi
		echo
		echo "Dispatch one agent per PR above, or move each into the excluded list with its own"
		echo "named reason. There is no bare override: the legitimate zero case is every PR"
		echo "carrying a reason, which is what keeps this gate from crying wolf."
		echo
		echo "Each agent JUDGES its findings — fix what holds, refute what does not with"
		echo "measurement, reply with rationale, resolve. The plan schedules the review; it"
		echo "never accepts a finding for you."
	} >&2
	exit 2
}

main "$@"
