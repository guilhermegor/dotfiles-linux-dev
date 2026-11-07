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
# Contract (two directions: Blocked unblocks; Ready with an open blocker re-blocks, #812):
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
# shellcheck source=issue_spec_complete.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/issue_spec_complete.sh"

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

# _ru_origin_names_repo ROOT REPO
# True when checkout ROOT's `origin` is github.com's REPO (https or ssh, `.git` optional), compared
# as lowercase literals: GitHub names are case-insensitive and a `.` in one is not a wildcard.
_ru_origin_names_repo() {
	local url
	url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
	url="${url#*github.com[:/]}"
	url="${url%/}"
	url="${url%.git}"
	[[ -n "$url" && "${url,,}" == "${2,,}" ]]
}

# _ru_unblock_dest REPO ITEM_JSON
# Decides where an unblocked card goes (dotfiles-linux-dev#931): Ready when its body is a complete
# spec (issue_spec_complete.sh, shared with issue_template_guard.sh), Backlog otherwise. Sets
# UNBLOCK_DEST, UNBLOCK_WHY (what is missing, "" when complete) and UNBLOCK_LABELS. Returns 1 for
# UNKNOWN, never "complete": no `body` key at all (a present-but-null body is readable and empty,
# so it routes to Backlog), unreadable labels, or no verified template source.
#
# Templates are read at an EXPLICIT ref, `origin/HEAD` of the local checkout
# (`$ROADMAP_CHECKOUT_ROOT/<name>`, default ~/github/<name>), never its working tree, which may sit
# on a stale feature branch (same implicit-HEAD class as #229/#410). The checkout must exist, its
# origin must name REPO, and `origin/HEAD` must resolve; its freshness is that of the last fetch
# (no network call here). The `What / Why` skeleton is the fallback only when that ref ships no
# template. Labels (minus `state:blocked`, which the unblock removes) feed `if-label` rules.
_ru_unblock_dest() {
	local repo="$1" item="$2" body reasons root labels number tdir file
	local -a templates=()
	UNBLOCK_DEST="" UNBLOCK_WHY="" UNBLOCK_LABELS=""
	jq -e '.content | has("body")' <<<"$item" >/dev/null 2>&1 || return 1
	body="$(jq -r '.content.body // ""' <<<"$item")"
	number="$(jq -r '.content.number' <<<"$item")"
	root="${ROADMAP_CHECKOUT_ROOT:-$HOME/github}/${repo##*/}"
	_ru_origin_names_repo "$root" "$repo" || return 1
	git -C "$root" rev-parse --verify -q origin/HEAD >/dev/null 2>&1 || return 1
	tdir="$(mktemp -d)"
	while IFS= read -r file; do
		[[ "${file,,}" == *.md ]] || continue
		git -C "$root" show "origin/HEAD:$file" >"$tdir/$(basename "$file")" 2>/dev/null \
			|| { rm -rf "$tdir"; return 1; }
		templates+=("$tdir/$(basename "$file")")
	done < <(git -C "$root" ls-tree --name-only origin/HEAD .github/ISSUE_TEMPLATE/ 2>/dev/null | sort)
	labels="$(_ru_item_labels "$item" "$repo" "$number")" || { rm -rf "$tdir"; return 1; }
	UNBLOCK_LABELS="$labels"
	labels="$(grep -vxF 'state:blocked' <<<"$labels" || true)"
	reasons="$(SPEC_LABELS="$labels" spec_incomplete_reasons "$body" "${templates[@]+"${templates[@]}"}")"
	rm -rf "$tdir"
	if [[ -z "$reasons" ]]; then
		UNBLOCK_DEST="Ready"
		return 0
	fi
	UNBLOCK_DEST="Backlog"
	UNBLOCK_WHY="$(printf '%s\n' "$reasons" | awk 'NR > 1 { printf ", " } { printf "%s", $0 }')"
}

# _ru_dest_phrase
# The report-line tail for the destination decided by _ru_unblock_dest.
_ru_dest_phrase() {
	if [[ "$UNBLOCK_DEST" == "Ready" ]]; then
		printf 'Ready'
	else
		printf 'Backlog (%s)' "$UNBLOCK_WHY"
	fi
}

# _ru_unblock OWNER PROJECT REPO NUMBER URL DETAIL DEST
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
	local owner="$1" project="$2" repo="$3" number="$4" url="$5" detail="$6" dest="${7:-Ready}"
	local note="Unblocked: $detail. Status set to $dest."
	local -a label_args=(--remove-label "state:blocked")
	if [[ "$dest" == "Ready" ]]; then
		label_args=(--add-label "state:ready" "${label_args[@]}")
	elif grep -qxF 'state:ready' <<<"${UNBLOCK_LABELS:-}"; then
		# An incomplete spec must not advertise readiness. Only when the label is on the issue:
		# removing one that is absent may error and fail the whole write.
		label_args+=(--remove-label "state:ready")
	fi
	gh issue edit "$number" --repo "$repo" "${label_args[@]}" >/dev/null 2>&1 || return 1
	gh project item-edit "$project" --owner "$owner" --url "$url" \
		--field "Blocked by" --clear >/dev/null 2>&1 || return 1
	if ! _ru_has_comment "$repo" "$number" "$note"; then
		gh issue comment "$number" --repo "$repo" --body "$note" >/dev/null 2>&1 || return 1
	fi
	gh project item-edit "$project" --owner "$owner" --url "$url" \
		--field "Status" --value "$dest" >/dev/null 2>&1 || return 1
}

# _ru_write_failed_line VERB IDENT
# One report line for a write that failed partway. #921: under a confirmed GraphQL throttle say
# SKIPPED, not FAILED, since the throttle is the likely cause. Still ask for a hand check if it stays
# wrong: the probe doesn't prove why the write failed, and a retry doesn't repair every partial state
# (a cleared "Blocked by" reads as "blocked by nothing"; a re-block whose blocker closes keeps its label).
_ru_write_failed_line() {
	if _board_throttled; then
		printf 'SKIPPED %s %s: GraphQL rate-limited — retry next round; partial write possible, verify by hand\n' "$1" "$2"
		return 0
	fi
	printf 'FAILED to %s %s: a gh write failed partway — verify by hand\n' "$1" "$2"
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
			if ! _ru_unblock_dest "$repo" "$item"; then
				printf 'UNKNOWN %s: could not read the issue body or the repo template checkout to judge the spec — left untouched\n' "$ident"
			elif _ru_unblock "$owner" "$project" "$repo" "$number" "$url" "$detail" "$UNBLOCK_DEST"; then
				printf 'unblocked %s: all native blockers closed (%s) -> %s%s\n' \
					"$ident" "$detail" "$(_ru_dest_phrase)" "$(_ru_kind_tag "$kind")"
			else
				_ru_write_failed_line unblock "$ident"
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
			if ! _ru_unblock_dest "$repo" "$item"; then
				printf 'UNKNOWN %s: could not read the issue body or the repo template checkout to judge the spec — left untouched\n' "$ident"
			elif _ru_unblock "$owner" "$project" "$repo" "$number" "$url" "$detail" "$UNBLOCK_DEST"; then
				printf 'unblocked %s: prose blocker(s) closed (%s) -> %s%s\n' \
					"$ident" "$detail" "$(_ru_dest_phrase)" "$(_ru_kind_tag "$kind")"
			else
				_ru_write_failed_line unblock "$ident"
			fi
		else
			printf 'still blocked %s: open prose blocker(s) %s%s\n' \
				"$ident" "$(printf '%s' "$open_refs" | paste -sd, -)" "$(_ru_kind_tag "$kind")"
		fi
		return 0
	fi

	printf 'blocked by nothing %s: Status=Blocked but no blocker recorded anywhere\n' "$ident"
}

# _ru_open_blockers REPO NUMBER FIELD_TEXT BODY_LINE
# Prints every OPEN blocker ("owner/repo#number", one per line) of an item, or nothing when none
# is open. Native `blocked_by` wins; the prose refs are read only when the native relation is
# empty (same precedence as `_ru_process_item`). Returns 1 on ANY read failure — the caller's
# UNKNOWN signal, never "no blockers".
_ru_open_blockers() {
	local repo="$1" number="$2" field_text="$3" body_line="$4"
	local native refs ref state
	native="$(_ru_native_blockers "$repo" "$number")" || return 1
	if [[ -n "$native" ]]; then
		printf '%s\n' "$native" | awk -F'\t' '$1 != "closed" {print $2}'
		return 0
	fi
	refs="$(_ru_prose_refs "$field_text"$'\n'"$body_line" "$repo")"
	while IFS= read -r ref; do
		[[ -n "$ref" && "$ref" != "$repo#$number" ]] || continue
		state="$(_ru_ref_state "$ref")" || return 1
		[[ "$state" == "closed" ]] || printf '%s\n' "$ref"
	done <<<"$refs"
}

# _ru_reblock OWNER PROJECT REPO NUMBER URL DETAIL
# The mirror of `_ru_unblock` (dotfiles-linux-dev#812): labels, board "Blocked by", audit comment,
# board Status LAST — same ordering argument. Status is the completion marker, so any earlier
# failure leaves the item in its Ready column, in the candidate set, and the next round
# redoes the whole (retry-safe) sequence.
_ru_reblock() {
	local owner="$1" project="$2" repo="$3" number="$4" url="$5" detail="$6"
	local note="Blocked: open blocker(s) $detail. Status set to Blocked."
	gh issue edit "$number" --repo "$repo" \
		--add-label "state:blocked" --remove-label "state:ready" >/dev/null 2>&1 || return 1
	gh project item-edit "$project" --owner "$owner" --url "$url" \
		--field "Blocked by" --text "$detail" >/dev/null 2>&1 || return 1
	if ! _ru_has_comment "$repo" "$number" "$note"; then
		gh issue comment "$number" --repo "$repo" --body "$note" >/dev/null 2>&1 || return 1
	fi
	gh project item-edit "$project" --owner "$owner" --url "$url" \
		--field "Status" --value "Blocked" >/dev/null 2>&1 || return 1
}

# _ru_item_labels ITEM_JSON REPO NUMBER
# Prints the issue's labels, one per line. The porcelain read carries `labels`; the GraphQL
# fallback read does not, so a missing key is read from the issue. Returns 1 when unreadable.
_ru_item_labels() {
	if jq -e 'has("labels")' <<<"$1" >/dev/null 2>&1; then
		jq -r '(.labels // [])[] | if type == "object" then .name else . end' <<<"$1" 2>/dev/null
		return 0
	fi
	gh issue view "$3" --repo "$2" --json labels --jq '.labels[].name' 2>/dev/null
}

# _ru_process_open_item OWNER PROJECT ITEM_JSON
# The reverse direction (dotfiles-linux-dev#812) for an item in Ready, and (#931) in Backlog, where
# it prints `blocked:` instead of `re-blocked:`. A Backlog card's way back is _ru_unblock_dest, so
# moving it is no longer a one-way promotion to Ready. A Backlog card carrying the `state:blocked`
# label with no open blocker is also moved (detail `state:blocked`). Prints one line
# only when something happened or could not be read: a (re-)block, FAILED, or UNKNOWN. An item
# with no open blocker (none recorded, or all closed) is left alone silently — it is where it
# should be. A `decision:` blocker is left alone too: this direction only acts on a blocker it
# can verify as open.
_ru_process_open_item() {
	local owner="$1" project="$2" item="$3"
	local number repo url body field_text body_line ident open rc=0 status verb="re-blocked"
	status="$(jq -r '.status // ""' <<<"$item")"
	[[ "$status" != "Backlog" ]] || verb="blocked"
	number="$(jq -r '.content.number' <<<"$item")"
	repo="$(jq -r '.content.repository' <<<"$item")"
	url="$(jq -r '.content.url' <<<"$item")"
	body="$(jq -r '.content.body // ""' <<<"$item")"
	field_text="$(jq -r '."blocked by" // ""' <<<"$item")"
	ident="$repo#$number"
	body_line="$(_ru_body_blocked_line "$body")"
	# A body-only `decision:` blocker would be invisible without the body: unreadable is UNKNOWN.
	if ! jq -e '.content | has("body")' <<<"$item" >/dev/null 2>&1; then
		printf 'UNKNOWN %s: could not read the issue body — left untouched\n' "$ident"
		return 0
	fi

	if _ru_is_decision "$field_text" || _ru_is_decision "$body_line"; then
		return 0
	fi

	open="$(_ru_open_blockers "$repo" "$number" "$field_text" "$body_line")" || rc=1
	if ((rc != 0)); then
		printf 'UNKNOWN %s: could not read blockers — left untouched\n' "$ident"
		return 0
	fi
	local detail kind=""
	if [[ -n "$open" ]]; then
		detail="$(printf '%s' "$open" | paste -sd, -)"
		kind="$(_ru_refs_kind "$repo" "$open")"
	elif [[ "$status" == "Backlog" ]]; then
		local labels lrc=0
		labels="$(_ru_item_labels "$item" "$repo" "$number")" || lrc=1
		if ((lrc != 0)); then
			printf 'UNKNOWN %s: could not read labels — left untouched\n' "$ident"
			return 0
		fi
		grep -qxF 'state:blocked' <<<"$labels" || return 0
		detail="state:blocked"
	else
		return 0
	fi
	if _ru_reblock "$owner" "$project" "$repo" "$number" "$url" "$detail"; then
		printf '%s: %s by %s%s\n' "$verb" "$ident" "$detail" "$(_ru_kind_tag "$kind")"
	else
		_ru_write_failed_line "${verb%ed}" "$ident"
	fi
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
		elif (( rc == 3 )); then
			RECONCILE_REPORT="UNKNOWN: project item list hit the 500 cap for $owner/$project — result may be truncated"
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

	# The reverse direction (#812, Backlog added in #931): a Ready or Backlog card that gained an open blocker. Backlog is safe to scan now that unblocking picks Ready or Backlog by spec completeness instead of always writing Ready.
	local open_items
	open_items="$(printf '%s' "$items_json" \
		| jq -c '.items[] | select((.status == "Ready" or .status == "Backlog") and .content.type == "Issue")' \
			2>/dev/null)" \
		|| { RECONCILE_REPORT="UNKNOWN (board unreadable): could not parse project $owner/$project"; return 1; }
	while IFS= read -r item; do
		[[ -n "$item" ]] || continue
		line="$(_ru_process_open_item "$owner" "$project" "$item")"
		[[ -n "$line" ]] && report="$(printf '%s\n%s' "$report" "$line")"
	done <<<"$open_items"

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
# why here. `repo` is the board's own repo: it labels the report line and, for
# reconcile_kanban_boards (lib/kanban_reconcile.sh, #887), names the "<repo> kanban" board. The
# kanban reconcile sweeps this same list; do not add a second one.
# shellcheck disable=SC2034 # read by reconcile_roadmap_boards below and by its callers' tests
ROADMAP_BOARDS=(
	"guilhermegor|21|layouts-cvm"
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
