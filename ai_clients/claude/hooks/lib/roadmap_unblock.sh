#!/bin/bash
# Shared roadmap-unblock reconcile (dotfiles-linux-dev#369): closes the gap where a board item's
# Status/label/"Blocked by" field do not follow the native issue-dependency relationship when the
# last blocker closes. GitHub resolves the native relationship
# (repos/<o>/<r>/issues/<n>/dependencies/blocked_by) on its own; nothing else does — the board
# Status stays Blocked, the `state:blocked` label stays, and the "Blocked by" text field goes
# stale (measured on the greenfield roadmap: an item still named a scaffold issue long after that
# issue had closed).
#
# Why a reconcile step, not an event trigger: blockers cross repositories (one project's item can
# be blocked by an issue in a different repo entirely), so an `issues: closed` workflow in one
# repo never sees the other repo's close event; and a `schedule:` workflow was separately measured
# firing 6 times in 21 hours on a quiet repo — GitHub throttles scheduled workflows hardest where
# they're needed most. An idempotent reconcile called once per `s:dev-loop` round has neither
# problem: it is one more read per round, on a trigger that already exists.
#
# Generic across projects: OWNER and PROJECT (number) are arguments — nothing board-specific
# (repo name, board id) is hardcoded. The `state:ready|blocked|deferred` label triad and the
# "Status"/"Blocked by" field names are the one convention this file assumes, per the issue spec.
#
# Contract:
#   reconcile_roadmap_unblock OWNER PROJECT
#     Sets two globals (never partial):
#       RECONCILE_STATUS = ok | unknown
#       RECONCILE_REPORT = newline-separated lines, one per item that changed OR needs a human
#                          look (still blocked, blocked by nothing, decision, unknown) — nothing
#                          is printed for an item left alone with no new information.
#     Returns 1 and sets RECONCILE_STATUS=unknown (RECONCILE_REPORT holding one explanatory line)
#     only when the BOARD ITSELF cannot be read (`gh project item-list` failure or unparseable
#     output). A single item's own read failure (`dependencies/blocked_by`) does not abort the
#     round — it is reported as an "UNKNOWN <item>" line and the next item is still processed.
#
# ⚠️ Fail closed on every read error: an item whose native-blocker read fails is reported UNKNOWN
# and left untouched. Reading a failure as "no blockers" would move the item the one direction
# that has no undo.
#
# ⚠️ A `decision:` blocker — the literal prefix, case-insensitive, recorded in the "Blocked by"
# project text field or the issue body's own "**Blocked by:**" line — is NEVER auto-cleared,
# closed native blockers or not. By definition only a person removes a decision blocker.
#
# dotfiles-linux-dev#416: a blocker recorded only as PROSE (the "Blocked by" field or the body's
# "**Blocked by:**" line naming `#N` / `owner/repo#N`) is invisible to GitHub's native
# `blocked_by` relation — nothing resolves it, so an item stays "still blocked" forever even
# after the named issue closes. When native `blocked_by` is empty, this file now parses issue
# references out of that same recorded text and reads each one's own state, as an ADDITIONAL
# source feeding the same three verdicts (unblocked / still blocked / UNKNOWN) — never a fourth
# path and never a weakening of the two rules above: a `decision:` blocker is checked first and
# always wins (this file never reaches the prose-ref resolution for one), and a failed state read
# is UNKNOWN, left untouched, same fail-closed contract as the native read.
#
# dotfiles-linux-dev#528: every report line for a determinate blocker now carries a `[blocker-kind: …]`
# tag — `internal` (same repo as the item), `external` (a different repo), or `decision` — so the
# board can colour-mark WHY an item is unpickable, not just THAT it is. Kind is decided purely by
# comparing the blocker's own repo to the item's repo, never by which code path (native API vs.
# prose parse) found it — see `_ru_refs_kind`.
#
# ⚠️ The asymmetry that makes this issue worth doing: an INTERNAL blocker is recorded in TWO
# independent places — GitHub's own `blocked_by` relationship graph (which this file reads via
# `_ru_native_blockers`) AND, usually, the issue body's prose line — so a wrong or missing prose
# line still self-heals from the native read. An EXTERNAL blocker has no such redundancy: GitHub's
# native dependency graph is scoped to the repo whose endpoint you query, so a cross-repo block
# can, in practice, only ever be recorded as PROSE (`_ru_prose_refs` + `_ru_ref_state`). The prose
# text is not one of two sources for an external blocker, it is the ONLY source — a typo or a
# deleted line loses the relationship entirely, with nothing else to fall back on. (The
# "cross-repo native blocker" bats case below is a defensive path — this file tolerates whatever
# repo a native entry happens to name — not a claim that GitHub's own UI offers cross-repo native
# linking.)
# dotfiles-linux-dev#567: `reconcile_roadmap_unblock`'s own project item read shared the same
# single-channel `gh project item-list` dependency as kanban_reconcile.sh's — two independent
# call sites, same defect. `_board_item_list` (throttle-confirm + one `gh api graphql` fallback)
# now lives in kanban_reconcile.sh, which already serves as this repo's shared board-helpers
# file (see its own header), and is sourced below rather than duplicated here.
set -u

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	echo "roadmap_unblock.sh is meant to be sourced, not executed." >&2
	exit 1
fi

# shellcheck source=kanban_reconcile.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/kanban_reconcile.sh"

_ru_is_decision() {
	# Case-insensitive "decision:" anywhere in the text — checked against both the project's
	# "Blocked by" text field and the issue body's own "**Blocked by:**" line, since either one
	# recording it makes this a decision blocker.
	printf '%s' "$1" | grep -qi 'decision:'
}

_ru_body_blocked_line() {
	# The issue body's own "**Blocked by:**" line, if present — a second place a blocker (decision
	# or otherwise) can be recorded besides the project's text field. `|| true`: grep's "no match"
	# exit status must never propagate as a failure of this always-succeeds helper.
	printf '%s' "$1" | grep -im1 '^\*\*Blocked by:\*\*' || true
}

# _ru_native_blockers REPO NUMBER
# Prints "state<TAB>owner/repo#number" one per line for every native blocker, or nothing if there
# are none. Returns 1 on any read/parse failure — the caller's fail-closed signal.
#
# ⚠️ `--paginate` is load-bearing, not tidiness: the endpoint returns 30 per page by default, and
# a single open blocker sitting on page 2 would be invisible while page 1 read all-closed — the
# caller would then unblock the item, the one direction with no undo (PR #376 review).
_ru_native_blockers() {
	local repo="$1" number="$2" json
	# The flag goes AFTER the endpoint so a fake `gh` matching on $2 still sees the path.
	json="$(gh api "repos/$repo/issues/$number/dependencies/blocked_by?per_page=100" \
		--paginate 2>/dev/null)" || return 1
	# -s: --paginate emits one array per page, so slurp before validating or reading.
	printf '%s' "$json" | jq -se 'length > 0 and all(type == "array")' >/dev/null 2>&1 || return 1
	printf '%s' "$json" | jq -sr '.[][] | "\(.state)\t\(.repository.full_name)#\(.number)"' 2>/dev/null
}

# _ru_prose_refs TEXT DEFAULT_REPO
# Prints every "#N" / "owner/repo#N" issue reference found in TEXT, one normalized
# "owner/repo#number" per line (deduplicated) — a bare "#N" is qualified with DEFAULT_REPO. Prints
# nothing when TEXT has no reference GitHub's own dependency graph would recognise.
_ru_prose_refs() {
	local text="$1" default_repo="$2" ref
	printf '%s' "$text" | grep -oE '([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+' | while IFS= read -r ref; do
		if [[ "$ref" == */* ]]; then
			printf '%s\n' "$ref"
		else
			printf '%s%s\n' "$default_repo" "$ref"
		fi
	done | sort -u
}

# _ru_ref_state REF (as "owner/repo#number")
# Prints the referenced issue's state, lowercased ("open"/"closed"). Returns 1 on any read
# failure — the caller's fail-closed signal, same contract as _ru_native_blockers.
_ru_ref_state() {
	local ref="$1" repo number state
	repo="${ref%#*}"
	number="${ref##*#}"
	state="$(gh issue view "$number" --repo "$repo" --json state --jq '.state' 2>/dev/null)" || return 1
	[[ -n "$state" ]] || return 1
	printf '%s\n' "${state,,}"
}

# _ru_refs_kind ITEM_REPO REFS
# REFS is a newline list of "owner/repo#number". Prints "internal" when every ref names
# ITEM_REPO, "external" the moment one names a different repo — kind is a property of the
# reference, not of which code path (native API or prose parse) found it. Prints nothing for
# an empty REFS (nothing to classify).
_ru_refs_kind() {
	local item_repo="$1" refs="$2" ref
	[[ -n "$refs" ]] || return 0
	while IFS= read -r ref; do
		[[ -n "$ref" ]] || continue
		if [[ "${ref%#*}" != "$item_repo" ]]; then
			printf 'external\n'
			return 0
		fi
	done <<<"$refs"
	printf 'internal\n'
}

# _ru_kind_tag KIND
# The report-line suffix for a determinate KIND, or nothing for an empty KIND (the
# "blocked by nothing" / UNKNOWN cases, where no blocker exists to classify).
_ru_kind_tag() {
	[[ -n "$1" ]] || return 0
	printf ' [blocker-kind: %s]' "$1"
}

# _ru_has_comment REPO NUMBER TEXT
# True when TEXT is already the body of a comment on the issue. A read failure counts as "absent":
# a duplicate audit comment is visible and harmless, a suppressed one is silent.
_ru_has_comment() {
	gh issue view "$2" --repo "$1" --json comments --jq '.comments[].body' 2>/dev/null \
		| grep -qxF "$3"
}

# _ru_unblock OWNER PROJECT REPO NUMBER URL DETAIL
# The one mutation path, in order: labels, board "Blocked by", audit comment, board Status LAST.
# The comment is the audit trail (dotfiles-linux-dev#369): a status that changes silently is
# indistinguishable from one someone fat-fingered.
#
# ⚠️ Status is the completion marker, so it writes last (PR #376 review). Writing it first is what
# makes a partial failure permanent: this function is only ever reached for a Status=Blocked item,
# so Status=Ready removes the item from every later round's candidate set — a failed "Blocked by"
# clear or a missing audit comment would then never be retried by anyone, and the stale field
# survives indefinitely. With Status last, any earlier failure leaves the item Blocked and the next
# round redoes the whole sequence, which is safe because every earlier write is retry-safe: the
# label swap is a no-op once applied, `--clear` on an empty field is a no-op, and the comment is
# skipped when its exact text is already on the issue.
#
# ponytail: still no rollback — the caller reports FAILED and the next round re-runs it.
_ru_unblock() {
	local owner="$1" project="$2" repo="$3" number="$4" url="$5" detail="$6"
	local note="Unblocked: $detail. Status set to Ready."
	gh issue edit "$number" --repo "$repo" \
		--add-label "state:ready" --remove-label "state:blocked" >/dev/null 2>&1 || return 1
	gh project item-edit "$project" --owner "$owner" --url "$url" \
		--field "Blocked by" --clear >/dev/null 2>&1 || return 1
	if ! _ru_has_comment "$repo" "$number" "$note"; then
		gh issue comment "$number" --repo "$repo" --body "$note" >/dev/null 2>&1 || return 1
	fi
	gh project item-edit "$project" --owner "$owner" --url "$url" \
		--field "Status" --value "Ready" >/dev/null 2>&1 || return 1
}

# _ru_process_item OWNER PROJECT ITEM_JSON
# Prints exactly one report line for a single Blocked item, and calls _ru_unblock when every
# native blocker is closed and no decision blocker is recorded.
_ru_process_item() {
	local owner="$1" project="$2" item="$3"
	local number repo url body field_text body_line ident
	number="$(jq -r '.content.number' <<<"$item")"
	repo="$(jq -r '.content.repository' <<<"$item")"
	url="$(jq -r '.content.url' <<<"$item")"
	body="$(jq -r '.content.body // ""' <<<"$item")"
	field_text="$(jq -r '."blocked by" // ""' <<<"$item")"
	ident="$repo#$number"
	body_line="$(_ru_body_blocked_line "$body")"

	local native native_rc=0
	native="$(_ru_native_blockers "$repo" "$number")" || native_rc=1
	if ((native_rc != 0)); then
		printf 'UNKNOWN %s: could not read native blockers — left untouched\n' "$ident"
		return 0
	fi

	if _ru_is_decision "$field_text" || _ru_is_decision "$body_line"; then
		printf 'decision blocker %s: %s — left untouched (only a person clears this)%s\n' \
			"$ident" "${field_text:-$body_line}" "$(_ru_kind_tag decision)"
		return 0
	fi

	if [[ -n "$native" ]]; then
		local open_list closed_list kind
		open_list="$(printf '%s\n' "$native" | awk -F'\t' '$1 != "closed" {print $2}')"
		closed_list="$(printf '%s\n' "$native" | awk -F'\t' '$1 == "closed" {print $2}')"
		kind="$(_ru_refs_kind "$repo" "$(printf '%s\n' "$native" | cut -f2)")"
		if [[ -z "$open_list" ]]; then
			local detail
			detail="$(printf '%s' "$closed_list" | paste -sd, -)"
			if _ru_unblock "$owner" "$project" "$repo" "$number" "$url" "$detail"; then
				printf 'unblocked %s: all native blockers closed (%s) -> Ready%s\n' \
					"$ident" "$detail" "$(_ru_kind_tag "$kind")"
			else
				printf 'FAILED to unblock %s: a gh write failed partway — verify by hand\n' "$ident"
			fi
		else
			printf 'still blocked %s: open native blocker(s) %s%s\n' \
				"$ident" "$(printf '%s' "$open_list" | paste -sd, -)" "$(_ru_kind_tag "$kind")"
		fi
		return 0
	fi

	if [[ -n "$field_text" || -n "$body_line" ]]; then
		local prose_text refs
		prose_text="$field_text"$'\n'"$body_line"
		refs="$(_ru_prose_refs "$prose_text" "$repo")"
		if [[ -z "$refs" ]]; then
			# No parseable "#N" reference in the recorded text — nothing to resolve.
			printf 'still blocked %s: recorded blocker %s\n' "$ident" "${field_text:-$body_line}"
			return 0
		fi

		local ref ref_state ref_rc=0 open_refs="" closed_refs=""
		while IFS= read -r ref; do
			[[ -n "$ref" ]] || continue
			ref_state="$(_ru_ref_state "$ref")" || { ref_rc=1; break; }
			if [[ "$ref_state" == "closed" ]]; then
				closed_refs="$(printf '%s\n%s' "$closed_refs" "$ref")"
			else
				open_refs="$(printf '%s\n%s' "$open_refs" "$ref")"
			fi
		done <<<"$refs"
		if ((ref_rc != 0)); then
			printf 'UNKNOWN %s: could not read prose blocker state — left untouched\n' "$ident"
			return 0
		fi
		open_refs="$(printf '%s\n' "$open_refs" | sed '/^$/d')"
		closed_refs="$(printf '%s\n' "$closed_refs" | sed '/^$/d')"

		local kind
		kind="$(_ru_refs_kind "$repo" "$refs")"
		if [[ -z "$open_refs" ]]; then
			local detail
			detail="$(printf '%s' "$closed_refs" | paste -sd, -)"
			if _ru_unblock "$owner" "$project" "$repo" "$number" "$url" "$detail"; then
				printf 'unblocked %s: prose blocker(s) closed (%s) -> Ready%s\n' \
					"$ident" "$detail" "$(_ru_kind_tag "$kind")"
			else
				printf 'FAILED to unblock %s: a gh write failed partway — verify by hand\n' "$ident"
			fi
		else
			printf 'still blocked %s: open prose blocker(s) %s%s\n' \
				"$ident" "$(printf '%s' "$open_refs" | paste -sd, -)" "$(_ru_kind_tag "$kind")"
		fi
		return 0
	fi

	printf 'blocked by nothing %s: Status=Blocked but no blocker recorded anywhere\n' "$ident"
}

reconcile_roadmap_unblock() {
	local owner="$1" project="$2"
	RECONCILE_STATUS="unknown"
	RECONCILE_REPORT=""

	local items_json blocked rc
	items_json="$(_board_item_list "$owner" "$project" 500)"; rc=$?
	if (( rc != 0 )); then
		if (( rc == 2 )); then
			RECONCILE_REPORT="UNKNOWN (throttled): GitHub GraphQL rate limit — retry next round"
		else
			RECONCILE_REPORT="UNKNOWN (board unreadable): could not read project $owner/$project"
		fi
		return 1
	fi
	# Shape-check before filtering: `.items[]?` exits 0 on `{}` and on `{"items": null}`, so
	# without this an unusable response would report ok having silently processed nothing —
	# indistinguishable from a board with no blocked items (PR #376 review).
	printf '%s' "$items_json" | jq -e 'type == "object" and (.items | type == "array")' \
		>/dev/null 2>&1 \
		|| { RECONCILE_REPORT="UNKNOWN (board unreadable): could not parse project $owner/$project"; return 1; }
	blocked="$(printf '%s' "$items_json" \
		| jq -c '.items[] | select(.status == "Blocked" and .content.type == "Issue")' 2>/dev/null)" \
		|| { RECONCILE_REPORT="UNKNOWN (board unreadable): could not parse project $owner/$project"; return 1; }

	local item line report=""
	while IFS= read -r item; do
		[[ -n "$item" ]] || continue
		line="$(_ru_process_item "$owner" "$project" "$item")"
		[[ -n "$line" ]] && report="$(printf '%s\n%s' "$report" "$line")"
	done <<<"$blocked"

	# shellcheck disable=SC2034 # read by callers after this returns, not within this file
	RECONCILE_STATUS="ok"
	# shellcheck disable=SC2034 # read by callers after this returns, not within this file
	RECONCILE_REPORT="$(printf '%s\n' "$report" | sed '/^$/d')"
	return 0
}

# dotfiles-linux-dev#531: the declared set of boards the reconciler sweeps — "owner|project|repo" per
# entry, the same shape as LESSON_STORES (lib/lesson_mirrors.sh). Before this, "every project this
# operator tracks" was session memory: a board nobody passed was indistinguishable from a board
# with nothing to unblock, since both report nothing.
#
# A board is absent BY DECLARATION, never by omission: stpstone (project 2) is excluded because
# its repo is no longer maintained. To add a board, add a row; to drop one, delete the row and say
# why here. `repo` is the board's own repo, used only to label its report line.
# shellcheck disable=SC2034 # read by reconcile_roadmap_boards below and by its callers' tests
ROADMAP_BOARDS=(
	"guilhermegor|17|greenfield"
	"guilhermegor|16|wwdates"
	"guilhermegor|15|filings-b3"
	"guilhermegor|13|dotfiles-linux-dev"
	"guilhermegor|9|filings-cvm"
	"guilhermegor|8|blueprintx"
)

# reconcile_roadmap_boards
#   Runs reconcile_roadmap_unblock over every ROADMAP_BOARDS entry. Sets:
#     RECONCILE_BOARDS_STATUS = ok | unknown   (unknown when ANY board — or the registry — is unreadable)
#     RECONCILE_BOARDS_REPORT = one "board OWNER/N (repo): ..." line per board, ALWAYS, plus that
#                               board's own item lines indented beneath it. A board that reconciled
#                               clean ("nothing to change") and one nobody swept (no line) must not
#                               look alike.
#   Returns 1 when RECONCILE_BOARDS_STATUS is unknown.
#
# ⚠️ Fail closed PER BOARD, never across the sweep: one unreadable board is reported UNKNOWN and the
# loop continues. An early `return 1` here would let a single permissions error silently cancel
# every other board's sweep. A malformed or empty registry is UNKNOWN too, never "nothing to do".
reconcile_roadmap_boards() {
	RECONCILE_BOARDS_STATUS="ok"
	RECONCILE_BOARDS_REPORT=""
	local lines="" entry owner project repo rc detail
	# Whole-entry shape, never per-field: `read` drops a trailing `|`, so
	# `owner|17|repo|` would split cleanly and pass a field-by-field check.
	local entry_shape='^[^|]+\|[0-9]+\|[^|]+$'
	if ((${#ROADMAP_BOARDS[@]} == 0)); then
		# shellcheck disable=SC2034 # read by callers
		RECONCILE_BOARDS_STATUS="unknown"
		# shellcheck disable=SC2034 # read by callers
		RECONCILE_BOARDS_REPORT="UNKNOWN: ROADMAP_BOARDS is empty — no board was swept"
		return 1
	fi
	for entry in "${ROADMAP_BOARDS[@]}"; do
		if [[ ! "$entry" =~ $entry_shape ]]; then
			RECONCILE_BOARDS_STATUS="unknown"
			lines+="board ${entry:-<empty>}: UNKNOWN — malformed registry entry (want owner|project|repo)"$'\n'
			continue
		fi
		IFS='|' read -r owner project repo <<<"$entry"
		rc=0
		reconcile_roadmap_unblock "$owner" "$project" || rc=$?
		if ((rc != 0)); then
			RECONCILE_BOARDS_STATUS="unknown"
			lines+="board $owner/$project ($repo): UNKNOWN — $RECONCILE_REPORT"$'\n'
		elif [[ -z "$RECONCILE_REPORT" ]]; then
			lines+="board $owner/$project ($repo): ok — nothing to change"$'\n'
		else
			lines+="board $owner/$project ($repo): ok — $(printf '%s\n' "$RECONCILE_REPORT" | wc -l) item line(s)"$'\n'
			while IFS= read -r detail; do
				lines+="  $detail"$'\n'
			done <<<"$RECONCILE_REPORT"
		fi
	done
	# shellcheck disable=SC2034 # read by callers
	RECONCILE_BOARDS_REPORT="$(printf '%s' "$lines" | sed '/^$/d')"
	[[ "$RECONCILE_BOARDS_STATUS" == "ok" ]]
}
