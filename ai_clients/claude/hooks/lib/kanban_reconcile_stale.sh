#!/bin/bash
# Kanban reconcile — stale cards (dotfiles-linux-dev#888).
#
# kanban_reconcile.sh moves a card forward on an open PR and kanban_reconcile_done.sh moves a
# closed issue to Done; neither can see a card that is stuck for any other reason. Three rules:
#   1. In review, issue still open, no open PR names it, and a PR that did was closed WITHOUT
#      merge -> back to Ready. The only move this file makes.
#   2. In progress with no commit on its pushed branch for KANBAN_STALE_DAYS -> REPORT only.
#      The column is still true and someone may be thinking rather than typing.
#   3. A card with an open closing PR outside In review is already moved by [7]; it is counted
#      so a PR list that could not be read shows up as UNKNOWN instead of reading as clean.
#
# Sources the helpers of kanban_reconcile.sh (board_config, move_card, _kr_status_names) and
# kanban_reconcile_done.sh (_krd_open_issue_facts); subagent_stop_sweep.sh sources both first.
#
# Contract:
#   reconcile_kanban_stale OWNER REPO CWD
#     Sets RECONCILE_STALE_STATUS = ok | unknown and RECONCILE_STALE_REPORT (one line per
#     finding). Returns 1 with STATUS=unknown and ONE explanatory line when the board, the item
#     list, the open-issue list or the PR lists cannot be read: nothing is moved in that round.
#     A single card whose branch cannot be read is an "UNKNOWN issue #N" line; the round goes on.
set -u

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	echo "kanban_reconcile_stale.sh is meant to be sourced, not executed." >&2
	exit 1
fi

# Days without a commit before an In progress card is reported stale.
KANBAN_STALE_DAYS="${KANBAN_STALE_DAYS:-7}"
_KRS_GIT=/usr/bin/git

# _krs_pr_lists OWNER REPO
# Prints one JSON array of every open and closed PR, all pages: a merged PR beyond a capped page
# would hide behind a closed-unmerged one and let the card move. REST only, one call per 100 PRs.
# Returns 1 on any read/parse failure.
_krs_pr_lists() {
	local owner="$1" repo="$2" open closed
	open="$(gh api "repos/$owner/$repo/pulls?state=open&per_page=100" --paginate 2>/dev/null)" || return 1
	closed="$(gh api "repos/$owner/$repo/pulls?state=closed&per_page=100" --paginate 2>/dev/null)" || return 1
	printf '%s\n%s' "$open" "$closed" |
		jq -se 'length > 0 and all(type == "array")' >/dev/null 2>&1 || return 1
	printf '%s\n%s' "$open" "$closed" | jq -sc 'add'
}

# _krs_pr_kind PRS_JSON NUMBER OWNER/REPO
# The body form is `Closes #N` or `Closes OWNER/REPO#N` (this repo's slug only).
# "open" if an open PR names the issue, else "merged" if a merged one does (a merge always blocks
# the move to Ready), else "unmerged" if a closed-unmerged one does, else "none".
# Only PRs by a trusted author (OWNER/MEMBER/COLLABORATOR) count: anyone can open and close a PR
# naming #N, and that must not drive a board change. A PR names the issue by the repo branch
# convention `<type>/N-...` or a Closes/Fixes/Resolves #N in its (trusted) body.
_krs_pr_kind() {
	printf '%s' "$1" | jq -r --arg n "$2" --arg slug "$3" '
		def trusted: .author_association | IN("OWNER", "MEMBER", "COLLABORATOR");
		def names: (.head.ref | test("^[a-z]+/" + $n + "-")) or
			((.body // "") | test("(?i)(close[sd]?|fix(e[sd])?|resolve[sd]?):? +(" +
				($slug | gsub("[.]"; "\\.")) + ")?#" + $n + "([^0-9]|$)"));
		[.[] | select(trusted and names)] as $m |
		if any($m[]; .state == "open") then "open"
		elif any($m[]; .merged_at != null) then "merged"
		elif any($m[]; .state == "closed") then "unmerged"
		else "none" end'
}

# _krs_last_commit_age_days CWD NUMBER
# Prints "<days> <branch>" for the newest tip among remote branches naming NUMBER, or nothing when
# none exists. Returns 1 when the branch list or a tip's date cannot be read — never "fresh".
_krs_last_commit_age_days() {
	local cwd="$1" number="$2" refs sha ref b ts newest=0 newest_b="" now
	refs="$($_KRS_GIT -C "$cwd" ls-remote --heads origin 2>/dev/null)" || return 1
	now="$(date +%s)"
	# Dated from the SHA ls-remote returned, never a local tracking ref that may predate a push;
	# a SHA missing locally fails the read (UNKNOWN), it is not read as "old".
	while read -r sha ref; do
		b="${ref#refs/heads/}"
		[[ -n "$sha" && "$b" =~ ^[a-z]+/$number- ]] || continue
		ts="$($_KRS_GIT -C "$cwd" log -1 --format=%ct "$sha^{commit}" 2>/dev/null)" || return 1
		[[ "$ts" =~ ^[0-9]+$ ]] || return 1
		if ((ts > newest)); then
			newest="$ts"
			newest_b="$b"
		fi
	done <<<"$refs"
	[[ -n "$newest_b" ]] || return 0
	echo "$(((now - newest) / 86400)) $newest_b"
}

reconcile_kanban_stale() {
	local owner="$1" repo="$2" cwd="${3:-.}"
	RECONCILE_STALE_STATUS="unknown"
	RECONCILE_STALE_REPORT=""

	local project_number project_node status_field ready_option
	read -r project_number project_node status_field ready_option \
		< <(board_config "$owner" "$repo" "Ready") || {
		RECONCILE_STALE_REPORT="UNKNOWN: could not resolve board for $owner/$repo"
		return 1
	}
	if [[ -z "$project_number" || "$project_number" == "AMBIGUOUS" || -z "$ready_option" ]]; then
		RECONCILE_STALE_REPORT="UNKNOWN: no unambiguous \"$repo kanban\" board with a Ready column"
		return 1
	fi

	local item_limit=500 items_json
	items_json="$(gh project item-list "$project_number" --owner "$owner" --format json --limit "$item_limit" 2>/dev/null)" &&
		printf '%s' "$items_json" | jq -e --argjson cap "$item_limit" \
			'type=="object" and (.items | type == "array") and (.items | length) < $cap' >/dev/null 2>&1 || {
		RECONCILE_STALE_REPORT="UNKNOWN: could not read a complete project item list for $owner/$repo"
		return 1
	}

	local open_facts prs
	open_facts="$(_krd_open_issue_facts "$owner" "$repo")" || {
		RECONCILE_STALE_REPORT="UNKNOWN: could not read open issues for $owner/$repo"
		return 1
	}
	prs="$(_krs_pr_lists "$owner" "$repo")" || {
		RECONCILE_STALE_REPORT="UNKNOWN: could not read pull requests for $owner/$repo"
		return 1
	}

	local report="" outside_review=0 id number status kind age_branch
	while IFS=$'\t' read -r id number status; do
		[[ -n "$id" ]] || continue
		# Only an OPEN issue is this file's concern; closed ones belong to reconcile_kanban_done.
		printf '%s\n' "$open_facts" | awk -F'\t' -v n="$number" '$1 == n {f=1} END {exit !f}' || continue
		kind="$(_krs_pr_kind "$prs" "$number" "$owner/$repo")" || {
			report="$(printf '%s\nUNKNOWN issue #%s: could not match its pull requests' "$report" "$number")"
			continue
		}
		if [[ "$kind" == "open" && "$status" != "In review" ]]; then
			outside_review=$((outside_review + 1))
		fi
		case "$status" in
		"In review")
			[[ "$kind" == "unmerged" ]] || continue
			if move_card "$project_node" "$id" "$status_field" "$ready_option"; then
				report="$(printf '%s\nmoved issue #%s to Ready (its PR was closed without merge)' "$report" "$number")"
			else
				report="$(printf '%s\nFAILED to move issue #%s to Ready — verify by hand' "$report" "$number")"
			fi
			;;
		"In progress")
			age_branch="$(_krs_last_commit_age_days "$cwd" "$number")" || {
				report="$(printf '%s\nUNKNOWN issue #%s: could not read its branch history' "$report" "$number")"
				continue
			}
			[[ -n "$age_branch" ]] || continue
			if ((${age_branch%% *} >= KANBAN_STALE_DAYS)); then
				report="$(printf '%s\nSTALE issue #%s: In progress, no commit for %s days on %s (report only)' \
					"$report" "$number" "${age_branch%% *}" "${age_branch#* }")"
			fi
			;;
		esac
	done < <(printf '%s' "$items_json" | jq -r '.items[] |
		select(.content.type == "Issue" and .content.repository == "'"$owner/$repo"'") |
		"\(.id)\t\(.content.number)\t\(.status // "")"')

	report="$(printf '%s\nopen-PR cards outside In review: %s (reconcile [7] moves them)' "$report" "$outside_review")"
	# shellcheck disable=SC2034 # read by callers after this returns, not within this file
	RECONCILE_STALE_STATUS="ok"
	# shellcheck disable=SC2034 # read by callers after this returns, not within this file
	RECONCILE_STALE_REPORT="$(printf '%s\n' "$report" | sed '/^$/d')"
	return 0
}
