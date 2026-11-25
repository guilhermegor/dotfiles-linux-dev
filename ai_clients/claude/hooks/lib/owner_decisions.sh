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
#   od_report_remote REPO  branch_prune.sh REPORT-REMOTE branch names (dry-run) of REPO's own
#                          local checkout; rc 3 = no checkout, rc 1 = pass unreadable
#   od_issue_json REPO     open issues labelled hitl, or state:blocked by a decision
#   od_gate_pending REPO   open PRs waiting on an owner-only gate approval ("N<TAB>why"): they touch
#                          a path the repo's own workflow declares gate-protected and lack the
#                          `gate-change-approved` label, or a gate check failed on the
#                          GATE_CHANGE_OK refusal text (#1130)
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
# every ROADMAP_BOARDS entry as `<owner>/<repo>` (discovered at runtime, #1022); when discovery
# yields none, the cwd checkout's `origin` repo, with a report line saying so (#1059). Every scanned
# repo gets its REPORT-REMOTE pass (#1046); one with no local checkout is UNREADABLE, never silent.
#
# Standing exclusions come from a DATA file, never hardcoded numbers: OWNER_DECISIONS_EXCLUDE_FILE
# (default ~/.claude/tasks/owner-decisions-exclusions.txt), one ref per line — `owner/repo#N`,
# `#N` (any repo), `branch:<name>` (any repo), `branch:<owner/repo>:<name>` or
# `workflow:<owner/N>/<name>`; text after ` # ` is the reason.
#
# ⚠️ Routine loop actions (merge, release, dispatch) are never decisions: only the six sources
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

OD_GATE_LABEL='gate-change-approved'
OD_GATE_REFUSAL_RE='GATE_CHANGE_OK|gate-change-ok|gate-weakening change'

# The repo declares its gate-protected paths itself: the workflow step that honours the approval
# label lists them as `-e <path>` lines. Never a path list here. rc 0 with no output = the repo
# declares none; rc 1 = unreadable (a 404 on the workflows dir alone means no workflows).
_od_gate_paths() {
	local repo="$1" listing err wf body
	err="$(mktemp)" || return 1
	if ! listing="$(gh api "repos/$repo/contents/.github/workflows" --jq '.[].path' 2>"$err")"; then
		if grep -q 'HTTP 404' "$err"; then rm -f "$err"; return 0; fi
		rm -f "$err"
		return 1
	fi
	rm -f "$err"
	while IFS= read -r wf; do
		[[ "$wf" == *.yml || "$wf" == *.yaml ]] || continue
		body="$(gh api -H 'Accept: application/vnd.github.raw' "repos/$repo/contents/$wf" 2>/dev/null)" \
			|| return 1
		grep -qF -- "$OD_GATE_LABEL" <<<"$body" || continue
		sed -n 's/^[[:space:]]*-e \([^[:space:]\\]*\).*/\1/p' <<<"$body"
	done <<<"$listing"
}

od_gate_pending() {
	local repo="$1" json paths pr sha labelled files hit runs run text
	json="$(od_pr_json "$repo")" || return 1
	paths="$(_od_gate_paths "$repo")" || return 1
	while IFS=$'\t' read -r pr sha labelled; do
		[[ -n "$pr" ]] || continue
		hit=""
		if [[ "$labelled" != "true" && -n "$paths" ]]; then
			files="$(gh api --paginate "repos/$repo/pulls/$pr/files" \
				--jq '.[] | .filename, (.previous_filename // empty)' 2>/dev/null)" || return 1
			hit="$(grep -Fx -f <(printf '%s\n' "$paths") <<<"$files" | head -1)"
			[[ -n "$hit" ]] && hit="touches gate-protected $hit, lacks label $OD_GATE_LABEL"
		fi
		if [[ -z "$hit" ]]; then
			runs="$(gh api --paginate "repos/$repo/commits/$sha/check-runs" \
				--jq '.check_runs[] | select(.conclusion == "failure" and (.name | test("gate"; "i"))) | .id' \
				2>/dev/null)" || return 1
			while IFS= read -r run; do
				[[ -n "$run" ]] || continue
				text="$(gh api "repos/$repo/check-runs/$run/annotations" --jq '.[].message' 2>/dev/null)" \
					|| return 1
				if grep -qE -- "$OD_GATE_REFUSAL_RE" <<<"$text"; then
					hit="gate check failed on the GATE_CHANGE_OK refusal (override is terminal-only)"
					break
				fi
			done <<<"$runs"
		fi
		[[ -z "$hit" ]] || printf '%s\t%s\n' "$pr" "$hit"
	done < <(jq -r --arg l "$OD_GATE_LABEL" '.[] | select(.state == "open" and .merged_at == null)
		| [.number, .head.sha, (any(.labels[]?; .name == $l))] | @tsv' <<<"$json")
	return 0
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

od_report_remote() (
	local repo="$1" dir out
	# A GIT_DIR inherited from a hook or another repo's tooling would make every `git -C <dir>` in
	# the lookup and the prune pass read THAT repo, so the unset is scoped to this subshell.
	unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
		GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_PREFIX
	# The repo's own checkout (cwd when its origin matches, else $KANBAN_CHECKOUT_ROOT/<repo>,
	# the lookup the kanban reconcile uses): rc 3 = none, never a guess at another repo's clone.
	dir="$(_kb_checkout "${repo%%/*}" "${repo#*/}" "${OD_REPO_DIR:-$PWD}")" || return 3
	# 0 = dry-run (prune_branches <repo> <apply 0|1>); rc 2 means the pass could not read the repo.
	out="$(prune_branches "$dir" 0 2>/dev/null)" || return 1
	sed -n 's/^REPORT-REMOTE \([^:]*\):.*/\1/p' <<<"$out"
)

# Cells are single-line and pipe-free so a row can never break the table. The cap is a bash
# substring, which counts characters (not bytes, as `cut -c` does) under a UTF-8 locale.
_od_cell() {
	local s="${1//[$'\t\n|']/ }"
	printf '%s' "${s:0:200}"
}

# One TSV row per candidate: kind<TAB>ref<TAB>decision<TAB>context
_od_rows() {
	local repo json line rc why
	local -a repos
	# Boards are discovered, never listed (#1022); a failed or partial discovery is reported, not
	# read as "no repos". Runs here (not in a subshell per source) so the result is shared.
	if ! discover_roadmap_boards "$PWD"; then
		printf 'unreadable\t-\tboard discovery (%s)\t\n' "${ROADMAP_BOARDS_ERROR:-failed}"
	fi
	while IFS= read -r line; do
		[[ "$line" == *UNKNOWN* ]] && printf 'unreadable\t-\t%s\t\n' "$line"
	done <<<"${ROADMAP_BOARDS_REPORT:-}"
	if [[ -n "${OWNER_DECISIONS_REPOS:-}" ]]; then
		read -ra repos <<<"$OWNER_DECISIONS_REPOS"
	elif ((${#ROADMAP_BOARDS[@]})); then
		read -ra repos <<<"$(printf '%s\n' "${ROADMAP_BOARDS[@]}" | awk -F'|' '!seen[$1"/"$3]++ {print $1"/"$3}' | tr '\n' ' ')"
	else
		# Empty discovery (a failed read, #1059): never scan "/"; fall back to this checkout's origin.
		# _kb_origin_slug accepts only a github.com origin and strips a trailing "/" and ".git";
		# the GIT_* unset (subshell-scoped, as in od_report_remote) keeps it on the cwd checkout.
		line="$(
			unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
				GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_PREFIX
			_kb_origin_slug "$PWD"
		)"
		repos=()
		[[ "$line" == */* ]] && repos=("$line")
		printf 'unreadable\t-\tno boards discovered; fallback to cwd origin repo (%s)\t\n' "${line:-none}"
	fi
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
		if line="$(od_gate_pending "$repo")"; then
			awk -F'\t' -v repo="$repo" 'NF >= 2 {printf "gate\t%s#%s\tApprove gate change on PR %s#%s\t%s\n", repo, $1, repo, $1, $2}' <<<"$line"
		else
			printf 'unreadable\t-\tgate approvals of %s\t\n' "$repo"
		fi
		rc=0
		line="$(od_report_remote "$repo")" || rc=$?
		if ((rc == 0)); then
			awk -v repo="$repo" 'NF {printf "branch\tbranch:%s:%s\tKeep or delete origin branch %s of %s?\tcontent missing from the default branch (REPORT-REMOTE)\n", repo, $0, $0, repo}' <<<"$line"
		else
			why=""
			((rc == 3)) && why=" (no local checkout)"
			printf 'unreadable\t-\tREPORT-REMOTE branches of %s%s\t\n' "$repo" "$why"
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
		pr | issue | card | gate) grep -qxF -- "#${ref##*#}" <<<"$excl" && continue ;;
		# A ref is `branch:<owner/repo>:<name>` (git forbids ':' in a branch name); a bare
		# `branch:<name>` entry hides that name in every repo.
		branch) grep -qxF -- "branch:${ref#branch:*:}" <<<"$excl" && continue ;;
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
	gate) printf 'Add the gate-change-approved label, or re-run the commit with GATE_CHANGE_OK in a terminal\tPro: unblocks a gate-file PR only you may approve. Con: approves an edit to the gate itself\n' ;;
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
