#!/bin/bash
# Stop hook: refuse to end a dev-loop round that had dispatchable candidates and
# started no agent — the deterministic half of s:dev-loop step 6 (DISPATCH),
# sibling of uncommitted_worktree_guard.sh and dispatch_free_surface_guard.sh
# (dotfiles-dev#433).
#
# The measurement: on 2026-09-20 the owner asked "is any free slot to be used…
# how do I work on them in subagents?" eight times in one session, each time
# just after a round had run and not dispatched. That repetition is not
# impatience — it is the operator serving as the Stop hook, which is what this
# file removes.
#
# How it differs from dispatch_free_surface_guard.sh, which it does NOT replace:
# that hook answers "is the free surface non-empty?" from gh alone. This one
# answers the sharper question the owner keeps asking — "which specific issues
# could go out RIGHT NOW in non-colliding agents?" — from a plan, so its message
# can name candidates and their file surfaces, and so a genuinely blocked board
# passes with a reason per candidate instead of a bare override.
#
# ⚠️ Collision is agent-vs-agent, never agent-vs-open-PR. Treating a frozen
# branch as a live claim excluded 7 of 10 candidates in one round and suppressed
# dispatch entirely; the planner owns that rule, this hook only reads its answer.
#
# THE PLANNER CONTRACT (hooks/lib/dispatch_plan.py, dotfiles-dev#433 item 2 — not
# yet shipped). Invoked with no arguments, prints one JSON object on stdout:
#
#   {"dispatchable": [{"issue": 433, "surface": ["ai_clients/claude/hooks/…"]}],
#    "excluded":     [{"issue": 426, "reason": "surface held by live agent foo"}]}
#
# `dispatchable` non-empty and no agent started this round => block. Empty is the
# legitimate zero case, and it is legitimate only because every candidate that
# did not make the cut is in `excluded` carrying its own named reason — the
# escape is per candidate, never a flag, or this becomes a gate that cries wolf
# and gets switched off, which is this toolchain's own recorded failure mode.
#
# ⚠️ Until that planner exists this hook DEGRADES TO AN ANNOUNCED NO-OP: it exits
# 1 (non-blocking) with a message saying it could not evaluate, once per session.
# It does not pass quietly. A hook that goes silent because its input is missing
# is the exact defect dotfiles-dev#433 is about — a gate reporting its own
# blindness as OK.
#
# Fails OPEN on everything else it cannot resolve (no jq, no transcript, a
# session that never ran the loop) — a guard that blocks on unrelated sessions
# gets disabled, same rule as every sibling Stop hook here.
set -u

command -v jq >/dev/null 2>&1 || exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLANNER="${ROUND_DISPATCH_PLANNER:-$HOOK_DIR/lib/dispatch_plan.py}"
# 60s, not 30: dispatch_plan.py measured 39s on 2026-10-03 15:40Z under a GitHub
# burst (every Stop read UNREADABLE) and 17s at 21:15Z after #605/#576 cut its
# reads. ~3.5x the quiet runtime absorbs API latency; a real hang still times out
# and fails closed (dotfiles-dev#607).
PLANNER_TIMEOUT="${ROUND_DISPATCH_PLANNER_TIMEOUT:-60}"

# round_events TRANSCRIPT
# The round's tool_use stream reduced to the two tokens that decide this hook:
# LOOP for a Skill call on dev-loop, AGENT for an Agent dispatch, in transcript
# order. Parsed with jq, never grepped — key-value spacing is not part of the
# JSONL contract, so a literal '"skill":"dev-loop"' match silently misses a
# record serialized with a space and the hook never fires.
round_events() {
	jq -r 'select(.message.content != null)
		| .message.content[]?
		| select(.type == "tool_use")
		| if (.name == "Skill" and .input.skill == "dev-loop") then "LOOP"
		  elif (.name == "Agent") then "AGENT"
		  else empty end' "$1" 2>/dev/null
}

# dispatched_this_round EVENTS
# True when an AGENT token appears after the last LOOP token. "This round" is
# deliberately the window since the most recent s:dev-loop invocation: an agent
# dispatched three rounds ago is not this round's dispatch, and counting it is
# how a round with nothing started reads as satisfied.
dispatched_this_round() {
	printf '%s\n' "$1" | awk '
		/^LOOP$/  { seen = 1; agent = 0; next }
		/^AGENT$/ { if (seen) agent = 1 }
		END       { exit(agent ? 0 : 1) }'
}

announce_no_planner() {
	local session_id marker
	session_id="$1"
	marker="${TMPDIR:-/tmp}/round_dispatch_guard.${session_id:-nosession}.announced"
	# Announced once per session: said out loud the first time, then quiet. A
	# no-op repeated every turn is noise, and noise is how a gate gets disabled.
	[ -e "$marker" ] && exit 0
	: >"$marker"
	{
		echo "round_dispatch_guard: COULD NOT EVALUATE — no dispatch planner at $PLANNER."
		echo
		echo "s:dev-loop step 6 (DISPATCH) is unenforced this session. This is a no-op, said"
		echo "out loud rather than passed in silence: the planner (dotfiles-dev#433 item 2)"
		echo "has not shipped yet, so nothing can be asked which candidates are dispatchable."
		echo "Run step 6 by hand this round, and do not read this hook's silence as a clear"
		echo "board once the planner lands."
	} >&2
	exit 1
}

main() {
	local payload active transcript session_id events plan dispatchable excluded

	payload="$(cat)"

	# Never block a stop that a hook already caused — one nudge per turn.
	active="$(printf '%s' "$payload" | jq -r '.stop_hook_active // false' 2>/dev/null)"
	[[ "$active" == "true" ]] && exit 0

	transcript="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)"
	[ -n "$transcript" ] && [ -r "$transcript" ] || exit 0
	session_id="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"

	events="$(round_events "$transcript")"
	printf '%s\n' "$events" | grep -qx LOOP || exit 0
	dispatched_this_round "$events" && exit 0

	[ -r "$PLANNER" ] || announce_no_planner "$session_id"

	plan="$(timeout "$PLANNER_TIMEOUT" python3 "$PLANNER" 2>/dev/null)"
	# Shape, not just keys: `{"dispatchable":null,"excluded":{}}` has both keys, formats to
	# nothing, and would exit 0 below as a false "nothing to dispatch". Every dispatchable
	# record needs an issue number; every excluded record needs a non-empty reason — an
	# exclusion with no reason is exactly the silent skip this hook exists to refuse.
	if ! printf '%s' "$plan" | jq -e '
		(.dispatchable | type == "array") and (.excluded | type == "array")
		and all(.dispatchable[]; (.issue | type == "number"))
		and all(.excluded[]; (.issue | type == "number") and ((.reason // "") | length > 0))
	' >/dev/null 2>&1; then
		{
			echo "round_dispatch_guard: dispatch plan UNREADABLE (planner failed, timed out, or"
			echo "printed something that is not the documented object) — not the same as empty."
			echo
			echo "Re-run the planner before reporting the board clear. A planner that fails and"
			echo "is then read as routine silence is the defect this hook exists to catch"
			echo "(dotfiles-dev#433)."
		} >&2
		exit 2
	fi

	dispatchable="$(printf '%s' "$plan" |
		jq -r '.dispatchable[]? | "  #\(.issue)  \((.surface // []) | join(", "))"')"
	[ -n "$dispatchable" ] || exit 0

	excluded="$(printf '%s' "$plan" | jq -r '.excluded[]? | "  #\(.issue)  \(.reason)"')"
	{
		echo "This dev-loop round has dispatchable candidates and started no agent — do not"
		echo "stop here without dispatching."
		echo
		echo "Dispatchable now (issue and its file surface):"
		printf '%s\n' "$dispatchable"
		if [ -n "$excluded" ]; then
			echo
			echo "Excluded, with the reason each was excluded:"
			printf '%s\n' "$excluded"
		fi
		echo
		echo "Dispatch them, or move each one into the excluded list with its own named"
		echo "reason. There is no bare override: the legitimate zero case is every candidate"
		echo "carrying a reason, which is what keeps this gate from crying wolf."
	} >&2
	exit 2
}

main "$@"
