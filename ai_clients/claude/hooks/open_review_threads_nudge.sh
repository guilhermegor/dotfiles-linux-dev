#!/bin/bash
# Stop hook: refuse to end the turn while ANY open PR in this repo has review threads that are
# not finished — no reply, or replied and still open.
#
# This is the LOOP half, and it is a different job from `pr_merge_threads_guard.sh`.
#
# That guard blocks a bad merge. It is necessary and it is not sufficient, because blocking the
# exit does not drive the work: a reviewer posts findings minutes after a push, the agent has
# already moved on to another task, and nothing brings it back. The threads then sit open until
# a HUMAN notices and asks — which is precisely the dependency being removed. Measured across
# blueprintx PRs #180 and #182: three separate rounds of review findings, each one surfaced by
# the user asking, never by the loop noticing.
#
# A Stop hook is the right shape because "am I done?" is exactly the question whose answer the
# open threads change. Exit 2 feeds stderr back to the model and makes it continue, so the loop
# closes without anyone remembering anything.
#
# ⚠️ Repo-wide, not branch-scoped (dotfiles-dev#397). The original version resolved the PR
# STRICTLY via `gh pr view` on the current branch, and that lookup fails open exactly where the
# orchestrator session lives: on a detached HEAD (every `worktree add --detach` used to inspect
# a PR) or on a branch that carries no PR of its own — which made this hook a structural no-op
# in the one session that runs `/dev-loop`. Measured: #317 carried an unanswered Major CodeRabbit
# finding through an entire round, surfaced only because `subagent_stop_sweep.sh` was run by
# hand — the exact human-asks path this hook exists to remove. Fix: keep the branch-PR lookup as
# the fast, cheap common case (a contributor session on a feature branch still pays for exactly
# one gate call, same as before #397); fall back to a repo-wide scan only when that lookup comes
# up empty (no PR for this branch/HEAD).
#
# ⚠️ Bound the cost of the fallback scan — it is up to one gate call per open PR (~23 measured on
# this repo), far heavier than the single-PR fast path:
#   - CAP: at most $OPEN_THREADS_NUDGE_MAX_PRS PRs (default 50) are ever queried in one scan.
#   - SHORT-CIRCUIT: the scan stops at the first non-clean PR it finds — the nudge only needs ONE
#     reason to block, never an exhaustive report (that report is `subagent_stop_sweep.sh`'s job,
#     reused here via the same gate, not re-derived).
#   - CACHE: the scan's verdict is cached per session under
#     `$CLAUDE_CONFIG_DIR/open-threads-nudge/`, for $OPEN_THREADS_NUDGE_CACHE_TTL seconds
#     (default 300), so a long session's many Stops don't re-run a full scan on every turn.
#
# ⚠️ A cached verdict names a PR whose STATE can change inside the TTL window (dotfiles-dev#423).
# Measured on blueprintx 2026-09-20: PR #566 merged 61s after the scan that cached "CodeRabbit
# still running" against it, and the hook replayed that stale verdict on three more Stops over the
# next four minutes — a snapshot that was true when taken and false every time it was printed
# again. Do NOT fix this by shortening the TTL (trades a benign false positive for the rate-limit
# pressure the TTL exists to absorb — this account already hit the GitHub quota four times that
# day). Instead, a cache hit that is ABOUT TO PRODUCE A NUDGE spends exactly one extra `gh pr view`
# call re-confirming the named PR is still OPEN before printing — cost bounded by the number of
# PRs actually flagged (0-1), not by the scan size. A PR that has merged/closed since is dropped
# silently, the same fail-open shape the rest of this scan already uses.
#
# ⚠️ `stop_hook_active` MUST be honoured. Claude Code sets it when the stop was itself triggered
# by a hook; ignoring it means blocking the stop that this very hook caused, forever. The model
# gets one nudge per turn, not an inescapable loop.
#
# Fails OPEN on everything it cannot resolve (no gh, no jq, no network, no PR anywhere in the
# repo) — a nudge that fires on its own blindness is noise, and noise gets the hook deleted.
#
# ⚠️ dotfiles-dev#491: `statusCheckRollup` mixes two node types that read alike and behave
# nothing alike. A `CheckRun` is work a runner is doing — QUEUED/IN_PROGRESS means it WILL reach
# a conclusion, so waiting is sound. A `StatusContext` is an assertion someone POSTED; its
# PENDING carries NO completion guarantee. The shared gate's own `running` filter already
# branches on `__typename`, but folds a merely-PENDING, non-required StatusContext into the same
# bucket as a real in-flight CheckRun — and CodeRabbit on this repo (under 10 stars, no
# auto-review) sits at PENDING for its whole life whenever nobody runs `@coderabbitai review`.
# Measured 2026-09-23: 4 of the last 8 merged PRs merged while still PENDING; the hook fired 3x
# in 15 minutes on #486 with nothing having changed. `review_thread_gate.sh` is held by sibling
# work, so this file re-queries the SAME statusCheckRollup with `isRequired` added (GitHub's
# `RequirableByPullRequest` interface, on both node types) and downgrades a non-required,
# still-PENDING StatusContext from "still running" to "pending (no completion expected)" — which
# does NOT block. A genuinely in-flight CheckRun, or a still-non-terminal REQUIRED context,
# keeps blocking exactly as before: the wait is bounded by relevance, not removed.
#
# ⚠️ dotfiles-dev#490/#497 reconciliation: #497 (the shared gate's comment-channel fix) is no
# longer "sibling work" once merged, and its own author suggested folding this file's isRequired
# split into review_thread_gate.sh's `_gate_running_filter` to retire this second query.
# Deliberately NOT done: `subagent_stop_sweep.sh`'s `sweep_review_gate()` is a THIRD, unlisted
# caller of `gate_pr_thread_state` with a fixed `case "$GATE_STATUS" in clean|problems|running|
# unreadable)` — adding a new status value to the shared gate's contract (the pending/running
# split this file makes) would silently drop that PR from the board sweep's report, a caller
# neither #490 nor #491 touched or tested. The two features are orthogonal (comment-channel
# review-thread problems vs. checks running/pending-indefinite) and share only the roster-login
# lookup, which this file already reuses via the sourced `_gate_roster_logins` rather than
# re-deriving it — so keeping the second query here costs one extra `gh api graphql` call per
# gated PR, not a duplicated implementation.

set -u

command -v jq >/dev/null 2>&1 || exit 0
command -v gh >/dev/null 2>&1 || exit 0

ROSTER_FILE='.review-bots.yaml'
: "${OPEN_THREADS_NUDGE_MAX_PRS:=50}"
: "${OPEN_THREADS_NUDGE_CACHE_TTL:=300}"

# GraphQL query + classification live in one shared place (dotfiles-dev#167):
# the SubagentStop board sweep (subagent_stop_sweep.sh) calls the identical
# gate for every open PR, and a second hand-copy is exactly the risk this
# file's own header warns about (re-deriving a gate's verdict instead of
# calling it).
# shellcheck source=lib/review_thread_gate.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/review_thread_gate.sh"

# _status_check_query
# A SECOND, narrower GraphQL query than the gate's own -- adds `isRequired` (GitHub's
# RequirableByPullRequest interface) to both node types so this file can split a genuinely
# running CheckRun from an unbounded-PENDING StatusContext without touching the shared gate
# (dotfiles-dev#491 -- review_thread_gate.sh is held by sibling work). Also requests `totalCount`
# and the same reviewer-identity fields the gate's own `_gate_running_filter` uses
# (`checkSuite.app.slug` / `creator.login`), caught by CodeRabbit review on PR #498: a page that
# cannot hold every context is indistinguishable from one that legitimately has nothing left
# running, and skipping the gate's roster scoping here would let an unrelated CI check (or an
# unrelated bot's check) override the gate's own reviewer-scoped verdict.
_status_check_query() {
	cat <<'GRAPHQL'
query($owner:String!, $repo:String!, $number:Int!) {
  repository(owner:$owner, name:$repo) {
    pullRequest(number:$number) {
      commits(last:1) {
        nodes {
          commit {
            statusCheckRollup {
              contexts(first:100) {
                totalCount
                nodes {
                  __typename
                  ... on CheckRun {
                    name
                    status
                    isRequired(pullRequestNumber:$number)
                    checkSuite { app { slug } }
                  }
                  ... on StatusContext {
                    context
                    state
                    isRequired(pullRequestNumber:$number)
                    creator { login }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
GRAPHQL
}

# _classify_checks OWNER REPO NUMBER
# Sets RUNNING_DETAIL (a non-terminal, roster-scoped CheckRun, or a still-non-terminal REQUIRED
# roster-scoped StatusContext -- either is worth blocking on) and PENDING_DETAIL (a non-required,
# roster-scoped StatusContext sitting at PENDING/EXPECTED -- nothing promises it ever resolves).
# Reuses `_gate_roster_logins` (from the sourced review_thread_gate.sh) so the roster read and its
# `__NO_ROSTER__`/`github-actions` handling can never drift from the gate's own scoping.
# Leaves both empty when the page is truncated (totalCount exceeds the returned nodes -- a check
# beyond this page could be the real running one) or on any other read error: this call is
# advisory on top of the gate's own "running" verdict, never the sole source of truth, so a
# failure here falls back to the gate's original wording (_reclassify_running below) instead of
# inventing a new failure mode.
_classify_checks() {
	local owner="$1" repo="$2" number="$3" json roster total have
	RUNNING_DETAIL=""
	PENDING_DETAIL=""
	json="$(gh api graphql -f query="$(_status_check_query)" \
		-F owner="$owner" -F repo="$repo" -F number="$number" 2>/dev/null)" || return 0
	printf '%s' "$json" | jq -e '.errors' >/dev/null 2>&1 && return 0

	total="$(printf '%s' "$json" | jq -r \
		'.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.totalCount // 0' \
		2>/dev/null)"
	have="$(printf '%s' "$json" | jq -r \
		'.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes | length' \
		2>/dev/null)"
	[[ "$total" =~ ^[0-9]+$ ]] || total=0
	[[ "$have" =~ ^[0-9]+$ ]] || have=0
	[ "$total" -gt "$have" ] && return 0

	roster="$(_gate_roster_logins "$ROSTER_FILE")"

	# ⚠️ `. as $n` MUST come before any `$bots | index(...)` call: `index()` evaluates its
	# argument with `.` rebound to $bots (its own input), not to the node -- the exact fault
	# review_thread_gate.sh's own `_gate_running_filter` comment warns about ("Cannot index array
	# with string ..."). Binding the node to $n first, then reading $n.checkSuite/$n.creator
	# inside index()'s argument, is what keeps the lookup pointed at the node.
	RUNNING_DETAIL="$(printf '%s' "$json" | jq -r --arg roster "$roster" '
		($roster | split("\n") | map(select(length > 0)) | map(ascii_downcase)
		 | map(select(. != "github-actions"))) as $bots
		| [.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[]?
		 | . as $n
		 | if $n.__typename == "CheckRun" and $n.status != "COMPLETED"
		        and (($bots | index(($n.checkSuite.app.slug // "") | ascii_downcase)) != null)
		   then $n.name
		   elif $n.__typename == "StatusContext"
		        and ($n.state == "PENDING" or $n.state == "EXPECTED")
		        and $n.isRequired
		        and (($bots | index(($n.creator.login // "") | ascii_downcase)) != null)
		   then $n.context
		   else empty end]
		| join(", ")' 2>/dev/null)"

	PENDING_DETAIL="$(printf '%s' "$json" | jq -r --arg roster "$roster" '
		($roster | split("\n") | map(select(length > 0)) | map(ascii_downcase)
		 | map(select(. != "github-actions"))) as $bots
		| [.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[]?
		 | . as $n
		 | select($n.__typename == "StatusContext"
		          and ($n.state == "PENDING" or $n.state == "EXPECTED")
		          and ($n.isRequired | not)
		          and (($bots | index(($n.creator.login // "") | ascii_downcase)) != null))
		 | $n.context]
		| join(", ")' 2>/dev/null)"
}

# _reclassify_running OWNER REPO NUMBER
# Call only when GATE_STATUS=="running". Re-derives the split above and downgrades the verdict
# to "pending_indefinite" when nothing left waiting on is a genuine CheckRun or a required
# context. Leaves GATE_STATUS/GATE_DETAIL exactly as the gate set them when the re-query itself
# comes back empty (a transient read failure) -- see _classify_checks.
_reclassify_running() {
	local owner="$1" repo="$2" number="$3"
	[ "$GATE_STATUS" = "running" ] || return 0

	_classify_checks "$owner" "$repo" "$number"

	if [ -n "$RUNNING_DETAIL" ]; then
		GATE_DETAIL="$RUNNING_DETAIL"
	elif [ -n "$PENDING_DETAIL" ]; then
		GATE_STATUS="pending_indefinite"
		GATE_DETAIL="$PENDING_DETAIL"
	fi
}

# _emit_verdict NUMBER PREFIX
# Prints the human-facing message for the current $GATE_STATUS/$GATE_DETAIL (set by a prior
# gate_pr_thread_state call) and returns the exit code the hook should use. A non-empty PREFIX
# marks a repo-wide finding, so the message never reads as if it came from the branch's own PR.
_emit_verdict() {
	local number="$1" prefix="$2"

	case "$GATE_STATUS" in
	unreadable)
		{
			echo "${prefix}PR #${number}: could NOT read the review threads (GitHub API unreachable"
			echo "after 3 attempts) — so their state is UNKNOWN, not clean."
			echo
			echo "Do not report this PR as finished on the strength of a check that never ran."
			echo "Re-read the threads when the API answers again."
		} >&2
		return 2
		;;
	running)
		# ⚠️ "Zero open threads" is only a VERDICT once the reviewers have finished. Measured on
		# blueprintx#186, threads read 0 and a CodeRabbit re-review opened SIX new ones thirty
		# seconds later — and the turn had already been reported as clean.
		{
			echo "${prefix}PR #${number}: every review thread is answered and resolved RIGHT NOW, but"
			echo "checks are still running — so that reading is a snapshot, not a verdict."
			echo
			echo "  still running: ${GATE_DETAIL}"
			echo
			echo "A reviewer bot posts its findings when its own check finishes. Wait for the"
			echo "checks to go terminal and re-read the threads before reporting this PR as clean."
		} >&2
		return 2
		;;
	pending_indefinite)
		# Not a verdict to wait out — a StatusContext PENDING with isRequired=false carries no
		# completion guarantee at all (dotfiles-dev#491). Reported, never waited on.
		{
			echo "${prefix}PR #${number}: pending (no completion expected): ${GATE_DETAIL} —"
			echo "not a required context, so nothing promises it will ever resolve. Not blocking."
		} >&2
		return 0
		;;
	unreviewed)
		# Not a thread finding, and this hook only ever blocked on thread findings. The gate
		# gained this status with #505; the catch-all below would have reported "still has
		# unfinished review threads" for a PR with none, which is simply untrue. Reported so
		# the gap stays visible, never blocking -- an unreviewed PR is the reviewer-slot step's
		# problem, not a reason to refuse to end a turn.
		{
			echo "${prefix}PR #${number}: no reviewer has reported on this head yet — so its"
			echo "threads being empty is not yet a verdict. Not blocking."
		} >&2
		return 0
		;;
	clean)
		return 0
		;;
	problems | *)
		{
			echo "${prefix}PR #${number} still has unfinished review threads — do not stop here."
			echo
			printf '%s\n' "$GATE_DETAIL"
			echo
			echo "For each: verify the finding against the code (some are wrong — refute those with"
			echo "measurement), reply with what changed and why, then resolve the conversation."
			echo
			echo "Checked live. The CI check cannot be trusted for this: it is evaluated on push and"
			echo "on new comments, and NOTHING re-runs it when a thread is resolved."
		} >&2
		return 2
		;;
	esac
}

# _scan_cache_path SESSION_ID OWNER NAME
# Prints the cache file path, or fails (empty stdout, non-zero return) when there is no session
# id to key it by, or the cache directory cannot be created — either way the caller treats that
# as "no cache available" and scans fresh instead of erroring.
_scan_cache_path() {
	local session_id="$1" owner="$2" name="$3" dir
	[ -n "$session_id" ] || return 1
	dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/open-threads-nudge"
	mkdir -p "$dir" 2>/dev/null || return 1
	printf '%s/%s-%s_%s\n' "$dir" "$session_id" "$owner" "$name"
}

# _repo_wide_scan OWNER NAME SESSION_ID
# Sets GATE_STATUS/GATE_DETAIL/REPORT_NUMBER to the FIRST non-clean open PR found (REPORT_NUMBER
# stays empty and GATE_STATUS=clean when every scanned PR is clean, or there are none), reusing
# a same-session cache when it is still fresh. Returns 1 only when the PR list itself could not
# be read — the caller's fail-open case.
_repo_wide_scan() {
	local owner="$1" name="$2" session_id="$3" cache now ts age cached prs n state

	cache="$(_scan_cache_path "$session_id" "$owner" "$name" 2>/dev/null)" || cache=""
	if [ -n "$cache" ] && [ -r "$cache" ]; then
		now="$(date +%s)"
		cached="$(cat "$cache" 2>/dev/null)"
		ts="$(printf '%s' "$cached" | jq -r '.ts // 0' 2>/dev/null)"
		[[ "$ts" =~ ^[0-9]+$ ]] || ts=0
		age=$((now - ts))
		if [ "$age" -ge 0 ] && [ "$age" -lt "$OPEN_THREADS_NUDGE_CACHE_TTL" ]; then
			REPORT_NUMBER="$(printf '%s' "$cached" | jq -r '.number // empty' 2>/dev/null)"
			GATE_STATUS="$(printf '%s' "$cached" | jq -r '.status // "clean"' 2>/dev/null)"
			GATE_DETAIL="$(printf '%s' "$cached" | jq -r '.detail // empty' 2>/dev/null)"

			# The cache can outlive the PR's own state (dotfiles-dev#423) -- a merge inside the
			# TTL leaves a verdict naming a PR that is no longer open. Pay for exactly one live
			# re-check, and only when the cache is about to produce a nudge (REPORT_NUMBER set).
			if [ -n "$REPORT_NUMBER" ]; then
				state="$(gh pr view "$REPORT_NUMBER" --repo "$owner/$name" \
					--json state --jq .state 2>/dev/null)"
				if [ "$state" != "OPEN" ]; then
					REPORT_NUMBER=""
					GATE_STATUS="clean"
					GATE_DETAIL=""
				fi
			fi
			return 0
		fi
	fi

	prs="$(gh pr list --repo "$owner/$name" --state open --json number \
		--limit "$OPEN_THREADS_NUDGE_MAX_PRS" --jq '.[].number' 2>/dev/null)" || return 1

	REPORT_NUMBER=""
	GATE_STATUS="clean"
	GATE_DETAIL=""
	while read -r n; do
		[ -n "$n" ] || continue
		gate_pr_thread_state "$owner" "$name" "$n" "$ROSTER_FILE"
		# An unreadable answer fails OPEN here, and is never cached. The two paths differ
		# deliberately: the branch-scoped path above fails CLOSED because that PR is this
		# session's own work, while a transient GraphQL failure on some unrelated PR must not
		# block this stop — and caching it would extend one blip across the whole TTL.
		if [ "$GATE_STATUS" = "unreadable" ]; then
			return 1
		fi
		if [ "$GATE_STATUS" = "running" ]; then
			_reclassify_running "$owner" "$name" "$n"
		fi
		# A non-required, indefinitely-PENDING status is not a reason to stop the scan here --
		# it never blocks, so it must not be mistaken for the one finding this scan is looking
		# for (dotfiles-dev#491). Keep looking at the rest of the open PRs.
		if [ "$GATE_STATUS" = "pending_indefinite" ]; then
			continue
		fi
		# Same reasoning one status along: "nobody has reviewed PR #N yet" is not the open-thread
		# finding this scan looks for, and stopping the scan on it would hide a real finding on a
		# later PR behind an unreviewed earlier one.
		if [ "$GATE_STATUS" = "unreviewed" ]; then
			continue
		fi
		if [ "$GATE_STATUS" != "clean" ]; then
			REPORT_NUMBER="$n"
			break
		fi
	done <<<"$prs"

	if [ -n "$cache" ]; then
		jq -nc --arg n "$REPORT_NUMBER" --arg s "$GATE_STATUS" --arg d "$GATE_DETAIL" \
			--argjson ts "$(date +%s)" \
			'{ts: $ts, number: (if ($n | length) > 0 then $n else null end), status: $s, detail: $d}' \
			>"$cache" 2>/dev/null || true
	fi
	return 0
}

main() {
	local payload active number repo owner name session_id

	payload="$(cat)"

	# Never block a stop that a hook already caused.
	active="$(printf '%s' "$payload" | jq -r '.stop_hook_active // false' 2>/dev/null)"
	[[ "$active" == "true" ]] && exit 0

	git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

	# Fast path: the current branch's own open PR. Unchanged from before #397 — a contributor
	# session on a feature branch still pays for exactly one gate call.
	number="$(gh pr view --json number,state -q 'select(.state=="OPEN") | .number' 2>/dev/null)"
	if [[ "$number" =~ ^[0-9]+$ ]]; then
		repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || exit 0
		owner="${repo%%/*}"
		name="${repo##*/}"
		[[ -n "$owner" && -n "$name" ]] || exit 0

		# ⚠️ FAIL CLOSED on an unreadable answer — see gate_pr_thread_state's own retry/partial-body
		# handling. Measured 2026-08-17: a run of HTTP 503s swallowed a thread reply, and the thread
		# then sat resolved with no reasoning recorded.
		gate_pr_thread_state "$owner" "$name" "$number" "$ROSTER_FILE"
		[ "$GATE_STATUS" = "running" ] && _reclassify_running "$owner" "$name" "$number"
		_emit_verdict "$number" ""
		exit $?
	fi

	# No PR for this branch/HEAD (detached, or a branch with none) — the exact session shape
	# #397 reports as silent. Fall back to a repo-wide scan instead of exiting clean here.
	repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || exit 0
	owner="${repo%%/*}"
	name="${repo##*/}"
	[[ -n "$owner" && -n "$name" ]] || exit 0
	session_id="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"

	_repo_wide_scan "$owner" "$name" "$session_id" || exit 0
	[ -n "$REPORT_NUMBER" ] || exit 0

	_emit_verdict "$REPORT_NUMBER" "[repo-wide scan, no PR for this branch/HEAD] "
	exit $?
}

main "$@"
