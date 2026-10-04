#!/bin/bash
# Shared orphaned-issues gate (dotfiles-linux-dev#418): ONE implementation of "which open issues
# already shipped in a merged PR that forgot to declare it", mirroring free_surface.sh and
# roadmap_unblock.sh — skill-invoked shared logic that is not itself a hook, generic across
# repos (owner/repo arguments, nothing hardcoded), sourced by s:dev-loop step 2 (SWEEP) instead
# of re-deriving the computation by hand.
#
# The direction is the mirror image of free_surface.sh's `_free_claimed_issues`: that helper
# asks "given an issue about to be dispatched, does some PR already claim it?" (used to decide
# NOT to dispatch). This gate asks the other direction, proactively, over every open issue: "is
# there a merged PR whose title/branch/body already mentions this issue, without declaring it
# via closingIssuesReferences?" — the fully-decidable half of dotfiles-linux-dev#418's scope (a
# textual PR-mention with a missing link). The complementary signal named in #418 (the issue's
# declared file surface existing on the default branch, with no PR mention at all) is already
# s:intake-shipped's job (shipped_check.sh) once a specific issue is in hand; re-deriving that
# content-probe here for every open issue on every round would duplicate it, so this gate stays
# scoped to the PR-mention signal and s:dev-loop calls both.
#
# Measured (dotfiles-linux-dev#418): blueprintx#381's own PR (#467) had "381" in its branch name
# (`refactor/migrations-folder-alembic-parity-373-381`) and in its title, and still only closed
# 373 -- the orphan survived a human reading the title. blueprintx#355 shipped via PR #509 with
# closingIssuesReferences = []. Never trust the branch-name `-<issue>` suffix heuristic alone
# (dotfiles-dev's own step 6 already rejects it): a mention can sit anywhere in title/body too,
# so this gate scans all three fields.
#
# Contract:
#   gate_orphaned_issues OWNER REPO
#     Sets two globals (never partial -- a failure leaves both empty AND returns 1):
#       ORPHAN_STATUS = ok | unknown
#       ORPHAN_REPORT = newline-separated candidate lines, one per open issue with a merged PR
#                       mentioning it without closing it -- "#N may already be shipped by PR #M
#                       (mentions #N, closingIssuesReferences=<list|none>) -- verify on <default
#                       branch>". Empty when no candidate is found (still ORPHAN_STATUS=ok).
#     Returns 1 and sets ORPHAN_STATUS=unknown on any gh/jq read failure. ⚠️ Never returns 0 with
#     a stale/partial ORPHAN_REPORT on a failure -- a report is a *candidate*, never a verdict
#     (see #418's own scope: report, never auto-close), so a caller that treats a failure as "no
#     candidates" would silently stop re-offering issues that already merged.
#
#   gate_orphaned_surface OWNER REPO  (dotfiles-linux-dev#419)
#     The complementary signal named-but-deferred in the #418 header above: an issue with
#     NO PR mention at all (blueprintx#438's shape -- both seams already existed on `main`,
#     and nobody ever opened a PR that named the issue). Reuses free_surface.sh's
#     FREE_UNCLAIMED_ISSUES (open issues no PR, open or merged, claims via
#     closingIssuesReferences -- never re-derived here) and content-tests each one's
#     declared ` ```surface ` block (the format s:intake-plan already parses) against the
#     default branch. Sets two globals (never partial):
#       ORPHAN_SURFACE_STATUS = ok | unknown
#       ORPHAN_SURFACE_REPORT = newline-separated candidate lines -- fully or partially
#                               present surface paths on the default branch, with no PR
#                               claiming the issue. An issue with no ` ```surface ` block is
#                               silently skipped (not a candidate for this cheap pass, not a
#                               failure) -- s:intake-plan already reports a missing/unparsable
#                               block back to the issue for its own purposes.
#     Returns 1 and sets ORPHAN_SURFACE_STATUS=unknown on any gate/gh/git read failure.
set -u

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	echo "orphaned_issues.sh is meant to be sourced, not executed." >&2
	exit 1
fi

source "$(dirname "${BASH_SOURCE[0]}")/free_surface.sh"

# Two ceilings this gate cannot page past. Both are DETECTION thresholds, not request
# sizes: crossing either means the real set is larger than can be enumerated, and the
# only honest answer is ORPHAN_STATUS=unknown. Raising one without also moving the
# detection re-opens the silent-truncation hole it closes.
ORPHAN_SEARCH_CEILING="${ORPHAN_SEARCH_CEILING:-1000}"      # GraphQL `search` hard cap
ORPHAN_OPEN_ISSUE_CEILING="${ORPHAN_OPEN_ISSUE_CEILING:-500}" # `gh issue list --limit`

# _orphan_merged_pr_mentions SLUG
# Prints "issue_number<TAB>pr_number<TAB>closing_list" one line per (mentioned issue, PR) pair
# where a MERGED pull request's title, body, or branch name mentions the issue number while its
# own closingIssuesReferences omits it. `is:merged` (not `is:open`) on purpose -- same reasoning
# as free_surface.sh's `_free_claimed_issues`: a merged PR that forgot the link is invisible
# under `is:open`.
_orphan_merged_pr_mentions() {
	local slug="$1" cursor="" has_next="true" query result page after node
	while [ "$has_next" = "true" ]; do
		after=""
		[ -n "$cursor" ] && after=",after:\"$cursor\""
		query="{search(query:\"repo:$slug is:pr is:merged\",type:ISSUE,first:50$after){issueCount pageInfo{hasNextPage endCursor} nodes{... on PullRequest{number title body headRefName closingIssuesReferences(first:20){nodes{number}}}}}}"
		result="$(gh api graphql -f query="$query" 2>/dev/null)" || return 1
		printf '%s' "$result" | jq -e '.errors' >/dev/null 2>&1 && return 1
		# GraphQL `search` stops yielding at 1000 results however far you paginate, so a
		# repo past that ceiling silently drops the merged PR that mentions an open issue
		# and the gate would answer `ok` having never seen it. `issueCount` is the TOTAL
		# match count, not the page size, so it detects the ceiling before it truncates.
		printf '%s' "$result" \
			| jq -e ".data.search.issueCount > $ORPHAN_SEARCH_CEILING" >/dev/null 2>&1 && return 1
		page="$(printf '%s' "$result" | jq -c '.data.search.nodes[]?' 2>/dev/null)" || return 1
		while IFS= read -r node; do
			[ -n "$node" ] || continue
			printf '%s' "$node" | jq -r '
				(.number) as $pr
				| ((.title // "") + " " + (.body // "")) as $text
				| ([$text | scan("#[0-9]+")] | map(ltrimstr("#"))) as $hash_mentions
				| ((.headRefName // "") | [splits("[^0-9]+")] | map(select(length > 0))) as $branch_mentions
				| ([.closingIssuesReferences.nodes[]?.number | tostring]) as $closed
				# A branch embedding this same PR number (e.g. "feat/509-masking" on PR
				# 509) would otherwise self-report as "PR #509 mentions #509" -- exclude.
				| (($hash_mentions + $branch_mentions) | unique | map(select(. != ($pr | tostring)))) as $mentioned
				| $mentioned[] as $m
				| select(($closed | index($m)) == null)
				| "\($m)\t\($pr)\t\($closed | join(","))"
			' 2>/dev/null || return 1
		done <<<"$page"
		# Both reads fail closed. A failed `hasNextPage` read leaves has_next empty, which
		# ends the loop exactly like a genuine "false" -- the caller would then publish the
		# pages gathered so far as a complete answer. An unread cursor is the same defect
		# one step later: the next iteration would re-request page 1 forever.
		has_next="$(printf '%s' "$result" | jq -r '.data.search.pageInfo.hasNextPage // "false"' 2>/dev/null)" || return 1
		[ -n "$has_next" ] || return 1
		if [ "$has_next" = "true" ]; then
			cursor="$(printf '%s' "$result" | jq -r '.data.search.pageInfo.endCursor // empty' 2>/dev/null)" || return 1
			[ -n "$cursor" ] || return 1
		fi
	done
}

gate_orphaned_issues() {
	local owner="$1" repo="$2"
	local slug="$owner/$repo"
	ORPHAN_STATUS="unknown"
	ORPHAN_REPORT=""

	local db
	db="$(gh api "repos/$slug" --jq '.default_branch' 2>/dev/null)" || return 1
	[ -n "$db" ] || return 1

	# `--limit` is a ceiling, not an exhaustive query: a repo past it drops the tail
	# silently, and a dropped issue is discarded by the membership test below as though
	# no PR ever mentioned it. Ask for one MORE than the ceiling -- getting that many
	# back proves the real set is larger than we can enumerate, so answer unknown.
	local open_issues open_count
	open_issues="$(gh issue list --repo "$slug" --state open \
		--limit "$((ORPHAN_OPEN_ISSUE_CEILING + 1))" --json number --jq '.[].number' 2>/dev/null)" || return 1
	open_count="$(printf '%s\n' "$open_issues" | sed '/^$/d' | wc -l)"
	[ "$open_count" -le "$ORPHAN_OPEN_ISSUE_CEILING" ] || return 1

	local mentions
	mentions="$(_orphan_merged_pr_mentions "$slug")" || return 1

	local issue pr closed report=""
	while IFS=$'\t' read -r issue pr closed; do
		[ -n "$issue" ] || continue
		printf '%s\n' "$open_issues" | grep -qxF "$issue" || continue
		report="$(printf '%s\n%s' "$report" \
			"#$issue may already be shipped by PR #$pr (mentions #$issue, closingIssuesReferences=${closed:-none}) -- verify on $db")"
	done <<<"$mentions"

	# shellcheck disable=SC2034 # read by callers after this returns, not within this file
	ORPHAN_REPORT="$(printf '%s\n' "$report" | sed '/^$/d' | sort -u)"
	# shellcheck disable=SC2034 # read by callers after this returns, not within this file
	ORPHAN_STATUS="ok"
	return 0
}

# --- gate_orphaned_surface: the zero-PR-mention direction (dotfiles-linux-dev#419) ---------------------

# _orphan_surface_lines BODY
# Extracts the fenced ` ```surface ` block's non-empty lines from an issue body -- the exact
# format s:intake-plan already parses (one glob/path per line). Empty output means no declared
# surface: the caller's job, not this function's, to decide that is "skip", not "fail".
_orphan_surface_lines() {
	printf '%s\n' "$1" | sed -n '/^```surface/,/^```/p' | sed '1d;$d' | sed '/^[[:space:]]*$/d'
}

# _orphan_surface_present_count TREE LINE...
# Pure glob match, no network (mirrors free_classify_files's own "pure, no network" shape):
# counts how many of the given surface lines match at least one path in TREE (a newline-
# separated tracked-path listing from `git ls-tree`). Prints "present total".
_orphan_surface_present_count() {
	local tree="$1"
	shift
	local total=0 present=0 line f matched
	for line in "$@"; do
		[ -n "$line" ] || continue
		total=$((total + 1))
		matched=0
		while IFS= read -r f; do
			[ -n "$f" ] || continue
			# shellcheck disable=SC2053 # deliberate glob match -- surface lines may carry '*'
			if [[ "$f" == $line ]]; then
				matched=1
				break
			fi
		done <<<"$tree"
		[ "$matched" -eq 1 ] && present=$((present + 1))
	done
	echo "$present $total"
}

gate_orphaned_surface() {
	local owner="$1" repo="$2"
	local slug="$owner/$repo"
	ORPHAN_SURFACE_STATUS="unknown"
	ORPHAN_SURFACE_REPORT=""

	# Never re-derive "which open issues no PR claims" -- free_surface.sh already answers it.
	gate_free_surface "$owner" "$repo" || return 1

	local base_ref
	base_ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
	[ -n "$base_ref" ] || return 1

	local tree
	tree="$(git ls-tree -r --name-only "$base_ref" 2>/dev/null)" || return 1

	local issue body lines_str present_total present total report=""
	local -a lines
	while IFS= read -r issue; do
		[ -n "$issue" ] || continue
		body="$(gh issue view "$issue" --repo "$slug" --json body --jq '.body' 2>/dev/null)" || return 1
		lines_str="$(_orphan_surface_lines "$body")"
		[ -n "$lines_str" ] || continue # no declared surface -- not a candidate for this pass

		mapfile -t lines <<<"$lines_str"
		present_total="$(_orphan_surface_present_count "$tree" "${lines[@]}")"
		present="${present_total%% *}"
		total="${present_total##* }"

		if [ "$total" -gt 0 ] && [ "$present" -eq "$total" ]; then
			report="$(printf '%s\n%s' "$report" \
				"#$issue may already be shipped -- declared surface fully present on $base_ref, no PR claims it -- verify before closing")"
		elif [ "$present" -gt 0 ]; then
			report="$(printf '%s\n%s' "$report" \
				"#$issue partially shipped ($present of $total surface paths present on $base_ref) -- verify before closing")"
		fi
	done <<<"$FREE_UNCLAIMED_ISSUES"

	# shellcheck disable=SC2034 # read by callers after this returns, not within this file
	ORPHAN_SURFACE_REPORT="$(printf '%s\n' "$report" | sed '/^$/d' | sort -u)"
	# shellcheck disable=SC2034 # read by callers after this returns, not within this file
	ORPHAN_SURFACE_STATUS="ok"
	return 0
}
