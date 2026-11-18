#!/bin/bash
# Owner-decision collector (dotfiles-linux-dev#1033): answers "what is pending from a decision of
# mine?" FROM DATA, never from the orchestrator's recall. Backs the s:owner-decisions skill.
#
# Usage:  owner_decisions.sh            (executed: prints the table)
#         source owner_decisions.sh     (tests: override the od_* provider seams, call
#                                        owner_decisions_collect)
#
# Sources, one provider seam each (tests replace them with fixtures, nothing here is a live call
# once overridden):
#   od_pr_json REPO        open PRs whose body flags a judgement call
#   od_board_report        Blocked cards whose blocker is `decision:` ("owner/repo#N<TAB>text")
#   od_workflows_off       GitHub Projects workflows reported OFF ("owner/N<TAB>name")
#   od_report_remote       branch_prune.sh REPORT-REMOTE branch names (dry-run, one repo:
#                          OD_REPO_DIR, default $PWD)
#   od_issue_json REPO     open issues labelled hitl, or state:blocked by a decision
#
# Every provider returns non-zero when its read fails; the row then becomes
# `UNREADABLE (not "none")`, never an empty source. A provider must capture `gh`'s own status
# before piping: in a pipeline the exit status is the LAST command's, and `jq -s` on empty input
# still prints `[]` with status 0 (PR #1045 review).
#
# ⚠️ READ-ONLY. The board source reads items with `_board_item_list` and judges them with
# roadmap_unblock.sh's pure helpers; it never calls `reconcile_roadmap_boards`, which moves
# cards. Asking "what is pending on me?" must not change a board.
#
# OWNER_DECISIONS_REPOS overrides the scanned repos (space-separated `owner/repo`); the default is
# every ROADMAP_BOARDS entry as `<owner>/<repo>`.
#
# Standing exclusions come from a DATA file, never hardcoded numbers: OWNER_DECISIONS_EXCLUDE_FILE
# (default ~/.claude/tasks/owner-decisions-exclusions.txt), one ref per line — `owner/repo#N`,
# `#N` (any repo), `branch:<name>` or `workflow:<owner/N>/<name>`; text after ` # ` is the reason.
#
# ⚠️ Routine loop actions (merge, release, dispatch) are never decisions: only the five sources
# above produce rows, and none of them keys on a merge/release/dispatch event.
set -u

_OD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=roadmap_unblock.sh
source "$_OD_DIR/roadmap_unblock.sh"
# shellcheck source=worktree_prune.sh
source "$_OD_DIR/worktree_prune.sh"

OD_FLAG_RE='decide whether|surface expansion|expands? the (public )?surface|disabled feature|feature (is )?disabled|judge?ment call'

od_pr_json() {
	local raw
	raw="$(gh api --paginate "repos/$1/pulls?state=open&per_page=100" 2>/dev/null)" || return 1
	jq -s 'add // []' <<<"$raw"
}

od_issue_json() {
	local label raw all=""
	for label in hitl state:blocked; do
		raw="$(gh api --paginate "repos/$1/issues?state=open&labels=$label&per_page=100" 2>/dev/null)" \
			|| return 1
		all+="$raw"$'\n'
	done
	jq -s 'add // [] | unique_by(.number)' <<<"$all"
}

od_board_report() {
	local entry owner project repo json items item field body_line
	for entry in "${ROADMAP_BOARDS[@]}"; do
		IFS='|' read -r owner project repo <<<"$entry"
		json="$(_board_item_list "$owner" "$project" 500 2>/dev/null)" || return 1
		items="$(jq -c '.items | if type == "array" then .[] else error end
			| select(.status == "Blocked" and .content.type == "Issue")' <<<"$json" 2>/dev/null)" \
			|| return 1
		while IFS= read -r item; do
			[[ -n "$item" ]] || continue
			field="$(jq -r '."blocked by" // ""' <<<"$item")"
			body_line="$(_ru_body_blocked_line "$(jq -r '.content.body // ""' <<<"$item")")"
			if _ru_is_decision "$field" || _ru_is_decision "$body_line"; then
				jq -r --arg t "${field:-$body_line}" '"\(.content.repository)#\(.content.number)\t\($t)"' <<<"$item"
			fi
		done <<<"$items"
	done
}

od_workflows_off() {
	local entry owner project raw
	for entry in "${ROADMAP_BOARDS[@]}"; do
		IFS='|' read -r owner project _ <<<"$entry"
		# shellcheck disable=SC2016 # $o/$n are GraphQL variables
		raw="$(gh api graphql -f query='query($o:String!,$n:Int!){user(login:$o){projectV2(number:$n){workflows(first:50){nodes{name enabled}}}}}' \
			-F o="$owner" -F n="$project" 2>/dev/null)" || return 1
		# A null user/project (an org-owned board, a renamed one) is unreadable, never "none OFF".
		jq -r --arg b "$owner/$project" '.data.user.projectV2.workflows.nodes
			| if type == "array" then .[] else error end
			| select(.enabled == false) | "\($b)\t\(.name)"' <<<"$raw" 2>/dev/null || return 1
	done
}

od_report_remote() {
	local out
	# 0 = dry-run (prune_branches <repo> <apply 0|1>); rc 2 means the pass could not read the repo.
	out="$(prune_branches "${OD_REPO_DIR:-$PWD}" 0 2>/dev/null)" || return 1
	sed -n 's/^REPORT-REMOTE \([^:]*\):.*/\1/p' <<<"$out"
}

# Cells are single-line and pipe-free so a row can never break the table. The cap is a bash
# substring, which counts characters (not bytes, as `cut -c` does) under a UTF-8 locale.
_od_cell() {
	local s="${1//[$'\t\n|']/ }"
	printf '%s' "${s:0:200}"
}

# One TSV row per candidate: kind<TAB>ref<TAB>decision<TAB>context
_od_rows() {
	local repo json line
	local -a repos
	read -ra repos <<<"${OWNER_DECISIONS_REPOS:-$(printf '%s\n' "${ROADMAP_BOARDS[@]}" | awk -F'|' '!seen[$1"/"$3]++ {print $1"/"$3}' | tr '\n' ' ')}"
	for repo in "${repos[@]}"; do
		if json="$(od_pr_json "$repo")" && jq -e 'type == "array"' <<<"$json" >/dev/null 2>&1; then
			jq -r --arg repo "$repo" --arg re "$OD_FLAG_RE" '.[]
				| select(.state == "open" and .merged_at == null)
				| select((.body // "") | test($re; "i"))
				| [ "pr", "\($repo)#\(.number)", "Decide on PR: \(.title)",
				    ((.body | split("\n") | map(select(test($re; "i"))) | .[0]) // "") ] | @tsv' <<<"$json"
		else
			printf 'unreadable\t-\topen PRs of %s\t\n' "$repo"
		fi
		if json="$(od_issue_json "$repo")" && jq -e 'type == "array"' <<<"$json" >/dev/null 2>&1; then
			jq -r --arg repo "$repo" '.[] | select(.pull_request == null)
				| select(any(.labels[]?; .name == "hitl")
					or (any(.labels[]?; .name == "state:blocked")
						and ((.body // "") | test("\\*\\*Blocked by:\\*\\*[^\n]*decision:"; "i"))))
				| [ "issue", "\($repo)#\(.number)", "Decide on issue: \(.title)",
				    (if any(.labels[]?; .name == "hitl") then "labelled hitl" else "state:blocked by a decision" end) ] | @tsv' <<<"$json"
		else
			printf 'unreadable\t-\towner-decision issues of %s\t\n' "$repo"
		fi
	done
	if line="$(od_board_report)"; then
		awk -F'\t' 'NF >= 2 {printf "card\t%s\tDecide on blocked card %s\t%s\n", $1, $1, $2}' <<<"$line"
	else
		printf 'unreadable\t-\tboard decision blockers\t\n'
	fi
	if line="$(od_workflows_off)"; then
		awk -F'\t' 'NF >= 2 {printf "workflow\tworkflow:%s/%s\tEnable Projects workflow \"%s\" on board %s?\tReported OFF; the API cannot enable it\n", $1, $2, $2, $1}' <<<"$line"
	else
		printf 'unreadable\t-\tProjects workflows\t\n'
	fi
	if line="$(od_report_remote)"; then
		awk 'NF {printf "branch\tbranch:%s\tKeep or delete origin branch %s?\tcontent missing from the default branch (REPORT-REMOTE)\n", $0, $0}' <<<"$line"
	else
		printf 'unreadable\t-\tREPORT-REMOTE branches\t\n'
	fi
}

# Reads rows on stdin; drops any whose ref is in the exclusions file, and any ref already listed
# (an issue blocked by a decision is also a decision-blocked card: the first row wins).
_od_filter_excluded() {
	local file="${OWNER_DECISIONS_EXCLUDE_FILE:-$HOME/.claude/tasks/owner-decisions-exclusions.txt}"
	local kind ref decision context excl=""
	local -A seen=()
	[[ -r "$file" ]] && excl="$(sed -e 's/[[:space:]]#[[:space:]].*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^#\([[:space:]]\|$\)/d' -e '/^$/d' "$file")"
	while IFS=$'\t' read -r kind ref decision context; do
		[[ -n "$ref" && -z "${seen[$ref]:-}" ]] || continue
		seen[$ref]=1
		grep -qxF -- "$ref" <<<"$excl" && continue
		# `#N` names an issue/PR number, so it never matches a branch or workflow ref.
		case "$kind" in
		pr | issue | card) grep -qxF -- "#${ref##*#}" <<<"$excl" && continue ;;
		esac
		printf '%s\t%s\t%s\t%s\n' "$kind" "$ref" "$decision" "$context"
	done
}

# kind -> "suggestion<TAB>pros/cons"
_od_advice() {
	case "$1" in
	pr) printf 'Read the flagged note, then approve or amend before merge\tPro: unblocks the PR with your intent. Con: merging as-is bakes in the agent guess\n' ;;
	card) printf 'Record the answer on the card and drop the decision: blocker\tPro: card becomes pickable. Con: decision then binds later work\n' ;;
	workflow) printf 'Switch it on in the Projects UI if the automation is wanted\tPro: board stays in sync without the loop. Con: one more automation to watch\n' ;;
	branch) printf 'Delete if the missing lines are superseded, else open a PR\tPro: removes dead branch. Con: deleting loses unmerged work\n' ;;
	issue) printf 'Answer on the issue and relabel it\tPro: frees the item for dispatch. Con: a wrong answer is re-work\n' ;;
	esac
}

owner_decisions_collect() {
	local kind ref decision context sugg proscons u all rows unreadable
	all="$(_od_rows)"
	unreadable="$(awk -F'\t' '$1 == "unreadable" {print $3}' <<<"$all")"
	rows="$(grep -v '^unreadable' <<<"$all" | _od_filter_excluded)"
	if [[ -n "$rows" ]]; then
		printf '| Decision | Context | Suggestion | Pros/Cons |\n|---|---|---|---|\n'
		while IFS=$'\t' read -r kind ref decision context; do
			IFS=$'\t' read -r sugg proscons <<<"$(_od_advice "$kind")"
			printf '| %s (%s) | %s | %s | %s |\n' "$(_od_cell "$decision")" "$(_od_cell "$ref")" \
				"$(_od_cell "$context")" "$(_od_cell "$sugg")" "$(_od_cell "$proscons")"
		done <<<"$rows"
	else
		echo "No pending owner decisions."
	fi
	while IFS= read -r u; do
		if [[ -n "$u" ]]; then printf 'UNREADABLE (not "none"): %s\n' "$u"; fi
	done <<<"$unreadable"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	owner_decisions_collect
fi
