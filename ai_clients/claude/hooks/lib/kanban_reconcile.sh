#!/bin/bash
# Shared kanban board helpers + reconcile (dotfiles-dev#448).
#
# owner_repo/cache_file/discover_board/board_config/move_card used to live only in
# kanban_lifecycle.sh. Moved here so the event hook and the reconcile below share ONE
# implementation instead of two copies that drift (same seam as free_surface.sh /
# review_thread_gate.sh: a shared gate/helper file sourced by more than one hook).
#
# Why a reconcile, not a better event hook: kanban_lifecycle.sh's PostToolUse hook only fires
# when the harness observes the EVENT (`gh pr create`) in ITS OWN Bash tool call, in the right
# cwd. Measured 2026-09-21: 8 of 8 issues with an open PR sat in Backlog because the PR was
# opened by a dispatched agent (cwd reset mid-session, dotfiles-dev#229), during a `gh` 403
# window (#445), or by a rescue committing on someone else's branch — all the same defect: an
# event-only transition has no recovery when the event is missed. Same seam as
# hooks/lib/roadmap_unblock.sh (#369): the correct Status is derivable from the forge at any
# time, so re-derive it every round instead of trusting only the event.
#
# Contract:
#   reconcile_kanban OWNER REPO
#     For every OPEN pull request in OWNER/REPO, resolves its linked issue(s) via
#     `closingIssuesReferences` (GraphQL — NOT the branch-name heuristic; free_surface.sh's own
#     header explains why that heuristic is disqualified) and moves each linked OPEN issue's
#     card to "In review" when its current Status is BEHIND "In review" in the board's own
#     column order. Never moves a card backwards: an issue already In review, Done, or any
#     column at/after In review is left untouched. Column order is read fresh from
#     `gh project field-list` every call, never hardcoded, so a renamed/reordered board is
#     still handled correctly.
#
#     Sets two globals (never partial):
#       RECONCILE_KANBAN_STATUS = ok | unknown
#       RECONCILE_KANBAN_REPORT = newline-separated "moved issue #N ..." lines, or empty when
#                                 nothing needed to move. An empty report on STATUS=ok is a
#                                 real, ordinary answer ("no kanban cards changed"), never
#                                 treated as a failure.
#     Returns 1 and sets RECONCILE_KANBAN_STATUS=unknown (REPORT holding one explanatory line)
#     only when the board itself, the open-PR list, or the Status column order can't be read.
#     A single PR's own closingIssuesReferences read failure does not abort the round — it is
#     reported as an "UNKNOWN PR #N" line and the next PR is still processed (same
#     fail-closed-per-item shape as roadmap_unblock.sh).
#
# dotfiles-dev#567: the Status-order read (`_kr_status_names`) and the project item read
# (`_board_item_list`, shared with roadmap_unblock.sh) both go through `gh project` porcelain
# ONLY — no second channel. A throttle there can surface as a plain-looking error ("unknown owner
# type") that reads as a config fault rather than a rate limit, and neither call had a fallback
# once it failed. Both now: (1) confirm a throttle with a FRESH `gh api graphql` probe rather than
# trusting the porcelain failure's own text (`_board_throttled`), and (2) make exactly one
# `gh api graphql` fallback read when the failure is NOT a confirmed throttle. A confirmed
# throttle is reported as "UNKNOWN (throttled)" (try next round); an unreadable board after the
# fallback also fails is "UNKNOWN (board unreadable)" (the board is misconfigured) — the two want
# different responses from a reader. Never a retry loop: one porcelain attempt, one fallback
# attempt, then report.
set -u

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	echo "kanban_reconcile.sh is meant to be sourced, not executed." >&2
	exit 1
fi

: "${CACHE_DIR:=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/kanban-boards}"

owner_repo() {
	gh repo view --json owner,name -q '.owner.login + " " + .name' 2>/dev/null
}

cache_file() {
	printf '%s/%s-%s.json' "$CACHE_DIR" "$1" "$2"
}

discover_board() {
	# Find the `<repo> kanban` project, resolve its Status field + option ids, cache the result, and
	# echo it as one JSON object. Returns: 0 + config on success, 1 when no such board exists, and
	# 2 when MORE THAN ONE board carries that title (refuse to guess — the caller surfaces this).
	local owner="$1" repo="$2" projects matches count num node fields field_id options config
	projects="$(gh project list --owner "$owner" --format json 2>/dev/null)" || return 1

	matches="$(printf '%s' "$projects" \
		| jq -r --arg t "$repo kanban" '.projects[] | select(.title==$t) | "\(.number) \(.id)"')"
	count="$(printf '%s\n' "$matches" | grep -c .)"
	(( count == 0 )) && return 1
	if (( count > 1 )); then
		# A silent head -n1 pick here would move a random board's card. Refuse instead — issue.md
		# now prevents duplicate-titled boards, so this is the safety net for one already out there.
		return 2
	fi

	read -r num node <<< "$matches"
	[[ -n "$num" && -n "$node" ]] || return 1

	fields="$(gh project field-list "$num" --owner "$owner" --format json 2>/dev/null)" || return 1
	field_id="$(printf '%s' "$fields" | jq -r '.fields[] | select(.name=="Status") | .id' | head -n1)"
	[[ -n "$field_id" ]] || return 1
	options="$(printf '%s' "$fields" \
		| jq -c '[.fields[] | select(.name=="Status") | .options[]] | map({(.name): .id}) | add')"
	[[ -n "$options" && "$options" != "null" ]] || return 1

	config="$(jq -n --argjson num "$num" --arg node "$node" --arg field "$field_id" \
		--argjson options "$options" \
		'{project_number:$num, project_node_id:$node, status_field_id:$field, options:$options}')"

	mkdir -p "$CACHE_DIR" 2>/dev/null && printf '%s\n' "$config" > "$(cache_file "$owner" "$repo")" 2>/dev/null
	printf '%s' "$config"
}

board_config() {
	# Emit "<project_number> <project_node> <status_field_id> <option_id_for_target>". Reads the
	# per-repo cache, discovering + writing it on a miss. Returns 1 if there is no `<repo> kanban`
	# board or the target column does not exist.
	local owner="$1" repo="$2" target="$3" file line num node field opt
	file="$(cache_file "$owner" "$repo")"

	if [[ -r "$file" ]]; then
		opt="$(jq -r --arg t "$target" '.options[$t] // empty' "$file" 2>/dev/null)"
		if [[ -n "$opt" ]]; then
			num="$(jq -r '.project_number' "$file")"
			node="$(jq -r '.project_node_id' "$file")"
			field="$(jq -r '.status_field_id' "$file")"
			# Trailing newline is required: the caller uses `read`, which returns non-zero on EOF
			# before a delimiter and would trip its `|| exit 0` despite assigning the vars.
			printf '%s %s %s %s\n' "$num" "$node" "$field" "$opt"
			return 0
		fi
	fi

	local rc
	line="$(discover_board "$owner" "$repo")"; rc=$?   # writes the cache as a side effect
	(( rc == 2 )) && { printf 'AMBIGUOUS\n'; return 0; }   # >1 same-named board — let the caller warn
	(( rc == 0 )) || return 1
	opt="$(printf '%s' "$line" | jq -r --arg t "$target" '.options[$t] // empty' 2>/dev/null)"
	[[ -n "$opt" ]] || return 1
	printf '%s %s %s %s\n' \
		"$(printf '%s' "$line" | jq -r '.project_number')" \
		"$(printf '%s' "$line" | jq -r '.project_node_id')" \
		"$(printf '%s' "$line" | jq -r '.status_field_id')" \
		"$opt"
}

move_card() {
	local node="$1" item="$2" field="$3" option="$4"
	gh project item-edit --project-id "$node" --id "$item" \
		--field-id "$field" --single-select-option-id "$option" >/dev/null 2>&1
}

# _board_throttled
# True (exit 0) only when a FRESH, minimal `gh api graphql` probe itself comes back naming a rate
# limit — never inferred from a `gh project` porcelain failure's own text, which can read
# "unknown owner type" during the exact same throttle (dotfiles-dev#567). False (the probe
# succeeds, or fails for any other reason) is the safe default: an unconfirmed guess falls
# through to the GraphQL fallback read instead of halting on a maybe.
_board_throttled() {
	local probe
	probe="$(gh api graphql -f query='query{rateLimit{remaining}}' 2>&1)" && return 1
	printf '%s' "$probe" | grep -qiE 'rate.?limit'
}

# _board_item_list_graphql OWNER PROJECT
# One-shot `gh api graphql` read of a project's items, translated into the same `{"items": [...]}`
# shape `gh project item-list --format json` prints — id, content.{type,number,repository,url,body},
# and every other field (Status, "Blocked by", ...) as a top-level key named by lowercasing the
# field's own display name, exactly like the porcelain command already does. Downstream jq
# consumers in this file and roadmap_unblock.sh never need to know which channel answered.
#
# `repositoryOwner` is the schema's owner-TYPE-agnostic interface (works for a User or an
# Organization without knowing which up front) — the porcelain command's own "unknown owner type"
# failure is exactly the resolution step this sidesteps.
#
# ponytail: single page (first: 100), no cursor loop. A board past that many items comes back with
# `hasNextPage`, and this returns 1 (unreadable) rather than a silently partial list — add real
# pagination if a board ever grows past 100 items.
_board_item_list_graphql() {
	local owner="$1" project="$2" query result
	query='query($login:String!,$num:Int!){repositoryOwner(login:$login){... on ProjectV2Owner{projectV2(number:$num){items(first:100){pageInfo{hasNextPage}nodes{id content{__typename ... on Issue{number url body repository{nameWithOwner}}}fieldValues(first:20){nodes{__typename ... on ProjectV2ItemFieldSingleSelectValue{name field{... on ProjectV2FieldCommon{name}}} ... on ProjectV2ItemFieldTextValue{text field{... on ProjectV2FieldCommon{name}}}}}}}}}}}'
	result="$(gh api graphql -f query="$query" -f login="$owner" -F num="$project" 2>/dev/null)" || return 1
	printf '%s' "$result" | jq -e '.errors' >/dev/null 2>&1 && return 1
	printf '%s' "$result" \
		| jq -e '.data.repositoryOwner.projectV2.items.nodes | type == "array"' >/dev/null 2>&1 \
		|| return 1
	printf '%s' "$result" \
		| jq -e '.data.repositoryOwner.projectV2.items.pageInfo.hasNextPage == true' \
		>/dev/null 2>&1 && return 1
	printf '%s' "$result" | jq -c '
		.data.repositoryOwner.projectV2.items.nodes | {
			items: [.[] | {
				id: .id,
				content: (
					if .content.__typename == "Issue" then {
						type: "Issue", number: .content.number, url: .content.url,
						body: .content.body, repository: .content.repository.nameWithOwner
					} else { type: .content.__typename }
					end
				)
			} + (
				[.fieldValues.nodes[] | select(.field.name != null) |
					{(.field.name | ascii_downcase): (.name // .text)}] | add // {}
			)]
		}'
}

# _board_item_list OWNER PROJECT LIMIT
# Prints the `{"items": [...]}` JSON `gh project item-list` would, trying that porcelain command
# first. On failure, confirms whether GitHub's GraphQL API is presently throttled before deciding
# what to do next — a `gh project` failure whose text does not name a rate limit is not evidence
# that it is not one (dotfiles-dev#567) — and makes exactly ONE fallback attempt, never a retry
# loop.
# Returns 0 with JSON on stdout (either channel), 2 with nothing on stdout when throttling is
# CONFIRMED (report this distinctly — "try next round", not "the board is misconfigured"), or 1
# with nothing on stdout when neither channel can read the board.
_board_item_list() {
	local owner="$1" project="$2" limit="$3" json
	json="$(gh project item-list "$project" --owner "$owner" --format json --limit "$limit" 2>/dev/null)" \
		&& { printf '%s' "$json"; return 0; }

	_board_throttled && return 2

	json="$(_board_item_list_graphql "$owner" "$project")" || return 1
	printf '%s' "$json"
}

# _kr_status_names OWNER PROJECT
# Ordered list of Status column names, one per line, straight from the ARRAY `gh project
# field-list` returns. Arrays preserve order; this deliberately does not reconstruct order from
# an object (board_config's cached `.options` map), whose key order this file does not want to
# depend on.
#
# dotfiles-dev#567: on a porcelain failure that is NOT a confirmed throttle, falls back to one
# `gh api graphql` read of the same field/options (via the owner-agnostic `repositoryOwner`
# interface — see `_board_item_list_graphql`'s own comment).
# Returns 0 with the list on stdout, 2 (nothing on stdout) when a throttle is CONFIRMED, or 1
# (nothing on stdout) when neither channel can read the Status field.
_kr_status_names() {
	local owner="$1" project="$2" out query result
	out="$(gh project field-list "$project" --owner "$owner" --format json 2>/dev/null \
		| jq -r '.fields[] | select(.name=="Status") | .options[].name' 2>/dev/null)"
	if [[ -n "$out" ]]; then
		printf '%s\n' "$out"
		return 0
	fi

	_board_throttled && return 2

	query='query($login:String!,$num:Int!){repositoryOwner(login:$login){... on ProjectV2Owner{projectV2(number:$num){fields(first:50){nodes{... on ProjectV2SingleSelectField{name options{name}}}}}}}}'
	result="$(gh api graphql -f query="$query" -f login="$owner" -F num="$project" 2>/dev/null)" || return 1
	printf '%s' "$result" | jq -e '.errors' >/dev/null 2>&1 && return 1
	out="$(printf '%s' "$result" \
		| jq -r '.data.repositoryOwner.projectV2.fields.nodes[] | select(.name=="Status") | .options[].name' 2>/dev/null)"
	[[ -n "$out" ]] || return 1
	printf '%s\n' "$out"
}

# _kr_closing_issues OWNER REPO NUMBER
# Prints every OPEN issue this PR's closingIssuesReferences names, one per line, as
# "<nameWithOwner>\t<number>", or nothing if it names none. Returns 1 on any GraphQL error —
# the caller's per-PR fail-closed signal, so one bad PR read never aborts the whole round.
#
# The repository is carried, not discarded: closingIssuesReferences can name an issue in a
# DIFFERENT repository, and a project board can hold cards from several repositories, so
# matching a card on the issue number alone can select the wrong card and move it.
_kr_closing_issues() {
	local owner="$1" repo="$2" number="$3" query result
	query="{repository(owner:\"$owner\",name:\"$repo\"){pullRequest(number:$number){closingIssuesReferences(first:100){pageInfo{hasNextPage}nodes{number state repository{nameWithOwner}}}}}}"
	result="$(gh api graphql -f query="$query" 2>/dev/null)" || return 1
	printf '%s' "$result" | jq -e '.errors' >/dev/null 2>&1 && return 1
	# A truncated page would drop linked issues while the round still reported ok. Treat it as
	# this PR's own unknown rather than silently reconciling a subset.
	printf '%s' "$result" \
		| jq -e '.data.repository.pullRequest.closingIssuesReferences.pageInfo.hasNextPage == true' \
		>/dev/null 2>&1 && return 1
	printf '%s' "$result" \
		| jq -r '.data.repository.pullRequest.closingIssuesReferences.nodes[]
			| select(.state=="OPEN")
			| "\(.repository.nameWithOwner)\t\(.number)"' \
		2>/dev/null
}

reconcile_kanban() {
	local owner="$1" repo="$2"
	RECONCILE_KANBAN_STATUS="unknown"
	RECONCILE_KANBAN_REPORT=""

	local project_number project_node status_field target_option
	read -r project_number project_node status_field target_option \
		< <(board_config "$owner" "$repo" "In review") || {
		RECONCILE_KANBAN_REPORT="UNKNOWN: could not resolve board for $owner/$repo"
		return 1
	}
	if [[ "$project_number" == "AMBIGUOUS" ]]; then
		RECONCILE_KANBAN_REPORT="UNKNOWN: more than one \"$repo kanban\" board — refusing to guess"
		return 1
	fi
	if [[ -z "$project_number" || -z "$target_option" ]]; then
		RECONCILE_KANBAN_REPORT="UNKNOWN: no \"$repo kanban\" board or no In review column"
		return 1
	fi

	local order_list target_rank rc
	order_list="$(_kr_status_names "$owner" "$project_number")"; rc=$?
	if [[ -z "$order_list" ]]; then
		if (( rc == 2 )); then
			RECONCILE_KANBAN_REPORT="UNKNOWN (throttled): GitHub GraphQL rate limit — retry next round"
		else
			RECONCILE_KANBAN_REPORT="UNKNOWN (board unreadable): could not read Status column order for $owner/$repo"
		fi
		return 1
	fi
	target_rank="$(printf '%s\n' "$order_list" | grep -nxF "In review" | head -n1 | cut -d: -f1)"
	if [[ -z "$target_rank" ]]; then
		RECONCILE_KANBAN_REPORT="UNKNOWN: no In review column found for $owner/$repo"
		return 1
	fi

	# Both listings below are capped. A cap that is REACHED means the answer may be partial, and a
	# partial reconcile reported as `ok` is the failure this gate exists to avoid (the same
	# "usable answer, not just a clean exit" contract ai_clients/CLAUDE.md states) — so a
	# truncated read is reported as unknown instead of silently reconciling a subset.
	local pr_limit=200 item_limit=500

	local pr_numbers pr_count
	pr_numbers="$(gh pr list --repo "$owner/$repo" --state open --json number --limit "$pr_limit" \
		--jq '.[].number' 2>/dev/null)" || {
		RECONCILE_KANBAN_REPORT="UNKNOWN: could not list open PRs for $owner/$repo"
		return 1
	}
	pr_count="$(printf '%s\n' "$pr_numbers" | grep -c .)"
	if (( pr_count >= pr_limit )); then
		RECONCILE_KANBAN_REPORT="UNKNOWN: open-PR list hit the $pr_limit cap for $owner/$repo — result may be truncated"
		return 1
	fi

	local items_json item_count
	items_json="$(_board_item_list "$owner" "$project_number" "$item_limit")"; rc=$?
	if (( rc != 0 )); then
		if (( rc == 2 )); then
			RECONCILE_KANBAN_REPORT="UNKNOWN (throttled): GitHub GraphQL rate limit — retry next round"
		else
			RECONCILE_KANBAN_REPORT="UNKNOWN (board unreadable): could not read project items for $owner/$repo"
		fi
		return 1
	fi
	# Shape-check before use: `.items[]?` exits 0 on `{}`/`{"items": null}` too, which would
	# otherwise report ok having silently processed nothing (same trap PR #376 caught in
	# roadmap_unblock.sh).
	printf '%s' "$items_json" | jq -e 'type=="object" and (.items | type == "array")' \
		>/dev/null 2>&1 || {
		RECONCILE_KANBAN_REPORT="UNKNOWN (board unreadable): could not parse project items for $owner/$repo"
		return 1
	}
	item_count="$(printf '%s' "$items_json" | jq '.items | length' 2>/dev/null)"
	if [[ -n "$item_count" ]] && (( item_count >= item_limit )); then
		RECONCILE_KANBAN_REPORT="UNKNOWN: project item list hit the $item_limit cap for $owner/$repo — result may be truncated"
		return 1
	fi

	local report="" n processed=""
	while IFS= read -r n; do
		[[ -n "$n" ]] || continue
		local issues
		if ! issues="$(_kr_closing_issues "$owner" "$repo" "$n")"; then
			report="$(printf '%s\nUNKNOWN PR #%s: could not resolve closing issues' "$report" "$n")"
			continue
		fi
		local issue issue_repo issue_label
		while IFS=$'\t' read -r issue_repo issue; do
			[[ -n "$issue" ]] || continue
			# Several open PRs can close the same issue — process it once. The key carries the
			# repository, so issue #42 of another repo is never mistaken for this repo's #42.
			printf '%s\n' "$processed" | grep -qxF "$issue_repo#$issue" && continue
			processed="$(printf '%s\n%s' "$processed" "$issue_repo#$issue")"

			# Report same-repo issues as plain "#N" (what every caller and test expects) and
			# qualify only a cross-repo one, where the bare number would be ambiguous.
			issue_label="#$issue"
			[[ "$issue_repo" == "$owner/$repo" ]] || issue_label="$issue_repo#$issue"

			local item_id current_status rank
			item_id="$(printf '%s' "$items_json" | jq -r --argjson num "$issue" --arg nwo "$issue_repo" \
				'first(.items[] | select(.content.type=="Issue" and .content.number==$num and .content.repository==$nwo)) | .id // empty' 2>/dev/null)"
			[[ -n "$item_id" ]] || continue   # issue not on this board -> nothing to move

			current_status="$(printf '%s' "$items_json" | jq -r --argjson num "$issue" --arg nwo "$issue_repo" \
				'first(.items[] | select(.content.type=="Issue" and .content.number==$num and .content.repository==$nwo)) | .status // empty' 2>/dev/null)"

			[[ "$current_status" == "In review" ]] && continue

			rank="$(printf '%s\n' "$order_list" | grep -nxF "$current_status" | head -n1 | cut -d: -f1)"
			if [[ -n "$rank" ]] && (( rank >= target_rank )); then
				continue   # already at or beyond In review -> never move backwards
			fi

			if move_card "$project_node" "$item_id" "$status_field" "$target_option"; then
				report="$(printf '%s\nmoved issue %s to In review (was: %s, via PR #%s)' \
					"$report" "$issue_label" "${current_status:-none}" "$n")"
			else
				# A stale cached Status field / option id is the likely cause, and keeping it makes
				# every later round repeat the same failure. Refresh the board once and retry,
				# exactly as kanban_lifecycle.sh does on the event path.
				rm -f "$(cache_file "$owner" "$repo")"
				read -r project_number project_node status_field target_option \
					< <(board_config "$owner" "$repo" "In review") || true
				if [[ "$project_number" != "AMBIGUOUS" && -n "$project_node" && -n "$target_option" ]] \
					&& move_card "$project_node" "$item_id" "$status_field" "$target_option"; then
					report="$(printf '%s\nmoved issue %s to In review after a board-cache refresh (was: %s, via PR #%s)' \
						"$report" "$issue_label" "${current_status:-none}" "$n")"
				else
					report="$(printf '%s\nFAILED to move issue %s to In review (PR #%s) — verify by hand' \
						"$report" "$issue_label" "$n")"
				fi
			fi
		done <<<"$issues"
	done <<<"$pr_numbers"

	# shellcheck disable=SC2034 # read by callers after this returns, not within this file
	RECONCILE_KANBAN_STATUS="ok"
	# shellcheck disable=SC2034 # read by callers after this returns, not within this file
	RECONCILE_KANBAN_REPORT="$(printf '%s\n' "$report" | sed '/^$/d')"
	return 0
}
