#!/bin/bash
# SubagentStop hook — board sweep + free dispatch surface (dotfiles-dev#167).
#
# The problem this closes: a rule that must fire EVERY cycle cannot live in a
# document. Measured in one blueprintx session — three corrections, two
# lessons written, zero behaviour change, because "did you sweep the board /
# dispatch more agents?" depended on someone remembering to ask. This hook
# makes the sweep fire deterministically every time a subagent finishes,
# instead of on request.
#
# Generalised from the blueprintx-specific reference sweep (measured there
# 2026-08-29, see its own header comments for the two defects it survived):
# the repo is resolved from the session cwd + `git remote`, never hardcoded,
# and nothing here re-derives the review-thread gate's verdict — it calls the
# shared implementation in lib/review_thread_gate.sh (the same one
# open_review_threads_nudge.sh uses), because a re-derived copy inherited
# that gate's own bug plus a new one of its own when blueprintx tried it.
#
# ⚠️ Two traps carried forward from the reference sweep, both measured:
#   1. NEVER judge git state through the rtk proxy. `rtk proxy git status
#      --porcelain` on a clean tree returns the literal string "ok", which
#      `wc -l` counts as 1 line — reporting a clean branch as dirty. Every
#      git call below uses $GIT (/usr/bin/git) directly.
#   2. NEVER re-derive the review-thread gate's verdict; CALL it, and match
#      the sentence that discriminates when classifying its output, never a
#      bare noun (a first draft matched the word "thread" and hit it inside
#      a sentence that meant the opposite).
#
# Query, not judgement (the reference sweep's own framing): every section
# below only prints states that need action, and the final line is always
# explicit — "unclaimed by a PR (N): ..." or "dispatch: free surface empty" —
# because silence is indistinguishable from the check having been skipped.
# ⚠️ Item [6]'s label is NOT the dispatch plan (dotfiles-dev#535). It answers
# gate_free_surface's question ("not claimed by an open/merged PR"), which is
# strictly weaker than dispatch_plan.py's ("dispatchable": also excludes an
# UNDECLARED surface, a live-agent collision, and a bare-#N PR mention).
# Measured 2026-09-27: this line printed "dispatch these 13: ..." for the
# exact 13 issues dispatch_plan.py excluded the same round — one enumeration
# read as fact would have sent 13 agents onto undeclared surfaces. See
# format_free_surface_report() below for the wording contract this pins.
#
# Emits its report as SubagentStop `additionalContext` JSON so the parent
# session sees it without anyone asking. Never blocks: this hook cannot spawn
# agents, so blocking the stop would accomplish nothing — it only informs.
#
# ⚠️ Fires ONLY for dev/implementation agent types (dotfiles-dev#508). This hook used to run
# unconditionally for every stopping subagent — a reviewer, `Explore`, `Plan`, or a skill fork
# like `code-review` received the board sweep as `additionalContext`, spent its turn reacting to
# dev-loop chatter, and handed back that instead of its actual result. Measured 2026-09-25: a
# forked `code-review` subagent reviewing ditto#681 received 45 sweep injections and its final
# report was a refusal to do dev-loop orchestration — the real review buried mid-transcript.
# `sweep_agent_allowed()` gates on the payload's `agent_type` field — confirmed against the
# installed Claude Code build (v2.1.283) by decompiling its bundled schema: the SubagentStop
# payload is `{hook_event_name, stop_hook_active, agent_id, agent_transcript_path, agent_type,
# ...}` — `agent_type`, never `subagent_type` (that name belongs to the Agent TOOL CALL's own
# input parameter in the DISPATCHING session's transcript, a different field on a different
# object entirely). An ALLOWLIST, not a denylist, per the same rule the free-surface gate above
# already follows: a newly added read-only agent type is silent by default, never opted in by
# omission. Absent/empty `agent_type` fails OPEN (fires) rather than silent — the manual
# invocation `s:dev-loop` documents (`subagent_stop_sweep.sh <<<'{}'`) carries no agent_type at
# all, and that contract must keep working outside a real SubagentStop trigger.
set -uo pipefail

GIT=/usr/bin/git
command -v gh >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/review_thread_gate.sh
source "$HOOK_DIR/lib/review_thread_gate.sh"
# shellcheck source=lib/free_surface.sh
source "$HOOK_DIR/lib/free_surface.sh"
# shellcheck source=lib/kanban_reconcile.sh
source "$HOOK_DIR/lib/kanban_reconcile.sh"
# shellcheck source=lib/dispatch_claims.sh
source "$HOOK_DIR/lib/dispatch_claims.sh"
# shellcheck source=lib/kanban_reconcile_done.sh
source "$HOOK_DIR/lib/kanban_reconcile_done.sh"
# shellcheck source=lib/gh_budget.sh
source "$HOOK_DIR/lib/gh_budget.sh"
# shellcheck source=lib/roadmap_unblock.sh
source "$HOOK_DIR/lib/roadmap_unblock.sh"

emit() {
	# $1 = plain-text report body. Wraps it as SubagentStop additionalContext.
	jq -n --arg ctx "$1" '{hookSpecificOutput: {hookEventName: "SubagentStop", additionalContext: $ctx}}'
}

# Dev/implementation agent types s:dev-loop dispatches for issue work — the only ones this
# sweep is useful to. See this file's header comment for the field name and why absent/empty
# fails open instead of silent (dotfiles-dev#508).
SWEEP_AGENT_ALLOWLIST=(general-purpose claude)

# sweep_agent_type PAYLOAD
# Reads .agent_type off the raw SubagentStop JSON. Empty when absent or unparseable.
sweep_agent_type() {
	local payload="$1"
	[ -n "$payload" ] || return 0
	printf '%s' "$payload" | jq -r '.agent_type // empty' 2>/dev/null
}

# sweep_agent_allowed AGENT_TYPE
# Empty/absent (no signal at all — a manual invocation, or a build that never sends the field)
# returns true: same "fail open on missing data" rule every other gate in this file follows.
# A named type must appear in SWEEP_AGENT_ALLOWLIST — anything else (a reviewer, Explore, Plan,
# or a "fork" running a read-only skill, the ditto#681 case that opened this issue) is refused.
sweep_agent_allowed() {
	local t="$1" a
	[ -z "$t" ] && return 0
	for a in "${SWEEP_AGENT_ALLOWLIST[@]}"; do
		[ "$t" = "$a" ] && return 0
	done
	return 1
}

resolve_cwd() {
	local payload="$1" cwd
	cwd=""
	if [ -n "$payload" ]; then
		cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
	fi
	if [ -n "$cwd" ]; then
		printf '%s\n' "$cwd"
	else
		printf '%s\n' "${CLAUDE_PROJECT_DIR:-$PWD}"
	fi
}

default_branch() {
	# Reads the remote's HEAD symref directly — never depends on whether a
	# local `fetch` already ran. Getting this wrong once (measured while
	# testing this hook against a never-fetched clone) turned into a false
	# positive: an empty $db matched nothing in the exclusion check below,
	# so the repo's OWN default branch was flagged as "pushed without PR".
	local cwd="$1" db
	db="$($GIT -C "$cwd" ls-remote --symref origin HEAD 2>/dev/null | awk '/^ref:/{print $2}')"
	db="${db#refs/heads/}"
	if [ -n "$db" ]; then
		printf '%s\n' "$db"
		return
	fi
	# Network unreachable / no origin: fall back to a local guess.
	for db in main master; do
		if $GIT -C "$cwd" show-ref --verify --quiet "refs/heads/$db"; then
			printf '%s\n' "$db"
			return
		fi
	done
	printf '%s\n' ""
}

repo_slug() {
	local cwd="$1" url
	url="$($GIT -C "$cwd" remote get-url origin 2>/dev/null)" || return 1
	[ -n "$url" ] || return 1
	url="${url%.git}"
	case "$url" in
	*github.com[:/]*)
		printf '%s\n' "${url#*github.com}" | sed 's#^[:/]##'
		;;
	*)
		return 1
		;;
	esac
}

sweep_worktrees() {
	local cwd="$1"
	local wt b st un any=0 main_wt
	# Every linked worktree, not just `worktrees/agent-*`. The old filter matched the name the
	# harness happens to pick, so a worktree created by hand (or by a resumed agent, named
	# `worktrees/issue-356`) held two uncommitted files while this step printed "none" — the
	# exact silence the step exists to break (dotfiles-dev#162 is about residue, not naming).
	# The main checkout is still skipped: the operator's own dirty tree is not agent residue.
	main_wt="$($GIT -C "$cwd" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
	while read -r wt; do
		[ -n "$wt" ] || continue
		[ "$wt" = "$main_wt" ] && continue
		b="$($GIT -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)"
		st="$($GIT -C "$wt" status --porcelain 2>/dev/null | wc -l)"
		# Measure "unpushed" against the branch's OWN upstream, never `origin/$b`.
		# On a DETACHED HEAD, `rev-parse --abbrev-ref HEAD` prints the literal string
		# "HEAD", so `origin/$b` silently becomes `origin/HEAD` — a symref to the default
		# branch — and the count turns into "commits ahead of main". Every detached
		# worktree then reports phantom unpushed work whose only cure is deleting it;
		# measured twice in two rounds on blueprintx, 3 scratch worktrees reported
		# 8/3/4 "unpushed" commits that were all already on origin. A sweep that cries
		# wolf is worse than none — the operator learns to skip it, and then it catches
		# nothing. lib/worktree_fanout.sh already got this right; this is that same form.
		if $GIT -C "$wt" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
			un="$($GIT -C "$wt" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 0)"
			[ -n "$un" ] || un=0
		else
			un=no-remote
		fi
		[ "$b" = "HEAD" ] && b="detached@$($GIT -C "$wt" rev-parse --short HEAD 2>/dev/null)"
		if [ "$st" != "0" ]; then
			echo "    - $b: $st uncommitted"
			any=1
		fi
		if [ "$un" != "0" ] && [ "$un" != "no-remote" ]; then
			echo "    - $b: $un unpushed"
			any=1
		fi
	done < <($GIT -C "$cwd" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')
	[ "$any" = "0" ] && echo "    none"
}

sweep_review_gate() {
	local owner="$1" name="$2" repo="$3" roster_file="$4" prs
	if ! prs="$(gh api "repos/$repo/pulls?state=open" --jq '.[].number' 2>/dev/null)"; then
		echo "    UNKNOWN — could not list open PRs (gh API failure), not 'none'"
		return
	fi
	if [ -z "$prs" ]; then
		echo "    no open PRs"
		return
	fi
	local n
	while read -r n; do
		[ -n "$n" ] || continue
		# dotfiles-dev#559: gate_pr_thread_state() latches on its OWN terminal GitHub API budget
		# refusal, but a latch written for PR N does nothing to stop PR N+1's identical call a
		# moment later unless this loop checks it too — the exact "repeated fan-out attempts" the
		# finding named. Skip every remaining PR this sweep once the budget is latched.
		if gh_budget_latch_active; then
			echo "    UNKNOWN — GitHub API budget latched, skipping remaining PRs this sweep"
			break
		fi
		gate_pr_thread_state "$owner" "$name" "$n" "$roster_file"
		# ⚠️ The `*)` arm is load-bearing, not defensive padding. This `case` had no catch-all,
		# so a status the shared gate gained later printed NOTHING and the PR disappeared from
		# the board report entirely — a silent drop, indistinguishable from "no open PRs".
		# open_review_threads_nudge.sh predicted this failure in prose before it happened; the
		# arm below is what makes the next added status loud instead of invisible.
		case "$GATE_STATUS" in
		clean) echo "    #$n clean" ;;
		problems) echo "    #$n NEEDS REPLY/RESOLVE: $(printf '%s' "$GATE_DETAIL" | tr '\n' ';')" ;;
		running) echo "    #$n reviewer checks running — snapshot, not a verdict" ;;
		unreviewed) echo "    #$n NO REVIEWER HAS REPORTED on this head" ;;
		unreadable) echo "    #$n unreadable: $GATE_DETAIL" ;;
		*) echo "    #$n UNKNOWN gate status '$GATE_STATUS' — treat as unverified: $GATE_DETAIL" ;;
		esac
	done <<<"$prs"
}

# A pushed `git stash` snapshot has a tip commit titled by `git stash` itself
# (`WIP on <branch>: ...`, `index on <branch>: ...`, or, for `-u`, `untracked
# files on <branch>: ...`) — never a title a person or an agent would write.
# Matching on that title is what tells a real branch missing a PR apart from
# a stash pushed under a branch name (dotfiles-dev#399).
is_stash_snapshot_title() {
	case "$1" in
	"WIP on "* | "index on "* | "untracked files on "*) return 0 ;;
	*) return 1 ;;
	esac
}

# Extra context for a stash snapshot so the loop can decide whether to ask
# about deleting it, without re-deriving the diff by hand: how far $db has
# moved since the snapshot's base, and the three-dot per-file +/- (a mostly-
# deleting file is a stale snapshot re-adding lines $db already removed).
stash_snapshot_diff_context() {
	local cwd="$1" db="$2" b="$3" base gained
	base="$($GIT -C "$cwd" merge-base "origin/$db" "origin/$b" 2>/dev/null)"
	if [ -z "$base" ]; then
		echo "      no merge-base with $db — can't date this snapshot"
		return
	fi
	gained="$($GIT -C "$cwd" rev-list --count "$base..origin/$db" 2>/dev/null || echo 0)"
	echo "      $db gained $gained commit(s) since this snapshot's base"
	echo "      per-file +/- (three-dot diff vs $db):"
	$GIT -C "$cwd" diff --numstat "origin/$db...origin/$b" 2>/dev/null |
		while read -r add del path; do
			[ -n "$path" ] || continue
			echo "        $path: +$add/-$del"
		done
}

# Whether any open OR merged PR already touches the same files this snapshot
# touches — if so, opening a PR for the snapshot would bring back old content
# that is either already in flight or already landed.
#
# ⚠️ An API failure must read UNKNOWN, never "no open or merged PR touches
# these files" — the two gh calls below are checked for their own exit
# status (not just their captured text), because an empty result on success
# and an empty result on failure are otherwise indistinguishable, and the
# silently-empty reading is the wrong one to act on (CodeRabbit, PR #403).
stash_snapshot_pr_overlap() {
	local cwd="$1" repo="$2" db="$3" b="$4" files pr_nums n pr_files f hits=""
	files="$($GIT -C "$cwd" diff --name-only "origin/$db...origin/$b" 2>/dev/null)"
	if [ -z "$files" ]; then
		echo "      touches no files vs $db"
		return
	fi
	if ! pr_nums="$(gh api "repos/$repo/pulls?state=all" --paginate \
		--jq '.[] | select(.merged_at != null or .state == "open") | .number' 2>/dev/null)"; then
		echo "      UNKNOWN — could not list open/merged PRs (gh API failure)"
		return
	fi
	while read -r n; do
		[ -n "$n" ] || continue
		if ! pr_files="$(gh api "repos/$repo/pulls/$n/files" --paginate --jq '.[].filename' 2>/dev/null)"; then
			echo "      UNKNOWN — could not list files for PR #$n (gh API failure)"
			return
		fi
		while read -r f; do
			[ -n "$f" ] || continue
			if printf '%s\n' "$files" | grep -qxF "$f"; then
				hits="$hits #$n"
				break
			fi
		done <<<"$pr_files"
	done <<<"$pr_nums"
	hits="${hits# }"
	if [ -n "$hits" ]; then
		echo "      same files touched by: $hits"
	else
		echo "      no open or merged PR touches these files"
	fi
}

sweep_orphan_branches() {
	local cwd="$1" repo="$2" owner="$3" db="$4" b heads any=0 title
	# ONE call for every PR head, never one per branch: the per-branch form
	# cost an API call per remote branch (33 on blueprintx) and, on a 403,
	# rendered EVERY branch as missing a PR (see s:dev-loop, GitHub API budget).
	# `head.label` ("<owner>:<branch>"), never `head.ref`: a fork PR can carry
	# the same branch name as ours, and matching the bare name would read that
	# fork's PR as covering OUR branch, hiding a real orphan. The per-branch
	# query this replaces was owner-scoped (`?head=$owner:$b`) for the same
	# reason, so matching "$owner:$b" below keeps that property.
	if ! heads="$(gh api "repos/$repo/pulls?state=all&per_page=100" --paginate --jq '.[].head.label' 2>/dev/null)"; then
		echo "    UNKNOWN — could not list PR head refs (gh API failure), not 'no PR'"
		return
	fi
	while read -r b; do
		[ -n "$b" ] || continue
		case "$b" in "$db" | gh-pages) continue ;; esac
		if ! printf '%s\n' "$heads" | grep -qxF "$owner:$b"; then
			title="$($GIT -C "$cwd" log -1 --format=%s "origin/$b" 2>/dev/null)"
			if is_stash_snapshot_title "$title"; then
				echo "    - $b: STASH SNAPSHOT (\"$title\"), not a branch missing a PR"
				stash_snapshot_diff_context "$cwd" "$db" "$b"
				stash_snapshot_pr_overlap "$cwd" "$repo" "$db" "$b"
			else
				echo "    - $b"
			fi
			any=1
		fi
	done < <($GIT -C "$cwd" ls-remote --heads origin 2>/dev/null | sed 's#.*refs/heads/##')
	[ "$any" = "0" ] && echo "    none"
}

# ⚠️ Both functions below capture the listing call into a variable and check ITS OWN exit status
# before iterating — never `done < <(gh api ... 2>/dev/null)` directly. Piping straight into the
# loop via process substitution discards the command's exit status, so a 403 prints its RAW
# response body as fake PR numbers instead of failing: `gh api --jq` exits non-zero on an HTTP
# error WITHOUT ever running the filter, but still writes the unfiltered JSON body to stdout —
# `{`, `  "message": "API rate limit exceeded...",`, `}` — and each of those lines becomes a
# bogus "- #{" / "- #\"message\": ..." finding (dotfiles-dev#512, found via the exact #445 latch
# work above). Same fix shape sweep_review_gate() and sweep_orphan_branches() already use.
sweep_no_automerge() {
	local repo="$1" prs n any=0
	if ! prs="$(gh api "repos/$repo/pulls?state=open" --jq '.[] | select(.auto_merge == null) | .number' 2>/dev/null)"; then
		echo "    UNKNOWN — could not list open PRs (gh API failure), not 'none'"
		return
	fi
	while read -r n; do
		[ -n "$n" ] || continue
		echo "    - #$n"
		any=1
	done <<<"$prs"
	[ "$any" = "0" ] && echo "    none"
}

sweep_behind_base() {
	local cwd="$1" repo="$2" db="$3" prs n headref behind any=0
	if ! prs="$(gh api "repos/$repo/pulls?state=open" --jq '.[].number' 2>/dev/null)"; then
		echo "    UNKNOWN — could not list open PRs (gh API failure), not 'none'"
		return
	fi
	while read -r n; do
		[ -n "$n" ] || continue
		headref="$(gh api "repos/$repo/pulls/$n" --jq .head.ref 2>/dev/null)"
		[ -n "$headref" ] || continue
		behind="$($GIT -C "$cwd" rev-list --count "origin/$headref..origin/$db" 2>/dev/null || echo 0)"
		if [ -n "$behind" ] && [ "$behind" != "0" ]; then
			echo "    - #$n: $behind commit(s) behind $db"
			any=1
		fi
	done <<<"$prs"
	[ "$any" = "0" ] && echo "    none"
}

# Free dispatch surface: calls the shared gate_free_surface (lib/free_surface.sh) instead of
# re-deriving it — the branch-name `-<issue>` heuristic this used to run is disqualified by
# measurement (it missed a PR open four days closing the same issue an agent was dispatched
# for; dotfiles-dev#340). Prints "#N #M ..." (space-separated), "UNKNOWN" on an API failure
# (never an empty string — empty is indistinguishable from "nothing left to dispatch"), or
# nothing when every open issue is already claimed.
#
# ⚠️ This is "unclaimed by a PR", never "dispatchable" — see format_free_surface_report()
# below, which is the ONLY place that turns this raw list into report prose, and states the
# distinction in the label every time (dotfiles-dev#535).
free_dispatch_surface() {
	local repo="$1" owner="${1%%/*}" name="${1##*/}"
	if ! gate_free_surface "$owner" "$name"; then
		echo "UNKNOWN"
		return 1
	fi
	local n free_list=()
	while read -r n; do
		[ -n "$n" ] || continue
		free_list+=("#$n")
	done <<<"$FREE_UNCLAIMED_ISSUES"
	[ "${#free_list[@]}" -gt 0 ] && printf '%s\n' "${free_list[*]}"
}

# format_free_surface_report FREE
# Renders item [6]'s report line from free_dispatch_surface's raw output ("$FREE" is its
# stdout: "UNKNOWN", empty, or "#N #M ..."). Named explicitly as "unclaimed by a PR" — never
# "dispatch"/"dispatchable" — because that word is dispatch_plan.py's own, STRICTER verdict
# (it also excludes an UNDECLARED surface, a live-agent collision, and a bare-#N PR mention;
# see dispatch_plan.py's module docstring). Conflating the two is the dotfiles-dev#535 defect:
# this exact line used to read "dispatch these 13: ..." for the 13 issues dispatch_plan.py
# excluded the same round. Pinned by tests/subagent_stop_sweep.bats so the two labels cannot
# drift back together.
format_free_surface_report() {
	local free="$1"
	if [ "$free" = "UNKNOWN" ]; then
		echo "dispatch: UNKNOWN — free surface unreadable (gh API failure), not empty"
	elif [ -n "$free" ]; then
		# shellcheck disable=SC2086 # word-splitting is intentional: count the tokens
		set -- $free
		echo "unclaimed by a PR ($#, NOT dispatch_plan.py's dispatchable set): $free"
	else
		echo "dispatch: free surface empty"
	fi
}

# gh_budget_gate REPO
# ONE cheap REST call standing in for "can the sweep reach the API at all right now" — never a
# re-run of the whole fan-out just to find out. Returns 0 to proceed. Returns 1 with
# BUDGET_GATE_REASON set (shellcheck disable=SC2034 — read by main() after this returns) when
# any of: an earlier 403 latch is still fresh, THIS probe just came back 403/429, or the sweep's
# OTHER budget (GraphQL) is already exhausted per gh_budget_quota_exhausted even though the REST
# probe itself succeeded — dotfiles-dev#511 review finding: `sweep_review_gate()`'s fan-out is
# GraphQL (via review_thread_gate.sh), a REST-only probe cannot see that budget going to zero, so
# a purely-GraphQL exhaustion used to sail through this gate and fail one PR at a time with no
# latch ever written — exactly the repeated fan-out #445 exists to stop.
# dotfiles-dev#445: 6 agents x a sweep per SubagentStop x ~6 gh calls each burned the whole
# hourly budget on sweeps that read UNKNOWN either way — these cheap calls replace finding that
# out the expensive way every time.
# A non-budget failure (bad repo, network blip) still returns 0: this gate only ever stops the
# sweep for a BUDGET reason, it is not a general health check.
# _gh_budget_latch_reason WHY
# Writes the latch with the measured TTL and builds BUDGET_GATE_REASON around WHY — appending an
# explicit "latch write FAILED" note when gh_budget_latch_write itself couldn't write the marker
# (dotfiles-dev#511 review: a swallowed write failure left the sweep silently unable to ever
# latch, indistinguishable from a healthy latch by anything reading BUDGET_GATE_REASON alone).
# Always returns 1 — every caller latches (or tries to) only on a path that already means "stop".
_gh_budget_latch_reason() {
	local why="$1"
	if gh_budget_latch_write "$(gh_budget_reset_ttl)"; then
		BUDGET_GATE_REASON="$why — latched until reset"
	else
		BUDGET_GATE_REASON="$why — latch write FAILED, next sweep will re-probe"
	fi
	return 1
}

gh_budget_gate() {
	local repo="$1" err rc
	BUDGET_GATE_REASON=""
	if gh_budget_latch_active; then
		BUDGET_GATE_REASON="403 latch active — GitHub API budget still exhausted"
		return 1
	fi
	if gh_budget_quota_exhausted; then
		_gh_budget_latch_reason "GitHub API quota (core or graphql) already exhausted per rate_limit"
		return 1
	fi
	err="$(mktemp)"
	gh api "repos/$repo" --jq '.id' >/dev/null 2>"$err"
	rc=$?
	if [ "$rc" -ne 0 ]; then
		gh_budget_classify "$(cat "$err" 2>/dev/null)"
		rm -f "$err"
		if gh_budget_is_terminal; then
			_gh_budget_latch_reason "GitHub API budget just returned 403/429"
			return 1
		fi
		return 0
	fi
	rm -f "$err"
	return 0
}

# sweep_roadmap_boards
# Prints reconcile_roadmap_boards' per-board report (one line per declared board, clean or not),
# or an UNKNOWN line when the sweep produced no report at all (dotfiles-dev#531).
sweep_roadmap_boards() {
	reconcile_roadmap_boards || true
	if [ -n "$RECONCILE_BOARDS_REPORT" ]; then
		printf '%s\n' "$RECONCILE_BOARDS_REPORT"
	else
		echo "roadmap boards: UNKNOWN — no per-board report produced, not 'nothing to unblock'"
	fi
}

main() {
	local payload cwd repo owner name db roster_file report agent_type
	if [ ! -t 0 ]; then payload="$(cat)"; else payload=""; fi

	# Gate on agent type FIRST, before any git/gh call — a silenced stop should cost nothing
	# beyond parsing the payload (dotfiles-dev#508).
	agent_type="$(sweep_agent_type "$payload")"
	sweep_agent_allowed "$agent_type" || exit 0

	cwd="$(resolve_cwd "$payload")"

	$GIT -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

	if ! repo="$(repo_slug "$cwd")"; then
		emit "sweep: no GitHub origin at $cwd — nothing to sweep.
dispatch: free surface empty"
		exit 0
	fi
	owner="${repo%%/*}"
	name="${repo##*/}"
	roster_file="$cwd/.review-bots.yaml"
	db="$(default_branch "$cwd")"
	$GIT -C "$cwd" fetch origin --quiet 2>/dev/null || true

	if ! gh_budget_gate "$repo"; then
		emit "── sweep $(date -u '+%H:%M UTC') — $repo ──
$BUDGET_GATE_REASON (dotfiles-dev#445) — skipping this sweep, no further gh calls.
dispatch: UNKNOWN — $BUDGET_GATE_REASON"
		exit 1
	fi

	report="$(
		echo "── sweep $(date -u '+%H:%M UTC') — $repo ──"
		echo "[1] worktree residue"
		sweep_worktrees "$cwd"
		echo "[2] review-thread gate (called, not re-derived)"
		sweep_review_gate "$owner" "$name" "$repo" "$roster_file"
		echo "[3] branch pushed without PR"
		sweep_orphan_branches "$cwd" "$repo" "$owner" "$db"
		echo "[4] PR without auto-merge armed"
		sweep_no_automerge "$repo"
		echo "[5] PR behind base ($db)"
		sweep_behind_base "$cwd" "$repo" "$db"
		echo "[6] PR-unclaimed issues (narrower than dispatch_plan.py — see its own [d]/[x])"
		free="$(free_dispatch_surface "$repo")"
		format_free_surface_report "$free"
		echo "[7] kanban reconcile (open PRs -> In review)"
		if reconcile_kanban "$owner" "$name"; then
			if [ -n "$RECONCILE_KANBAN_REPORT" ]; then
				printf '%s\n' "$RECONCILE_KANBAN_REPORT"
			else
				echo "no kanban cards changed"
			fi
		else
			echo "kanban reconcile: UNKNOWN — $RECONCILE_KANBAN_REPORT"
		fi
		echo "[8] roadmap boards (declared registry: ROADMAP_BOARDS in lib/roadmap_unblock.sh)"
		sweep_roadmap_boards
		echo "[9] kanban reconcile (closed issues -> Done, No Status -> placed)"
		if reconcile_kanban_done "$owner" "$name" "$cwd"; then
			if [ -n "$RECONCILE_DONE_REPORT" ]; then
				printf '%s\n' "$RECONCILE_DONE_REPORT"
			else
				echo "no kanban cards changed"
			fi
		else
			echo "kanban reconcile (Done/No Status): UNKNOWN — $RECONCILE_DONE_REPORT"
		fi
	)"

	emit "$report"
	exit 0
}

main "$@"
