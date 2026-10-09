#!/bin/bash
# Stop hook: refuse to end a dev-loop round that had assignable open PRs and started no
# review agent — the deterministic half of s:dev-loop step 4b (REVIEW FAN-OUT), sibling of
# uncommitted_worktree_guard.sh, dispatch_free_surface_guard.sh and round_dispatch_guard.sh
# (dotfiles-linux-dev#480).
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
# ⚠️ A REVIEW DISPATCH IS IDENTIFIED BY ITS `name`, not by any Agent dispatch existing. The
# first cut selected every `Agent` tool_use, so an unrelated agent in flight suppressed this
# guard entirely — fails open, in an orchestrating session most of the time (review finding on
# this file). Only `name: review-pr-<PR>` counts; see REVIEW_DISPATCH_NAME_RE.
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
# ⚠️ `rung.status` has THREE outcomes, not two, because "no rung" and "the legitimate zero
# case" are different claims:
#   ok      — dispatch; block if anything is assignable and nothing was started.
#   none    — the #479 probe ran and resolved neither qwen nor codex. ANNOUNCED ONCE per
#             session, then quiet, and never blocking (see announce_no_rung). It is not the
#             zero case: "every PR carries a reason" means the planner judged each PR, while
#             "no rung" means the mechanism that produces those reasons was never available
#             and nothing was judged at all. Passing silently would assert "nothing needed
#             asking" when the honest statement is "I could not tell"; blocking would make it
#             impossible to end a turn without signing into a reviewer runtime.
#   unknown — blindness (the probe could not be run, or timed out). BLOCKS.
# Collapsing any two of these is the #396 defect verbatim, and the same family as an empty
# `conclusion` read as "failing" or a `case` with no `*)` arm dropping a status silently.
#
# ⚠️ N is capped by API BUDGET, not by reviewer quota: five concurrent agents drained both the
# GitHub REST and GraphQL buckets (#445), and again at 09:49Z on 2026-09-23, blinding a thread
# sweep into reporting 21 PRs clean that it never read. #445's latch is the prerequisite for
# acting on a wide plan; this hook deliberately implements no latch of its own and no cap of
# its own — it reports the full assignable set and leaves the budget to the latch that owns it.
#
# SERIAL DRAIN (#646). When merging is strict-serial (a ruleset's
# strict_required_status_checks_policy, or REVIEW_FANOUT_SERIAL=1) the planner lists only the
# head of the merge queue as dispatchable and excludes the rest by name — a review of any
# other PR is voided by the merge ahead of it. Decided in the planner; this hook only says so.
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
# A big board takes the planner ~5 min (#696), far past PLANNER_TIMEOUT. A validated plan is
# cached per repo and reused while younger than CACHE_TTL_MIN minutes (0 disables); on a
# timeout the planner is re-run detached with REFRESH_TIMEOUT so the next Stop finds it.
# The cache key includes a digest of every open PR's head SHA (one REST call), so a push
# invalidates it at once — a TTL alone would let a Stop through for a head pushed after caching.
CACHE_DIR="${REVIEW_FANOUT_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/review_fanout}"
CACHE_TTL_MIN="${REVIEW_FANOUT_CACHE_TTL_MIN:-10}"
REFRESH_TIMEOUT="${REVIEW_FANOUT_REFRESH_TIMEOUT:-900}"

# dev_loop_invoked TRANSCRIPT
# Pure data: did this session's transcript ever run s:dev-loop? MIRRORS
# dispatch_free_surface_guard.sh's own function of the same name rather than sharing it —
# #405 holds that file, and a second writer on it is a guaranteed conflict. Three shapes
# count, all measured off real transcripts (dotfiles-linux-dev#404); a session that never ran the
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

# The `name` a review dispatch MUST pass to the Agent tool, as a pattern. `name` is a
# structured, pattern-validated Agent-tool parameter the DISPATCHER sets — not prose inferred
# from `description`, which is exactly the weak-proxy mistake `reviewer_ladder.sh` records for
# reading `priority` as capability, and `review_thread_gate.sh` records for reading an author
# login as a comment's role. The step-4b skill text ships this convention alongside this hook.
#
# ⚠️ NO SUCH MARKER EXISTED BEFORE THIS CHANGE. `.input.name` was read only as a display
# label. So this convention is introduced here, and the transition matters: until the step-4b
# text lands, no dispatch carries the name, the predicate below is always false, and the guard
# therefore BLOCKS rather than suppressing. That direction is deliberate for a guard whose
# whole purpose is "do not skip the fan-out" — and the block message names the in-flight agents
# it can see, so it is actionable rather than a shrug. Fail-open was the reported defect; the
# cost of fail-closed here is a nudge during the window between dispatching a review agent and
# its finishing, which the name closes once the skill text is in place.
# The optional `-<k>` is the suffix the harness appends when a teammate of that name already
# exists (`review-pr-692` -> `review-pr-692-2`, measured #694). The Agent INPUT name stays
# unsuffixed; only the spawn result's `name:` line and the teammate's own messages carry it.
# The suffix is indistinguishable from a PR number's own digits (`review-pr-12-3`); both are
# review names by construction, so no disambiguation is needed.
REVIEW_DISPATCH_NAME_RE='^review-pr-[0-9]+(-[0-9]+)?$'

# transcript_agent_facts TRANSCRIPT
# Every Agent dispatch and every fact bearing on whether it resolved, as TSV, in ONE streaming
# pass (record kinds A/S/R/E/N/I are listed below the shapes note).
#
# ⚠️ This is one pass on purpose. The previous shape ran `_agent_result_text` and
# `_task_notification_status` per dispatched id — two fresh `jq` passes over the whole file
# each, i.e. O(agents x transcript). Measured on a real orchestrating session's transcript (47
# Agent dispatches, so ~90 full scans) ONE call exceeded a 120-second timeout. This is a `Stop`
# hook: it runs at the end of every turn, so an unbounded scan is not a performance nicety, it
# is the difference between a guard that runs and one that times out and silently does nothing.
#
# `.. | strings` for the task-notification is kept, and kept deliberately: measured on real
# transcripts the identical blob appears under `.content` (a queue-operation record, on both
# enqueue AND removal), under `.prompt` (an attachment record), and eventually inside an
# ordinary delivered message. Walking every string leaf means a harness change to which shape
# delivers it cannot silently blind this — the way a `.message.content[]?` walk over a bare
# string silently blinded shape 3 of dev_loop_invoked above.
#
# Beyond the async ack, three teammate-style shapes were invisible (#694), each measured
# verbatim off real transcripts:
#   - spawn result `Spawned successfully. ... agent_id: <id>\nname: review-pr-692-2\n ...
#     will receive instructions via mailbox.` — a launch ack like the async one, with the
#     EFFECTIVE name (suffixed on a collision) on its `name:` line -> `R ack` + `E`;
#   - SendMessage result `{"success":true,"message":"Message sent to review-pr-692's
#     inbox",...}` — a delivery receipt for a resume -> `R sent`;
#   - teammate completion: NO task-notification exists for a teammate; it arrives as a USER
#     record whose string content is a teammate envelope (optionally behind an "Another Claude
#     session sent a message:" lead-in) wrapping a JSON body of type idle_notification with
#     `from`, `timestamp` and `idleReason` (`available` | `failed`) -> `I`. A batched record
#     holds several envelopes, so each is parsed on its own with fromjson: `from` and the
#     failed/completed verdict come from the SAME body. idleReason `failed` is the RESCUE case,
#     anything else is completed. Only that record shape counts (never a tool_result, assistant
#     text or a compaction summary that merely quotes one) — measured: a "continued from a
#     previous conversation" summary record carries the idle text verbatim.
# TSV, in transcript order (the idle must be ordered against dispatches): `A`/`S<TAB>id<TAB>
# name<TAB>label<TAB>ts` (Agent dispatch / SendMessage to a review teammate), `R<TAB>id<TAB>
# ack|sent|done`, `E<TAB>id<TAB>effective-name`, `N<TAB>id<TAB>completed|failed`,
# `I<TAB>name<TAB>completed|failed<TAB>ts`. `-` is an empty name/ts: a tab is whitespace to
# `read`, so an empty field would collapse into its neighbour.
transcript_agent_facts() {
	local transcript="$1"
	jq -n -r --arg ack "Async agent launched successfully" --arg re "$REVIEW_DISPATCH_NAME_RE" '
		def norm:
			if type == "string" then .
			else ([.[]? | .text // ""] | join("\n"))
			end;
		def dash: if . == null or . == "" then "-" else . end;
		inputs
		| . as $rec
		| ($rec.timestamp | dash) as $ts
		| (
			( $rec.message.content[]?
			  | select(type == "object")
			  | if (.type == "tool_use" and .name == "Agent") then
					"A\t\(.id)\t\(.input.name | dash)\t\(.input.name // .input.description // .id)\t\($ts)"
				elif (.type == "tool_use" and .name == "SendMessage"
					  and ((.input.to // "") | test($re))) then
					"S\t\(.id)\t\(.input.to)\t\(.input.to)\t\($ts)"
				elif (.type == "tool_result" and ((.content | norm) | length) > 0) then
					(.content | norm) as $t
					| .tool_use_id as $id
					| "R\t\($id)\t\(
						if ($t | contains($ack)) or ($t | contains("Spawned successfully")) then "ack"
						elif (($t | try (fromjson | .success == true) catch false)) and ($t | contains("Message sent to")) then "sent"
						else "done" end)",
					  ( $t | select(contains("Spawned successfully")) | capture("(?:^|\n)name: (?<n>[^\\s]+)")? | "E\t\($id)\t\(.n)" )
				else empty end ),
			( $rec
			  | .. | strings
			  | select(test("<tool-use-id>[^<]+</tool-use-id>"))
			  | select(test("<status>(completed|failed)</status>"))
			  | "N\t\(capture("<tool-use-id>(?<i>[^<]+)</tool-use-id>").i)\t\(capture("<status>(?<s>completed|failed)</status>").s)" ),
			( $rec
			  | select(.type == "user" and (.message.content | type) == "string")
			  | .message.content
			  | select(test("^(Another Claude session sent a message:\\s*)?<teammate-message"))
			  | capture("<teammate-message[^>]*>\\s*(?<b>\\{.*?\\})\\s*</teammate-message>"; "gs")
			  | .b
			  | (try fromjson catch empty)
			  | select(type == "object" and .type == "idle_notification" and (.from | type) == "string")
			  | "I\t\(.from)\t\(if .idleReason == "failed" then "failed" else "completed" end)\t\(.timestamp | dash)" )
		  )
	' "$transcript" 2>/dev/null
}

# review_dispatch_running TRANSCRIPT
# Descended from dispatch_free_surface_guard.sh's `subagents_running` — a mirror, not a shared
# helper (see dev_loop_invoked above for why). It has since DIVERGED in two ways that must not
# be "reconciled" by copying either direction blindly: this one discriminates review dispatches
# by `name`, and collects its facts in ONE streaming pass instead of two jq passes per id. The
# sibling still carries both original shapes; #405 owns that file today, and a shared
# hooks/lib/transcript_state.sh holding the fixed version is the named follow-up.
#
# True when a REVIEW dispatch of this session's own is still unresolved. Also always sets
# FAILED_BACKGROUND_AGENTS (the RESCUE case) and OTHER_AGENTS_IN_FLIGHT (unresolved dispatches
# that are NOT review dispatches), so main() never re-walks the transcript.
#
# 🔴 THE FIX THIS FUNCTION CARRIES (review finding on this file). It used to select EVERY
# `Agent` tool_use and suppress the guard whenever any of them was unresolved. So an agent
# dispatched for something entirely unrelated to reviewing — in an orchestrating session, most
# of them — let a Stop pass with `dispatchable` non-empty and no review agent ever started:
# the exact inverse of the contract this guard exists to enforce, and failing OPEN, where its
# sibling dispatch_free_surface_guard.sh fails closed. A guard suppressed by normal operation
# is not a guard. Only a dispatch whose `name` matches REVIEW_DISPATCH_NAME_RE suppresses now.
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
#
# A teammate spawn ("Spawned successfully … via mailbox") is the same kind of ack, and a
# SendMessage to a review teammate is a dispatch of its own whose result is only a delivery
# receipt (#694). Neither gets a task-notification; the teammate's `idle_notification` is the
# settle signal instead (`failed` idleReason = RESCUE, anything else = completed).
review_dispatch_running() {
	local transcript="$1"
	local LC_ALL=C
	FAILED_BACKGROUND_AGENTS=""
	OTHER_AGENTS_IN_FLIGHT=""
	[ -r "$transcript" ] || return 1

	local -A agent_name=() agent_label=() agent_result=() agent_note=() agent_ts=()
	local -a order=()
	local kind id field label ts
	while IFS=$'\t' read -r kind id field label ts; do
		[ -n "$id" ] || continue
		case "$kind" in
		A | S)
			# A re-dispatched id cannot happen, but last-wins is harmless and keeps the
			# ordering array free of duplicates. S is a SendMessage resuming a review
			# teammate: its own unit, in flight from the send until the teammate's next
			# idle_notification (#694).
			[ -n "${agent_name[$id]+set}" ] || order+=("$id")
			agent_name["$id"]="$field"
			agent_label["$id"]="$label"
			agent_ts["$id"]="$ts"
			;;
		R) agent_result["$id"]="$field" ;;
		# The name the harness actually gave the teammate: a collision suffixes it
		# (`review-pr-692` -> `review-pr-692-2`) while the Agent input name stays put.
		E) agent_name["$id"]="$field" ;;
		# Last wins, matching the previous `| tail -1`: a later notification supersedes an
		# earlier one for the same id.
		N) agent_note["$id"]="$field" ;;
		# A teammate going idle settles every unit of that name dispatched BEFORE it. The
		# idle blob is re-delivered in several records, so it is ordered by its own embedded
		# timestamp, never by where the copy sits in the file: a late copy must not settle a
		# SendMessage resume that was sent after the real idle. A dispatch with no timestamp
		# (`-`) is treated as oldest, and an idle with no timestamp is unorderable and settles
		# (a real idle always carries one; refusing it would block forever). The `<` is a
		# byte comparison under LC_ALL=C: under en_US/pt_BR collation punctuation is ignored,
		# so `"2026…Z" < "-"` is true there.
		#
		# ⚠️ Known limit: the idle carries no id tying it to a message, so a SendMessage to a
		# teammate that is still BUSY is settled by the idle that ends its CURRENT turn, before
		# the resumed work has run (measured: idle bodies hold type/from/timestamp/idleReason/
		# result only). That fails open for one resume; there is no signal to do better.
		I)
			local unit
			for unit in "${order[@]}"; do
				[ "${agent_name[$unit]}" = "$id" ] || continue
				[ -z "${agent_note[$unit]-}" ] || continue
				[[ "${agent_ts[$unit]}" == "-" || "$label" == "-" || "${agent_ts[$unit]}" < "$label" ]] || continue
				agent_note["$unit"]="$field"
			done
			;;
		esac
	done < <(transcript_agent_facts "$transcript")

	[ "${#order[@]}" -gt 0 ] || return 1

	local review_running=1 is_review
	for id in "${order[@]}"; do
		if [[ "${agent_name[$id]}" =~ $REVIEW_DISPATCH_NAME_RE ]]; then
			is_review=1
		else
			is_review=0
		fi

		case "${agent_result[$id]-}" in
		"")
			# No result yet — in flight.
			;;
		ack | sent)
			case "${agent_note[$id]-}" in
			completed) continue ;;
			failed)
				FAILED_BACKGROUND_AGENTS="$(printf '%s\n%s' \
					"$FAILED_BACKGROUND_AGENTS" "${agent_label[$id]}")"
				continue
				;;
			*) ;; # no notification yet — still working
			esac
			;;
		*) continue ;; # a synchronous call's real result already landed
		esac

		# Still in flight. Which question it answers depends on what it was dispatched for.
		if [ "$is_review" -eq 1 ]; then
			review_running=0
		else
			OTHER_AGENTS_IN_FLIGHT="$(printf '%s\n%s' \
				"$OTHER_AGENTS_IN_FLIGHT" "${agent_label[$id]}")"
		fi
	done

	FAILED_BACKGROUND_AGENTS="$(printf '%s\n' "$FAILED_BACKGROUND_AGENTS" | sed '/^$/d')"
	OTHER_AGENTS_IN_FLIGHT="$(printf '%s\n' "$OTHER_AGENTS_IN_FLIGHT" | sed '/^$/d')"
	[ "$review_running" -eq 0 ] && return 0
	return 1
}

# open_pr_heads CWD
# Prints a digest of "<number>:<head sha>" for every open PR, or fails. A failure means the
# cache cannot be proven current, so the caller runs with no cache at all.
open_pr_heads() {
	local out
	out="$(cd "$1" && timeout 20 gh api --paginate 'repos/{owner}/{repo}/pulls?state=open&per_page=100' \
		--jq '.[] | "\(.number):\(.head.sha)"' 2>/dev/null)" || return 1
	printf '%s\n' "$out" | sort | cksum | cut -d' ' -f1
}

# refresh_running LOCK — a detached refresh holds LOCK; one older than the refresh timeout is stale.
refresh_running() {
	[ -d "$1" ] && [ -z "$(find "$1" -maxdepth 0 -mmin "+$((REFRESH_TIMEOUT / 60 + 1))" 2>/dev/null)" ]
}

# publish_cache TMP CACHE — rename TMP over CACHE (readers never see a half-written file) and
# drop entries cached under older PR heads.
publish_cache() {
	mv "$1" "$2" && find "$CACHE_DIR" -maxdepth 1 -name "$cwdsum.*.json" ! -name "${2##*/}" -delete 2>/dev/null
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
		echo "(dotfiles-linux-dev#480, same shape as #396 and #433)."
	} >&2
	exit 2
}

# announce_no_rung SESSION_ID
# `rung.status: none` — the #479 probe RAN and resolved neither qwen nor codex.
#
# ⚠️ This is NOT the legitimate zero case, and reading it as one conflates two
# different facts:
#   "every PR carries its own named reason"  — the planner ran and JUDGED each PR.
#                                              That legitimately passes.
#   "no rung resolved"                       — the mechanism that would produce
#                                              those reasons was never available.
#                                              NOTHING was judged at all.
# Collapsing the second into the first is the error this repo keeps paying for: a
# filtered listing's `(empty)` read as "absent", an empty `conclusion` read as
# "failing", a `case` with no `*)` arm dropping a status silently. An absent verdict
# is UNKNOWN, never a value — a guard that passes here is asserting "nothing needed
# asking" when the honest statement is "I could not tell".
#
# But it must not BLOCK either: nobody should be unable to end a turn because they
# have not signed into qwen or codex. That is a gate crying wolf, and a re-ping every
# cycle trains the operator to ignore the notification — worse than the idle slot it
# was meant to fix.
#
# So: say it ONCE per session, do not block. Same shape, same reason, and
# deliberately the same mechanism as round_dispatch_guard.sh's announce_no_planner —
# a reader who found two near-identical "mechanism unavailable" conditions handled
# two different ways would reasonably assume one of them is a bug.
#
# ⚠️ `exit 1`, NOT `exit 0`: a Stop hook blocks on 2 and surfaces stderr on any other
# non-zero, while exit 0 discards it. Exit 0 would make this announcement invisible,
# which is the silent pass this function exists to replace — the distinction that
# makes "announce, don't block" expressible at all.
announce_no_rung() {
	local session_id="$1" marker
	marker="${TMPDIR:-/tmp}/review_fanout_guard.${session_id:-nosession}.norung"
	# Once per session: said out loud the first time, then quiet. A notice repeated
	# every turn is noise, and noise is how a gate gets disabled.
	[ -e "$marker" ] && exit 0
	: >"$marker"
	{
		echo "review_fanout_guard: no fallback reviewer rung resolved (qwen/codex both"
		echo "unavailable) — the reviewer slot was NOT evaluated this round; not blocking."
		echo
		echo "This is not the same as 'no PR needed a reviewer'. The #479 probe found no"
		echo "assignable runtime, so no PR was judged at all — said out loud rather than"
		echo "passed in silence, because an absent verdict is UNKNOWN, never a value."
		echo
		echo "Sign in to qwen or codex to restore step 4b's fan-out, or accept that this"
		echo "round reviews nothing. Not repeated again this session."
	} >&2
	exit 1
}

main() {
	local payload active cwd transcript session_id plan rung_status dispatchable excluded

	payload="$(cat)"

	# Never block a stop that a hook already caused — one nudge per turn.
	active="$(printf '%s' "$payload" | jq -r '.stop_hook_active // false' 2>/dev/null)"
	[[ "$active" == "true" ]] && exit 0

	cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
	[ -n "$cwd" ] || cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
	transcript="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)"
	[ -n "$transcript" ] && [ -r "$transcript" ] || exit 0
	session_id="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"

	$GIT -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

	dev_loop_invoked "$transcript" || exit 0
	# Only an unresolved REVIEW dispatch suppresses. An unrelated agent in flight does not —
	# see review_dispatch_running's own header for the fails-open defect that was.
	review_dispatch_running "$transcript" && exit 0

	[ -r "$PLANNER" ] || block_unreadable "no review fan-out planner at $PLANNER (run 'make ai_clients')."

	# The planner runs in the repo the payload names, never this hook's ambient cwd: `gh pr
	# list` resolves its repo from the working directory, and the harness can reset cwd to a
	# DIFFERENT repository between calls (dotfiles-linux-dev#229) — a plan computed against the
	# wrong repo is worse than no plan, because it reads as an answer.
	cwdsum="$(printf '%s' "$cwd" | cksum | cut -d' ' -f1)"
	lock="$CACHE_DIR/$cwdsum.lock"
	cache=""
	# No cache when disabled, or when the open-PR heads cannot be read (cannot prove it current).
	if [ "$CACHE_TTL_MIN" -gt 0 ] && heads="$(open_pr_heads "$cwd")"; then
		cache="$CACHE_DIR/$cwdsum.$heads.json"
	fi
	plan=""
	planner_rc=0
	if [ -n "$cache" ] && [ -n "$(find "$cache" -mmin "-$CACHE_TTL_MIN" 2>/dev/null)" ]; then
		plan="$(cat "$cache")"
	elif [ -n "$cache" ] && refresh_running "$lock"; then
		# A planner started now would just time out too, 90s per Stop, while the refresh runs.
		block_unreadable "review fan-out plan not cached yet — a background refresh is already running (up to ${REFRESH_TIMEOUT}s); the next Stop reads its cached plan. Not the same as empty."
	else
		plan="$(cd "$cwd" && timeout "$PLANNER_TIMEOUT" python3 "$PLANNER" 2>/dev/null)" || planner_rc=$?
	fi

	if [ "$planner_rc" -eq 124 ]; then
		if [ -z "$cache" ]; then
			block_unreadable "review fan-out planner timed out after ${PLANNER_TIMEOUT}s — plan caching is off (REVIEW_FANOUT_CACHE_TTL_MIN=0 or the open-PR heads were unreadable), so there is no background refresh; raise REVIEW_FANOUT_PLANNER_TIMEOUT. Not the same as empty."
		fi
		# Detached refresh: one at a time (mkdir lock; refresh_running treats an old lock as stale).
		mkdir -p "$CACHE_DIR"
		find "$lock" -maxdepth 0 -mmin "+$((REFRESH_TIMEOUT / 60 + 1))" -exec rmdir {} + 2>/dev/null
		if mkdir "$lock" 2>/dev/null; then
			(cd "$cwd" && tmp="$(mktemp "$cache.XXXXXX")" \
				&& timeout "$REFRESH_TIMEOUT" python3 "$PLANNER" >"$tmp" 2>/dev/null \
				&& jq -e '.rung.status' "$tmp" >/dev/null 2>&1 && publish_cache "$tmp" "$cache"
				rm -f "$tmp"; rmdir "$lock") >/dev/null 2>&1 </dev/null &
		fi
		block_unreadable "review fan-out planner timed out after ${PLANNER_TIMEOUT}s — a background refresh is running (up to ${REFRESH_TIMEOUT}s); the next Stop reads its cached plan. Not the same as empty."
	fi

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
		rm -f "$cache"
		block_unreadable "review fan-out plan UNREADABLE (planner failed, timed out, or printed something that is not the documented object) — not the same as empty."
	fi

	if [ -n "$cache" ] && [ -z "$(find "$cache" -mmin "-$CACHE_TTL_MIN" 2>/dev/null)" ]; then
		mkdir -p "$CACHE_DIR" && tmp="$(mktemp "$cache.XXXXXX")" \
			&& printf '%s' "$plan" >"$tmp" && publish_cache "$tmp" "$cache"
		rm -f "${tmp:-}"
	fi

	rung_status="$(printf '%s' "$plan" | jq -r '.rung.status')"
	case "$rung_status" in
	ok) ;;
	none)
		announce_no_rung "$session_id"
		;;
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
		  + (if (.ladder // "") != "" then "  [ladder: \(.ladder)] -> run_fallback_review now, no human prompt" else "" end)
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
		if [ -n "$OTHER_AGENTS_IN_FLIGHT" ]; then
			# Named, not silently counted as review capacity: these agents in flight are
			# exactly what used to suppress this guard entirely (fails open). Saying which
			# they are is what makes the block actionable instead of a shrug.
			echo "Agents in flight, none of them a review dispatch — they do not cover the"
			echo "fan-out and no longer suppress this check:"
			printf '%s\n' "$OTHER_AGENTS_IN_FLIGHT" | sed 's/^/  /'
			echo
		fi
		echo "Reviewer rung: $(printf '%s' "$plan" | jq -r '.rung | "\(.status) \(.runtime) \(.model)"')"
		echo
		if [ "$(printf '%s' "$plan" | jq -r '.serial // false')" = "true" ]; then
			echo "Serial drain (strict merges, #646): only the head of the merge queue is listed —"
			echo "one reviewer at a time; the rest are excluded below until it merges."
			echo
		fi
		echo "Needs a reviewer now (one agent per PR — N single-PR ladder calls, which is what"
		echo "reviewer_ladder.sh's one-PR-per-invocation cap permits, never a loop inside one."
		echo "Dispatch each with the Agent tool's name set to review-pr-<PR>, e.g."
		echo "name: review-pr-520 — that name is how this guard knows a review is under way):"
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
