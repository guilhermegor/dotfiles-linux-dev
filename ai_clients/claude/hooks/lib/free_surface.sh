#!/bin/bash
# Shared free-surface gate (dotfiles-dev#340): ONE implementation of "which open issues are
# safe to dispatch right now", mirroring hooks/lib/review_thread_gate.sh — skill-invoked shared
# logic that is not itself a hook, generic across repos (owner/repo arguments, nothing
# hardcoded), sourced by both the SubagentStop sweep and s:dev-loop step 6 instead of either one
# re-deriving the computation by hand.
#
# Measured on blueprintx, 2026-09-04: a directory-level "concentration" summary reported 9 of 11
# candidate issues as colliding; the exact recount showed a directory holding 6 of 200 files was
# 97% free. An aggregate over a per-item constraint always overestimates it — same family as the
# rtk-proxy `(empty)` collapse. So every comparison here is exact-path, file by file, never a
# directory prefix.
#
# Contract:
#   gate_free_surface OWNER REPO
#     Sets three globals (never partial — a failure leaves all three empty AND returns 1):
#       FREE_STATUS           = ok | unknown
#       FREE_HELD_PATHS       = newline-separated exact paths held by an open PR, or by a
#                               pushed branch with no open PR yet (union, deduped, sorted)
#       FREE_CLAIMED_ISSUES   = newline-separated issue numbers already claimed via
#                               `closingIssuesReferences`, across `is:pr` WITHOUT `is:open` —
#                               open AND merged, so a merged PR that forgot its `Closes #N`
#                               is still visible (dropping `is:open` is the whole point)
#       FREE_UNCLAIMED_ISSUES = newline-separated open issue numbers not in FREE_CLAIMED_ISSUES
#     Returns 1 and sets FREE_STATUS=unknown on any API failure. ⚠️ Never returns 0 with an
#     empty FREE_HELD_PATHS on a failure — a guard that fails open here reads as "everything is
#     free" and dispatches colliding agents.
#
#     ⚠️ dotfiles-dev#501: FREE_HELD_PATHS is the OPEN-PR union — an open PR is a frozen branch
#     awaiting review, not a live writer. It answers the claimed-issue question
#     (FREE_UNCLAIMED_ISSUES) and, read alongside free_classify_files below, a merge-risk
#     annotation worth a note in a dispatched agent's brief. It is NEVER the dispatch-collision
#     definition — that was the specific bug this issue exists to fix (7 of 10 dispatch
#     candidates excluded for overlapping frozen, in-review branches with no live writer on
#     them). The collision definition is `gate_live_agent_surface` below.
#
#   free_classify_files FILE...
#     Pure, no network — classifies a candidate file list against the FREE_HELD_PATHS already
#     set by a prior gate_free_surface call. Fails closed on FREE_STATUS != ok (prints UNKNOWN,
#     returns 1) instead of trusting FREE_HELD_PATHS being unset or empty — the two look
#     identical to a plain emptiness check, but only one of them means "really nothing is held".
#     Otherwise prints one of:
#       free                              — no candidate file is held
#       held:<colliding paths>            — every candidate file is held
#       would-need-a-held-file:<paths>    — some but not all candidate files are held (usually
#                                           one trivial line; dispatch it anyway per s:dev-loop)
#     Collapsing this third state into "held" is the specific failure this exists to avoid.
#     ⚠️ This verdict is the open-PR merge-risk annotation (see FREE_HELD_PATHS above) — never
#     read it as the dispatch-collision verdict. Use live_agent_classify_files for that.
#
#   gate_live_agent_surface CWD
#     dotfiles-dev#501's answer to "what is a dispatch collision": two LIVE agents writing the
#     same file right now, never a candidate vs. a frozen open PR (dotfiles-dev#433). Sets:
#       LIVE_AGENT_STATUS = ok | unknown
#       LIVE_AGENT_PATHS  = newline-separated exact paths any OTHER worktree of this checkout
#                           is touching right now — its branch's committed diff against the
#                           default branch, UNION its current uncommitted/untracked working-tree
#                           state (a fresh worktree with no commits yet is still live).
#     Local-only (no `gh` call) — a worktree IS the live-agent signal, same notion
#     `hooks/lib/worktree_fanout.sh` walks for session_start_context.sh/quota_gap_rescue.sh, and
#     the same notion `hooks/lib/dispatch_plan.py`'s `live_agent_held_paths()` already enforces
#     via `round_dispatch_guard.sh` (dotfiles-dev#433/#476) — this is the shared, testable form
#     of that same recipe for any caller working in bash (dev-loop.md's manual step 6 included),
#     not a fourth, independently-drifting liveness heuristic. It deliberately does NOT reuse
#     `worktree_fanout.sh`'s `classify_worktree_diff` staleness filter: that question ("should a
#     human resume this worktree?") is not this one ("is a file being written right now?") — a
#     worktree mid-revert is still a live writer for collision purposes even though it is not
#     worth resuming. Returns 1 and sets LIVE_AGENT_STATUS=unknown on any read failure — never
#     returns 0 with an empty LIVE_AGENT_PATHS on a failure, same fail-closed contract as above.
#
#   live_agent_classify_files FILE...
#     Same free/held/would-need-a-held-file trichotomy as free_classify_files, against
#     LIVE_AGENT_STATUS/LIVE_AGENT_PATHS instead — this is the verdict that actually blocks
#     dispatch. `held` means do not dispatch; `would-need-a-held-file` still dispatches (the
#     house pattern: land the one trivial overlapping line as its own follow-up commit).
#
# Deliberately out of scope (judgment, not data — see the issue): deciding WHICH free issue to
# dispatch, writing the brief, and supplying the candidate file list an issue's solution would
# touch (that needs reading the issue). This gate only does the exact-path set math underneath
# those decisions.
set -u

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	echo "free_surface.sh is meant to be sourced, not executed." >&2
	exit 1
fi

# _free_held_paths OWNER REPO
# Exact paths from every open PR, unioned with exact paths on any pushed branch that has no
# open PR (the "running agent, no PR yet" case) — compared via the GitHub compare API so no
# local clone of OWNER/REPO is required.
# ponytail: branches/PR lists are not paginated past gh's defaults beyond what's requested below;
# add --paginate to the `branches` call too if a repo ever exceeds one page (it already has it).
_free_held_paths() {
	local owner="$1" repo="$2"
	local slug="$owner/$repo"
	local db prs_json pr_numbers pr_heads paths n f branches b diff

	db="$(gh api "repos/$slug" --jq '.default_branch' 2>/dev/null)" || return 1
	[ -n "$db" ] || return 1

	prs_json="$(gh pr list --repo "$slug" --state open --json number,headRefName --limit 200 2>/dev/null)" || return 1
	pr_numbers="$(printf '%s' "$prs_json" | jq -r '.[].number' 2>/dev/null)" || return 1
	pr_heads="$(printf '%s' "$prs_json" | jq -r '.[].headRefName' 2>/dev/null)" || return 1

	paths=""
	while read -r n; do
		[ -n "$n" ] || continue
		f="$(gh pr view "$n" --repo "$slug" --json files --jq '.files[].path' 2>/dev/null)" || return 1
		paths="$(printf '%s\n%s' "$paths" "$f")"
	done <<<"$pr_numbers"

	branches="$(gh api "repos/$slug/branches" --paginate --jq '.[].name' 2>/dev/null)" || return 1
	while read -r b; do
		[ -n "$b" ] || continue
		[ "$b" = "$db" ] && continue
		printf '%s\n' "$pr_heads" | grep -qxF "$b" && continue
		# A branch with NO MERGE BASE (an orphan like `gh-pages`) makes compare 404.
		# That is not a read failure and must not fail the gate closed: such a branch
		# shares no history with the default branch, so it holds no paths against it.
		# Aborting here disabled DISPATCH entirely on any repo with a docs-site branch
		# — the sweep reported "free surface UNKNOWN" every round and no agent was ever
		# dispatched (dotfiles-dev, measured on blueprintx: 1 of 33 branches, 49 open
		# issues invisible). Skip ONLY on GitHub's own "No common ancestor" 404 — a
		# rate limit, auth or 5xx error must still fail closed, or the gate returns an
		# incomplete held set and reports ok.
		if ! diff="$(gh api "repos/$slug/compare/$db...$b" --jq '.files[]?.filename' 2>/dev/null)"; then
			[[ "$(gh api "repos/$slug/compare/$db...$b" 2>&1)" == *"No common ancestor"* ]] || return 1
			continue
		fi
		[ -n "$diff" ] && paths="$(printf '%s\n%s' "$paths" "$diff")"
	done <<<"$branches"

	printf '%s\n' "$paths" | sed '/^$/d' | sort -u
}

# _free_claimed_issues SLUG
# Issue numbers already claimed by ANY PR (open or merged) via closingIssuesReferences.
# ⚠️ `is:pr` WITHOUT `is:open` on purpose — a merged PR that forgot `Closes #N` is invisible
# under `is:open`. Disqualifies the branch-name `-<issue>` heuristic entirely (it missed a PR
# open four days closing the same issue an agent was dispatched for).
_free_claimed_issues() {
	local slug="$1" cursor="" has_next="true" claimed="" after query result page
	while [ "$has_next" = "true" ]; do
		after=""
		[ -n "$cursor" ] && after=",after:\"$cursor\""
		query="{search(query:\"repo:$slug is:pr\",type:ISSUE,first:100$after){pageInfo{hasNextPage endCursor} nodes{... on PullRequest{closingIssuesReferences(first:10){nodes{number}}}}}}"
		result="$(gh api graphql -f query="$query" 2>/dev/null)" || return 1
		printf '%s' "$result" | jq -e '.errors' >/dev/null 2>&1 && return 1
		page="$(printf '%s' "$result" | jq -r '.data.search.nodes[]?.closingIssuesReferences.nodes[]?.number' 2>/dev/null)"
		[ -n "$page" ] && claimed="$(printf '%s\n%s' "$claimed" "$page")"
		has_next="$(printf '%s' "$result" | jq -r '.data.search.pageInfo.hasNextPage // "false"' 2>/dev/null)"
		cursor="$(printf '%s' "$result" | jq -r '.data.search.pageInfo.endCursor // empty' 2>/dev/null)"
	done
	printf '%s\n' "$claimed" | sed '/^$/d' | sort -un
}

gate_free_surface() {
	local owner="$1" repo="$2"
	local slug="$owner/$repo"
	FREE_STATUS="unknown"
	FREE_HELD_PATHS=""
	FREE_CLAIMED_ISSUES=""
	FREE_UNCLAIMED_ISSUES=""

	local held claimed issues
	held="$(_free_held_paths "$owner" "$repo")" || return 1
	claimed="$(_free_claimed_issues "$slug")" || return 1
	issues="$(gh issue list --repo "$slug" --state open --limit 500 --json number --jq '.[].number' 2>/dev/null)" || return 1

	local n unclaimed=""
	while read -r n; do
		[ -n "$n" ] || continue
		printf '%s\n' "$claimed" | grep -qxF "$n" && continue
		unclaimed="$(printf '%s\n%s' "$unclaimed" "$n")"
	done <<<"$issues"

	FREE_HELD_PATHS="$held"
	# shellcheck disable=SC2034 # read by callers after this returns, not within this file
	FREE_CLAIMED_ISSUES="$claimed"
	# shellcheck disable=SC2034 # read by callers after this returns, not within this file
	FREE_UNCLAIMED_ISSUES="$(printf '%s\n' "$unclaimed" | sed '/^$/d' | sort -un)"
	# shellcheck disable=SC2034 # read by callers after this returns, not within this file
	FREE_STATUS="ok"
	return 0
}

# _classify_files_against STATUS HELD_PATHS FILE...
# Pure exact-path set math shared by free_classify_files (open-PR surface) and
# live_agent_classify_files (live-agent surface, dotfiles-dev#501) — one implementation of the
# free/held/would-need-a-held-file trichotomy so the two callers can never independently drift
# on what each state means. Fails closed (prints UNKNOWN, returns 1) unless STATUS is "ok" —
# gating on that explicit sentinel, never on HELD_PATHS being non-empty, is what tells
# "unset/unprimed" apart from "primed with a legitimately empty held set" (a repo with zero
# open PRs/live agents, where every file really is free). Under `set -u`, an unprimed call used
# to hit an unbound-variable error inside the loop, fall through the untouched held_count=0, and
# print "free" for a fully held file list (dotfiles-dev#414) — the exact input that causes a
# duplicate PR. Exact-path membership only — never a prefix/substring test, which is the whole
# defect this gate exists to avoid.
_classify_files_against() {
	local status="$1" held="$2"
	shift 2
	if [ "$status" != "ok" ]; then
		echo "UNKNOWN"
		return 1
	fi

	local total=0 held_count=0 f collided=""
	for f in "$@"; do
		total=$((total + 1))
		if printf '%s\n' "$held" | grep -qxF "$f"; then
			held_count=$((held_count + 1))
			collided="$collided $f"
		fi
	done
	collided="${collided# }"
	if [ "$held_count" -eq 0 ]; then
		echo "free"
	elif [ "$held_count" -eq "$total" ]; then
		echo "held:$collided"
	else
		echo "would-need-a-held-file:$collided"
	fi
}

# free_classify_files FILE... — see _classify_files_against; classifies against the open-PR
# surface (FREE_STATUS/FREE_HELD_PATHS). Merge-risk annotation only — never the dispatch-
# collision verdict (dotfiles-dev#501). Signature unchanged for existing callers.
free_classify_files() {
	_classify_files_against "${FREE_STATUS:-}" "${FREE_HELD_PATHS:-}" "$@"
}

# live_agent_classify_files FILE... — see _classify_files_against; classifies against the
# live-agent surface (LIVE_AGENT_STATUS/LIVE_AGENT_PATHS, set by gate_live_agent_surface). This
# is the verdict that actually blocks dispatch (dotfiles-dev#501).
live_agent_classify_files() {
	_classify_files_against "${LIVE_AGENT_STATUS:-}" "${LIVE_AGENT_PATHS:-}" "$@"
}

# _live_agent_held_paths CWD DEFAULT_BRANCH
# Exact paths any OTHER worktree of CWD is touching right now: its branch's committed diff
# against DEFAULT_BRANCH, union its current uncommitted/untracked working-tree state. See the
# file header for why this does not reuse worktree_fanout.sh's staleness classifier. Fails
# closed (returns 1) on anything but the documented "no shared history yet" no-op case — an
# orphan branch that has never diverged from default is not a read failure, mirroring
# _free_held_paths's own "No common ancestor" tolerance above, just against local git's wording
# instead of the GitHub compare API's.
_live_agent_held_paths() {
	local cwd="$1" default="$2"
	local path="" branch="" line held="" out out_lc untracked self

	git -C "$cwd" worktree list --porcelain >/dev/null 2>&1 || return 1

	# The caller's OWN worktree is the one to skip, identified by PATH, never by branch name.
	# Skipping every worktree whose branch equals $default excluded the wrong set: invoked from a
	# linked worktree, it dropped the main checkout's uncommitted files from LIVE_AGENT_PATHS
	# entirely, so a file an agent was holding there classified `free` and could be dispatched
	# concurrently (dotfiles-dev#523 review). The header already says "any OTHER worktree" — this
	# is what that sentence claimed all along.
	self="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || return 1
	[ -n "$self" ] || return 1

	while IFS= read -r line; do
		case "$line" in
		"worktree "*)
			path="${line#worktree }"
			branch=""
			;;
		"branch "*)
			branch="${line#branch refs/heads/}"
			;;
		"")
			if [ -n "$path" ] && [ -d "$path" ] && [ -n "$branch" ] && [ "$path" != "$self" ]; then
				# Committed divergence only means something against a DIFFERENT branch; for a
				# second worktree sitting on $default the diff is empty by definition, so skip
				# the call rather than spend it. Its dirty state below still counts.
				if [ "$branch" != "$default" ]; then
					if out="$(git -C "$cwd" diff --name-only "$default...$branch" 2>&1)"; then
						[ -n "$out" ] && held="$(printf '%s\n%s' "$held" "$out")"
					else
						out_lc="$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')"
						case "$out_lc" in
						*"no merge base"* | *"unrelated histories"* | *"unknown revision"* | *"bad revision"*) : ;;
						*) return 1 ;;
						esac
					fi
				fi
				# ⚠️ These two MUST fail closed, and used to fail open. Discarding their exit
				# status made an unreadable worktree indistinguishable from a clean one: the
				# empty result added nothing, the gate still returned `ok`, and a file another
				# agent was holding classified `free` — a permission error or a transient read
				# failure silently licensed a second agent onto it (dotfiles-dev#523 review).
				# The header's "fails closed on anything but the no-shared-history case" was
				# already the stated contract; these lines were the exception nobody declared.
				# Status is checked WITHOUT folding stderr into the value: a git warning on a
				# successful read would otherwise be parsed as a pathname.
				out="$(git -C "$path" diff HEAD --name-only 2>/dev/null)" || return 1
				[ -n "$out" ] && held="$(printf '%s\n%s' "$held" "$out")"
				untracked="$(git -C "$path" ls-files --others --exclude-standard 2>/dev/null)" || return 1
				[ -n "$untracked" ] && held="$(printf '%s\n%s' "$held" "$untracked")"
			fi
			path=""
			branch=""
			;;
		esac
	done < <(git -C "$cwd" worktree list --porcelain 2>/dev/null; printf '\n')

	printf '%s\n' "$held" | sed '/^$/d' | sort -u
}

# gate_live_agent_surface CWD — see the file header contract. No `gh` call: local git only.
gate_live_agent_surface() {
	local cwd="$1"
	LIVE_AGENT_STATUS="unknown"
	LIVE_AGENT_PATHS=""

	[ -d "$cwd" ] || return 1
	git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1

	local default_branch held cand
	# `|| true` is load-bearing, not defensive noise: `symbolic-ref --quiet` EXITS NON-ZERO when
	# the ref is absent, so under `set -e` this assignment aborted the whole function one line
	# before the guard below ever ran. That is the actual mechanism behind the #523 review's
	# "always returns unknown" — the fallback added below is unreachable without this.
	default_branch="$(git -C "$cwd" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
	default_branch="${default_branch#origin/}"
	# A missing local refs/remotes/origin/HEAD is NOT a read failure — it is simply absent in any
	# clone made with `git remote add`, and in clones whose remote never advertised a HEAD.
	# Treating it as unreadable returned `unknown` and blocked dispatch forever in a perfectly
	# healthy repository (dotfiles-dev#523 review). Fall back to whichever conventional remote
	# branch actually exists; still fail closed when none does, because then the default genuinely
	# cannot be determined and a wrong guess would mis-scope every diff below.
	if [ -z "$default_branch" ]; then
		for cand in main master; do
			if git -C "$cwd" rev-parse --verify --quiet "refs/remotes/origin/$cand" >/dev/null 2>&1; then
				default_branch="$cand"
				break
			fi
		done
	fi
	[ -n "$default_branch" ] || return 1

	held="$(_live_agent_held_paths "$cwd" "$default_branch")" || return 1

	LIVE_AGENT_PATHS="$held"
	# shellcheck disable=SC2034 # read by callers after this returns, not within this file
	LIVE_AGENT_STATUS="ok"
	return 0
}
