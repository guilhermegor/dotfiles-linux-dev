#!/bin/bash
# Kanban reconcile — closing direction + No-Status placement (dotfiles-dev#556).
#
# kanban_reconcile.sh's reconcile_kanban() only moves a card FORWARD to "In review" for an issue
# an open PR names in closingIssuesReferences. As a side effect it already covers a No-Status
# issue that has an open closing PR (an empty Status has no rank in the board's own column
# order, so it is never treated as "at/beyond target" and falls through to the move) — nothing
# here duplicates that. What nothing does yet:
#   1. A CLOSED issue's card never reaches Done. The two native board workflows that would set
#      it ("Item closed", "Pull request merged") are disabled and the API cannot enable them —
#      see issue #556's own body.
#   2. A card with NO STATUS AT ALL and no open closing PR sits in "No Status" forever, because
#      the "Auto-add to project" workflow drops new issues there with nothing to advance them
#      (dotfiles-dev#556's scope extension — #567, #571, #577, #579 measured stuck there).
#
# Kept in its own file/function rather than folded into kanban_reconcile.sh's reconcile_kanban():
# that file is being edited concurrently for board-gate/throttle-fallback work (dotfiles-dev#567)
# — landing here as its own small commit keeps that merge trivial. This file SOURCES
# kanban_reconcile.sh's already-shared helpers (board_config, move_card, _kr_status_names)
# instead of redefining them — see subagent_stop_sweep.sh's source order, which sources
# kanban_reconcile.sh before this file.
#
# Budget (GraphQL is burst-limited across ~10 concurrent agents right now): ONE
# `gh project item-list` read for the whole board, plus REST-only reads — one paginated
# `repos/<o>/<r>/issues?state=open` listing (bounded by the OPEN count, not the repo's history),
# one `repos/<o>/<r>/issues/<N>` read per board card the listing did not name and that is not
# already Done, and `git ls-remote` for pushed branches (git, not gh, so it doesn't touch either
# API budget). No per-card GraphQL call, ever.
# Native `blocked_by` detection (GitHub's issue-dependency graph) would need a call PER CARD to
# read — skipped for exactly that reason.
# ponytail: label-only Blocked detection; add native blocked_by if a per-card budget opens up.
#
# Contract:
#   reconcile_kanban_done OWNER REPO CWD
#     Sets two globals (never partial):
#       RECONCILE_DONE_STATUS = ok | unknown
#       RECONCILE_DONE_REPORT = newline-separated "moved issue #N ..." lines, or empty when
#                               nothing needed to move. An empty report on STATUS=ok is a real,
#                               ordinary answer, never treated as a failure.
#     Returns 1 and sets RECONCILE_DONE_STATUS=unknown (REPORT holding one explanatory line)
#     only when the board itself, the project item list, or the repo's open-issue list can't be
#     read. A single card's own confirmation read failing does not abort the round — it is
#     reported as an "UNKNOWN issue #N" line and the next card is still processed (same
#     fail-closed-per-item shape as kanban_reconcile.sh and roadmap_unblock.sh).
#
#     Never moves a card backwards: a closed issue whose card is already at or past Done (by the
#     board's own Status option order) is left alone — the #131 rule. A No-Status derivation
#     never "moves backwards" by construction: it only ever applies to a card with NO status.
set -u

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	echo "kanban_reconcile_done.sh is meant to be sourced, not executed." >&2
	exit 1
fi

_KRD_GIT=/usr/bin/git

# _krd_open_issue_facts OWNER REPO
# Prints "<number>\t<state>\t<labels,comma,separated>" for every OPEN ISSUE (never a PR — the
# same endpoint lists both), from a paginated REST read bounded by the open count, not the
# repo's whole history (state=all paged through every issue and PR ever filed).
# Closed issues are confirmed per board card by _krd_confirm_issue instead. Returns 1 on any
# read/parse failure — the caller's fail-closed signal for the whole round.
_krd_open_issue_facts() {
	local owner="$1" repo="$2" json
	json="$(gh api "repos/$owner/$repo/issues?state=open&per_page=100" --paginate 2>/dev/null)" || return 1
	# -s: --paginate emits one array per page, so slurp before validating or reading.
	printf '%s' "$json" | jq -se 'length > 0 and all(type == "array")' >/dev/null 2>&1 || return 1
	printf '%s' "$json" | jq -sr '.[][] | select(has("pull_request") | not) |
		"\(.number)\t\(.state)\t\([.labels[].name] | join(","))"' 2>/dev/null
}

# _krd_confirm_issue OWNER REPO NUMBER
# Same output line as _krd_open_issue_facts, for ONE issue, from one REST read. Called only for a
# board card the open listing did not name — absence from that listing means "not open", and
# whether that is closed, transferred, or unreadable is exactly what this read decides. Returns 1
# on any read/parse failure: UNKNOWN for that card, never "closed".
_krd_confirm_issue() {
	local owner="$1" repo="$2" number="$3" json
	json="$(gh api "repos/$owner/$repo/issues/$number" 2>/dev/null)" || return 1
	printf '%s' "$json" | jq -re 'select(type == "object" and (.state | type == "string") and
		(has("pull_request") | not)) |
		"\(.number)\t\(.state)\t\([.labels[].name] | join(","))"' 2>/dev/null
}

# _krd_branch_refs_issue CWD NUMBER
# True if any remote branch name carries NUMBER as a delimited token (`fix/556-...`,
# `issue-556`, `556-something`) — never a bare substring match, which would also fire on issue 5
# matching a branch named `.../1556-...`. Reuses the same `git ls-remote` the sweep's own
# orphan-branch check already runs — no extra API call of either kind.
_krd_branch_refs_issue() {
	local cwd="$1" number="$2"
	$_KRD_GIT -C "$cwd" ls-remote --heads origin 2>/dev/null |
		sed 's#.*refs/heads/##' |
		grep -qE "(^|[^0-9])$number([^0-9]|$)"
}

# _krd_claimed_issue CWD NUMBER
# True if lib/dispatch_claims.sh's registry holds a live claim for NUMBER. File-based, no gh
# call either. The CALLER must source lib/dispatch_claims.sh (subagent_stop_sweep.sh does) —
# with it unsourced this is always false, so a claimed No-Status issue reads as Ready and looks
# free to dispatch twice. CWD is passed through because the registry lives in the git common
# dir of the repo being swept, which is not necessarily the process's $PWD.
_krd_claimed_issue() {
	local cwd="$1" number="$2"
	command -v dispatch_claimed_issues >/dev/null 2>&1 || return 1
	dispatch_claimed_issues "$cwd" 2>/dev/null | grep -qxF "$number"
}

# _krd_rank ORDER_LIST NAME
# NAME's 1-based line number in ORDER_LIST, or empty if absent (a No-Status card, or a column
# this board doesn't have).
_krd_rank() {
	printf '%s\n' "$1" | grep -nxF "$2" | head -n1 | cut -d: -f1
}

# _krd_target_column CWD NUMBER LABELS
# The derived column name for one OPEN, No-Status card. Priority: an explicit `state:blocked`
# label always wins; then a pushed branch or a live dispatch claim naming this issue; else Ready.
_krd_target_column() {
	local cwd="$1" number="$2" labels="$3"
	case ",$labels," in
	*,state:blocked,*)
		echo "Blocked"
		return
		;;
	esac
	if _krd_branch_refs_issue "$cwd" "$number" || _krd_claimed_issue "$cwd" "$number"; then
		echo "In progress"
		return
	fi
	echo "Ready"
}

reconcile_kanban_done() {
	local owner="$1" repo="$2" cwd="${3:-.}"
	RECONCILE_DONE_STATUS="unknown"
	RECONCILE_DONE_REPORT=""

	local project_number project_node status_field done_option
	read -r project_number project_node status_field done_option \
		< <(board_config "$owner" "$repo" "Done") || {
		RECONCILE_DONE_REPORT="UNKNOWN: could not resolve board for $owner/$repo"
		return 1
	}
	if [[ "$project_number" == "AMBIGUOUS" ]]; then
		RECONCILE_DONE_REPORT="UNKNOWN: more than one \"$repo kanban\" board — refusing to guess"
		return 1
	fi
	if [[ -z "$project_number" || -z "$done_option" ]]; then
		RECONCILE_DONE_REPORT="UNKNOWN: no \"$repo kanban\" board or no Done column"
		return 1
	fi

	local order_list target_rank
	order_list="$(_kr_status_names "$owner" "$project_number")"
	if [[ -z "$order_list" ]]; then
		RECONCILE_DONE_REPORT="UNKNOWN: could not read Status column order for $owner/$repo"
		return 1
	fi
	target_rank="$(_krd_rank "$order_list" "Done")"
	if [[ -z "$target_rank" ]]; then
		RECONCILE_DONE_REPORT="UNKNOWN: no Done column found for $owner/$repo"
		return 1
	fi

	# Capped the same way reconcile_kanban() caps its own item-list read: a HIT cap means the
	# answer may be partial, and a partial reconcile reported as ok is the failure this guards.
	local item_limit=500
	local items_json item_count
	items_json="$(gh project item-list "$project_number" --owner "$owner" --format json --limit "$item_limit" 2>/dev/null)" || {
		RECONCILE_DONE_REPORT="UNKNOWN: could not read project items for $owner/$repo"
		return 1
	}
	printf '%s' "$items_json" | jq -e 'type=="object" and (.items | type == "array")' \
		>/dev/null 2>&1 || {
		RECONCILE_DONE_REPORT="UNKNOWN: could not parse project items for $owner/$repo"
		return 1
	}
	item_count="$(printf '%s' "$items_json" | jq '.items | length' 2>/dev/null)"
	if [[ -n "$item_count" ]] && ((item_count >= item_limit)); then
		RECONCILE_DONE_REPORT="UNKNOWN: project item list hit the $item_limit cap for $owner/$repo — result may be truncated"
		return 1
	fi

	local open_facts
	open_facts="$(_krd_open_issue_facts "$owner" "$repo")" || {
		RECONCILE_DONE_REPORT="UNKNOWN: could not read open issues for $owner/$repo"
		return 1
	}

	local report="" line id content_number content_repo status
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		id="$(printf '%s' "$line" | cut -f1)"
		content_number="$(printf '%s' "$line" | cut -f2)"
		content_repo="$(printf '%s' "$line" | cut -f3)"
		status="$(printf '%s' "$line" | cut -f4)"

		# A card from another repo on this board is not this repo's to judge.
		[[ "$content_repo" == "$owner/$repo" ]] || continue

		local fact state labels
		fact="$(printf '%s\n' "$open_facts" | awk -F'\t' -v n="$content_number" '$1 == n')"
		if [[ -z "$fact" ]]; then
			# Not open. A card already in Done needs nothing either way — skip the read.
			[[ "$status" != "Done" ]] || continue
			fact="$(_krd_confirm_issue "$owner" "$repo" "$content_number")" || fact=""
		fi
		if [[ -z "$fact" ]]; then
			report="$(printf '%s\nUNKNOWN issue #%s: could not confirm its state' "$report" "$content_number")"
			continue
		fi
		state="$(printf '%s' "$fact" | cut -f2)"
		labels="$(printf '%s' "$fact" | cut -f3)"

		if [[ "$state" == "closed" ]]; then
			if [[ "$status" == "Done" ]]; then
				continue
			fi
			local rank
			rank="$(_krd_rank "$order_list" "$status")"
			if [[ -n "$rank" ]] && ((rank >= target_rank)); then
				continue # already at/beyond Done by rank — never backwards
			fi
			if move_card "$project_node" "$id" "$status_field" "$done_option"; then
				report="$(printf '%s\nmoved issue #%s to Done (was: %s)' "$report" "$content_number" "${status:-none}")"
			else
				report="$(printf '%s\nFAILED to move issue #%s to Done — verify by hand' "$report" "$content_number")"
			fi
			continue
		fi

		# Open issue: only a No-Status card is this function's concern. Anything already placed
		# (Backlog/In progress/In review/...) is left exactly where it is — the #131 rule again.
		[[ -z "$status" ]] || continue

		local target target_option
		target="$(_krd_target_column "$cwd" "$content_number" "$labels")"
		read -r _ _ _ target_option < <(board_config "$owner" "$repo" "$target")
		if [[ -z "$target_option" ]]; then
			report="$(printf '%s\nUNKNOWN issue #%s: no \"%s\" column on this board' "$report" "$content_number" "$target")"
			continue
		fi
		if move_card "$project_node" "$id" "$status_field" "$target_option"; then
			report="$(printf '%s\nmoved issue #%s from No Status to %s' "$report" "$content_number" "$target")"
		else
			report="$(printf '%s\nFAILED to move issue #%s to %s — verify by hand' "$report" "$content_number" "$target")"
		fi
	done < <(printf '%s' "$items_json" | jq -r '.items[] | select(.content.type=="Issue") |
		"\(.id)\t\(.content.number)\t\(.content.repository)\t\(.status // "")"')

	# shellcheck disable=SC2034 # read by callers after this returns, not within this file
	RECONCILE_DONE_STATUS="ok"
	# shellcheck disable=SC2034 # read by callers after this returns, not within this file
	RECONCILE_DONE_REPORT="$(printf '%s\n' "$report" | sed '/^$/d')"
	return 0
}
