#!/bin/bash
# Kanban reconcile — place OPEN issues that never reached the board (dotfiles-linux-dev#1021).
#
# kanban_reconcile.sh and kanban_reconcile_done.sh only act on cards already ON a board, so an
# open issue with no card (/issue's board write failed under a GraphQL refusal and nothing
# recorded that a card was owed) was invisible to every pass. This one lists the repo's open
# issues over REST, diffs them against the board's items, and `item-add`s the missing ones.
#
# Status mirrors /issue step 7, and REUSES its helpers instead of re-deriving them:
#   open native blocker (roadmap_unblock.sh `_ru_open_blockers`) -> Blocked
#   work type `task` with a complete spec (issue_spec_complete.sh)  -> Ready
#   anything else (research/prototype/grilling, unknown type, thin spec) -> Backlog
# A blocker read that fails is UNKNOWN for that issue: it is NOT added, never guessed Ready.
#
# The item read is NOT `_board_item_list` (non-Done only): a Done card of a still-open issue is
# on the board, and adding it would re-set its Status.
#
# Contract: reconcile_kanban_offboard OWNER REPO CWD
#   Sets RECONCILE_OFFBOARD_STATUS = ok | unknown, RECONCILE_OFFBOARD_REPORT = one
#   "moved issue #N onto the board in <column>" line per added card. Under the GraphQL latch the
#   report is "UNKNOWN (latched)" and returns 1. Sourced by subagent_stop_sweep.sh, after
#   kanban_reconcile.sh and roadmap_unblock.sh.
set -u

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	echo "kanban_reconcile_offboard.sh is meant to be sourced, not executed." >&2
	exit 1
fi

# _kro_open_issues OWNER REPO — one JSON object per open issue (never a PR), or return 1.
_kro_open_issues() {
	local json
	json="$(gh api "repos/$1/$2/issues?state=open&per_page=100" --paginate 2>/dev/null)" || return 1
	printf '%s' "$json" | jq -se 'all(type == "array")' >/dev/null 2>&1 || return 1
	printf '%s' "$json" | jq -sc '.[][] | select(has("pull_request") | not)' 2>/dev/null
}

# _kro_work_type ISSUE_JSON — `type.name`, else a `type:<x>` label, else empty.
_kro_work_type() {
	jq -r '(.type.name // ([.labels[].name | select(startswith("type:")) | sub("^type:"; "")] | first) // "")
		| ascii_downcase' <<<"$1"
}

# _kro_target_column OWNER REPO ISSUE_JSON — prints the column; returns 1 when the blocker read fails.
_kro_target_column() {
	local owner="$1" repo="$2" issue="$3" number body blockers
	number="$(jq -r '.number' <<<"$issue")"
	body="$(jq -r '.body // ""' <<<"$issue")"
	blockers="$(_ru_open_blockers "$owner/$repo" "$number" "" "$(_ru_body_blocked_line "$body")")" || return 1
	if [[ -n "$blockers" ]]; then
		echo "Blocked"
	elif [[ "$(_kro_work_type "$issue")" == "task" ]] && declare -F spec_incomplete_reasons >/dev/null \
		&& [[ -z "$(spec_incomplete_reasons "$body" 2>/dev/null)" ]]; then
		echo "Ready"
	else
		echo "Backlog"
	fi
}

reconcile_kanban_offboard() {
	local owner="$1" repo="$2"
	RECONCILE_OFFBOARD_STATUS="unknown"
	RECONCILE_OFFBOARD_REPORT=""

	if command -v gh_budget_latch_active >/dev/null 2>&1 && gh_budget_latch_active; then
		RECONCILE_OFFBOARD_REPORT="UNKNOWN (latched): GraphQL budget latch active, off-board issues not checked"
		return 1
	fi

	local project_number project_node status_field backlog_option
	read -r project_number project_node status_field backlog_option \
		< <(board_config "$owner" "$repo" "Backlog") || {
		RECONCILE_OFFBOARD_REPORT="UNKNOWN: could not resolve board for $owner/$repo"
		return 1
	}
	if [[ "$project_number" == "AMBIGUOUS" || -z "$project_number" || -z "$backlog_option" ]]; then
		RECONCILE_OFFBOARD_REPORT="UNKNOWN: no single \"$repo kanban\" board with a Backlog column"
		return 1
	fi

	local limit=500 items_json count
	if ! items_json="$(gh project item-list "$project_number" --owner "$owner" --format json \
		--limit "$limit" 2>/dev/null)"; then
		if _board_throttled; then
			gh_budget_latch_write "$(gh_budget_reset_ttl)" || true
			RECONCILE_OFFBOARD_REPORT="UNKNOWN (throttled): GraphQL rate-limited, board items not read"
		else
			RECONCILE_OFFBOARD_REPORT="UNKNOWN: could not read project items for $owner/$repo"
		fi
		return 1
	fi
	count="$(jq -e '.items | if type == "array" then length else error("items is not an array") end' <<<"$items_json" 2>/dev/null)" || {
		RECONCILE_OFFBOARD_REPORT="UNKNOWN: could not parse project items for $owner/$repo"
		return 1
	}
	if ((count >= limit)); then
		RECONCILE_OFFBOARD_REPORT="UNKNOWN: project item list hit the $limit cap for $owner/$repo"
		return 1
	fi

	local on_board issues
	on_board="$(jq -r --arg r "$owner/$repo" '.items[] | select(.content.type == "Issue" and
		.content.repository == $r) | .content.number' <<<"$items_json")"
	issues="$(_kro_open_issues "$owner" "$repo")" || {
		RECONCILE_OFFBOARD_REPORT="UNKNOWN: could not read open issues for $owner/$repo"
		return 1
	}

	local report="" issue number url target option added item_id
	while IFS= read -r issue <&3; do
		[[ -n "$issue" ]] || continue
		number="$(jq -r '.number' <<<"$issue")"
		grep -qxF "$number" <<<"$on_board" && continue
		if ! target="$(_kro_target_column "$owner" "$repo" "$issue")"; then
			report+="UNKNOWN issue #$number: blocker read failed, not added"$'\n'
			continue
		fi
		read -r _ _ _ option < <(board_config "$owner" "$repo" "$target")
		[[ -n "$option" ]] || { target="Backlog"; option="$backlog_option"; }
		url="$(jq -r '.html_url' <<<"$issue")"
		if ! added="$(gh project item-add "$project_number" --owner "$owner" --url "$url" \
			--format json 2>/dev/null)"; then
			if _board_throttled; then
				gh_budget_latch_write "$(gh_budget_reset_ttl)" \
					|| report+="latch write FAILED: later boards may still call GraphQL"$'\n'
				report+="UNKNOWN (throttled): GraphQL rate-limited at issue #$number, remaining not added"$'\n'
				RECONCILE_OFFBOARD_REPORT="$(printf '%s' "$report" | sed '/^$/d')"
				return 1
			fi
			report+="FAILED to add issue #$number to the board — verify by hand"$'\n'
			continue
		fi
		item_id="$(jq -r '.id // empty' <<<"$added" 2>/dev/null)"
		if [[ -n "$item_id" ]] && move_card "$project_node" "$item_id" "$status_field" "$option"; then
			report+="moved issue #$number onto the board in $target"$'\n'
		else
			report+="FAILED to set Status $target on added issue #$number — verify by hand"$'\n'
		fi
	done 3<<<"$issues"

	# shellcheck disable=SC2034 # read by callers after this returns
	RECONCILE_OFFBOARD_STATUS="ok"
	# shellcheck disable=SC2034 # read by callers after this returns
	RECONCILE_OFFBOARD_REPORT="$(printf '%s' "$report" | sed '/^$/d')"
	return 0
}
