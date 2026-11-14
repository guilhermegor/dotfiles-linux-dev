#!/bin/bash
# Lesson Status backfill (dotfiles-linux-dev#1001).
#
# session_capture_audit.sh reported hundreds of lessons as "genuinely unaccounted" that were
# format drift, not lost work (measured 2026-11-13: 145 of blueprintx's 149 carried
# `Status: tracked|queued`; 109 of the toolchain's 118 cited their issue in prose). Whether a
# lesson's issue is open, closed as completed, or merged is a FORGE FACT, so this derives the
# Status from the forge instead of filing one issue per lesson.
#
# Usage:  lesson_status_backfill.sh [--apply] [--default-repo OWNER/REPO] STORE_DIR
#   Dry run by default: one tab-separated line per lesson (file, tier, refs, decision) and a
#   summary. --apply rewrites the lesson files (temp file + mv).
#
# Decision, over the lesson's refs (REST `repos/<o>/<r>/issues/<n>`; the issues endpoint answers
# for PRs too and carries `pull_request.merged_at`, so one call per ref and no GraphQL):
#   delivered  no ref is open, and a ref is a merged PR or an issue closed as `completed`
#              (a merged PR is also written to the `**PR:**` line)
#   tracked    a ref is an open issue/PR, and no ref is delivered
#   left       no ref, an unreadable ref, closed not_planned/unknown reason, or open and
#              delivered refs mixed: never guessed, reported for a human
# A Status of delivered/advisory/superseded is never rewritten (and costs no forge call).
#
# Which refs count: refs on the disposition lines (**Status:**, **PR:**, **Issue:**,
# **Tracked:**, **Backport tracked:**) win; only a lesson with none falls back to refs anywhere
# in the body (at most LB_MAX_BODY_REFS of them), EXCEPT its **Origin:** line. Origin names where the problem was SEEN, not where
# the fix landed, so a closed origin issue would mark a lesson delivered whose backport never
# happened. A wrong `delivered` hides real debt, which is the failure this audit exists to
# prevent. The dry-run line names the tier used.
#
# Also sourced by session_capture_audit.sh for lesson_has_ref(); when sourced it only defines
# functions (no options set, no output).

LB_OWNER="${LB_OWNER:-guilhermegor}"
# A body with more refs than this is a lesson QUOTING examples (a dozen PR numbers measured as
# evidence), not one tracking an issue: attributing a Status to it would be a guess.
LB_MAX_BODY_REFS="${LESSON_BACKFILL_MAX_BODY_REFS:-5}"
LB_META_RE='^[[:space:]]*([-*][[:space:]]+)?\*\*(Status|PR|Issue|Tracked|Backport tracked):\*\*'
LB_STATUS_RE='^[[:space:]]*([-*][[:space:]]+)?\*\*Status:\*\*'
LB_PR_RE='^[[:space:]]*([-*][[:space:]]+)?\*\*PR:\*\*'
LB_ORIGIN_RE='^[[:space:]]*([-*][[:space:]]+)?\*\*Origin:\*\*'
# `#123`, `repo#123`, `owner/repo#123`, `pull/123`, `issues/123`, github.com/o/r/pull/123.
# The lookbehind keeps `&#123;`, anchors and path fragments out of the match.
LB_REF_RE='(?<![\w/.#&-])(?:(?:[A-Za-z0-9_.-]+/)?[A-Za-z][A-Za-z0-9_.-]*)?#\d{1,6}(?!\w)|(?<![\w/.-])(?:pull|issues)/\d+(?!\w)|github\.com/[\w.-]+/[\w.-]+/(?:pull|issues)/\d+'

# lesson_has_ref FILE
# True when the lesson names any issue/PR ref anywhere. One grep, no fork chain: the audit
# runs it per lesson at SessionEnd.
lesson_has_ref() {
	grep -qP "$LB_REF_RE" "$1" 2>/dev/null
}

# lesson_status_word FILE
# First word of the Status value, lowercased, backticks and punctuation stripped; empty when
# the lesson has no Status line.
lesson_status_word() {
	local value
	value="$(grep -m1 -E "$LB_STATUS_RE" "$1" 2>/dev/null | sed -E 's/^[^:]*\*\*Status:\*\*[[:space:]]*//')" || true
	[ -n "$value" ] || return 0
	value="${value//\`/}"
	value="${value%%[[:space:]]*}"
	value="${value%%—*}"
	value="${value%%[:,.;-]*}"
	printf '%s\n' "${value,,}"
}

# lesson_refs FILE DEFAULT_REPO [meta|body]
# One `owner/repo#N` per line, sorted and unique. `meta` reads only the disposition lines,
# `body` the whole file minus the **Origin:** line. A bare `#N`, `pull/N` and a repo-less
# `PR#N` resolve to DEFAULT_REPO; a bare `name#N` to $LB_OWNER/name.
lesson_refs() {
	local file="$1" default_repo="$2" tier="${3:-body}" tok repo n
	local source_cmd
	if [ "$tier" = "meta" ]; then
		source_cmd=(grep -E "$LB_META_RE" "$file")
	else
		source_cmd=(grep -vE "$LB_ORIGIN_RE" "$file")
	fi
	while IFS= read -r tok; do
		case "$tok" in
		github.com/*/*/pull/* | github.com/*/*/issues/*)
			tok="${tok#github.com/}"
			n="${tok##*/}"
			repo="${tok%/pull/*}"
			repo="${repo%/issues/*}"
			;;
		pull/* | issues/*)
			repo="$default_repo"
			n="${tok#*/}"
			;;
		*)
			n="${tok##*#}"
			repo="${tok%#*}"
			case "$repo" in
			"" | [Pp][Rr] | [Ii]ssue | [Ii]ssues | [Pp]ull) repo="$default_repo" ;;
			*/*) ;;
			*) repo="$LB_OWNER/$repo" ;;
			esac
			;;
		esac
		printf '%s#%s\n' "$repo" "$n"
	done < <("${source_cmd[@]}" 2>/dev/null | grep -oP "$LB_REF_RE") | sort -u
}

# --- forge ---------------------------------------------------------------------------------

lb_init() {
	declare -gA LB_CACHE=()
	LB_CALLS=0
	LB_MAX_CALLS="${LESSON_BACKFILL_MAX_CALLS:-1500}"
	LB_GH_CACHE="${LESSON_BACKFILL_GH_CACHE:-30m}"
}

# lb_forge_state OWNER/REPO#N
# Sets LB_STATE to one of: pr-merged pr-open pr-closed issue-open issue-completed
# issue-notplanned issue-closed missing error. Cached per ref within the run (lessons share
# refs by the hundred); a 404 is `missing`, any other failure and the call ceiling are `error`
# (unreadable, fail closed). `--cache` lets a later --apply re-use the dry run's answers.
lb_forge_state() {
	local ref="$1" repo n out
	if [ -n "${LB_CACHE[$ref]+x}" ]; then
		LB_STATE="${LB_CACHE[$ref]}"
		return 0
	fi
	repo="${ref%#*}"
	n="${ref##*#}"
	if [ "$LB_CALLS" -ge "$LB_MAX_CALLS" ]; then
		LB_STATE="error"
		return 0
	fi
	LB_CALLS=$((LB_CALLS + 1))
	if out="$(gh api --cache "$LB_GH_CACHE" "repos/$repo/issues/$n" --jq '
		if .pull_request then
			(if .pull_request.merged_at then "pr-merged" elif .state == "open" then "pr-open" else "pr-closed" end)
		elif .state == "open" then "issue-open"
		elif .state_reason == "completed" then "issue-completed"
		elif .state_reason == "not_planned" then "issue-notplanned"
		else "issue-closed" end' 2>&1)"; then
		case "$out" in
		pr-merged | pr-open | pr-closed | issue-open | issue-completed | issue-notplanned | issue-closed) LB_STATE="$out" ;;
		*) LB_STATE="error" ;;
		esac
	elif [[ "$out" == *"404"* || "$out" == *"Not Found"* ]]; then
		LB_STATE="missing"
	else
		LB_STATE="error"
	fi
	LB_CACHE[$ref]="$LB_STATE"
}

# lb_decide FILE DEFAULT_REPO
# Sets LB_DECISION (delivered|tracked|unchanged|kept|left), LB_DETAIL, LB_TIER, LB_REFS,
# LB_STATUS_VALUE (new Status value) and LB_PR_REF (merged PR to name, may be empty).
lb_decide() {
	local file="$1" default_repo="$2" word ref open=0 done_n=0 bad=0 first_merged="" first_done="" first_open=""
	local -a refs=()
	LB_DECISION="" LB_DETAIL="" LB_TIER="" LB_REFS="" LB_STATUS_VALUE="" LB_PR_REF=""

	word="$(lesson_status_word "$file")"
	case "$word" in
	delivered | advisory | superseded)
		LB_DECISION="kept"
		LB_DETAIL="Status already $word"
		return 0
		;;
	esac

	LB_TIER="meta"
	mapfile -t refs < <(lesson_refs "$file" "$default_repo" meta)
	if [ "${#refs[@]}" -eq 0 ]; then
		LB_TIER="body"
		mapfile -t refs < <(lesson_refs "$file" "$default_repo" body)
	fi
	if [ "${#refs[@]}" -eq 0 ]; then
		LB_TIER="-"
		LB_DECISION="left"
		LB_DETAIL="no issue/PR ref"
		return 0
	fi
	LB_REFS="$(IFS=,; printf '%s' "${refs[*]}")"
	if [ "$LB_TIER" = "body" ] && [ "${#refs[@]}" -gt "$LB_MAX_BODY_REFS" ]; then
		LB_DECISION="left"
		LB_DETAIL="${#refs[@]} refs in prose, none on a disposition line: cannot attribute"
		return 0
	fi

	for ref in "${refs[@]}"; do
		lb_forge_state "$ref"
		case "$LB_STATE" in
		error)
			LB_DECISION="left"
			LB_DETAIL="unreadable ref $ref"
			return 0
			;;
		missing)
			# A typo in a disposition line is a human's to fix; a stray `#12` in prose is
			# just a number, not a ref.
			if [ "$LB_TIER" = "meta" ]; then
				LB_DECISION="left"
				LB_DETAIL="ref $ref does not exist"
				return 0
			fi
			;;
		issue-open | pr-open)
			open=$((open + 1))
			[ -n "$first_open" ] || first_open="$ref"
			;;
		pr-merged)
			done_n=$((done_n + 1))
			[ -n "$first_merged" ] || first_merged="$ref"
			[ -n "$first_done" ] || first_done="$ref"
			;;
		issue-completed)
			done_n=$((done_n + 1))
			[ -n "$first_done" ] || first_done="$ref"
			;;
		*) bad=$((bad + 1)) ;;
		esac
	done

	if [ "$open" -gt 0 ] && [ "$done_n" -gt 0 ]; then
		LB_DECISION="left"
		LB_DETAIL="ambiguous: open and delivered refs mixed"
		return 0
	fi
	if [ "$open" -gt 0 ]; then
		LB_DECISION="tracked"
		LB_DETAIL="open ref"
		LB_STATUS_VALUE="tracked — $first_open"
		[ "$word" = "tracked" ] && LB_DECISION="unchanged"
		return 0
	fi
	if [ "$done_n" -gt 0 ]; then
		LB_DECISION="delivered"
		LB_DETAIL="$first_done closed"
		LB_STATUS_VALUE="delivered — $first_done"
		LB_PR_REF="$first_merged"
		return 0
	fi
	LB_DECISION="left"
	LB_DETAIL="closed not_planned or unknown reason (${bad:-0} ref)"
}

# lb_rewrite FILE STATUS_VALUE PR_REF
# Writes the new Status (and a PR ref in place of a placeholder, or a new PR line) to a temp
# file in the same directory, then mv over FILE. The old Status text is kept as "(was: ...)".
lb_rewrite() {
	local file="$1" status_value="$2" pr_ref="$3" tmp
	tmp="$(mktemp "$(dirname -- "$file")/.lesson-backfill.XXXXXX")" || return 1
	if ! awk -v new_status="$status_value" -v pr_ref="$pr_ref" '
		function after_label(line, label,   rest) {
			rest = substr(line, index(line, label) + length(label)); sub(/^[ \t]+/, "", rest); return rest
		}
		function prefix_of(line) { match(line, /^[ \t]*([-*][ \t]+)?/); return substr(line, 1, RLENGTH) }
		function is_placeholder(v) {
			v = tolower(v); gsub(/^[ \t]+|[ \t]+$/, "", v)
			return v ~ /^(—|-|–|none( yet)?\.?|pending|not yet opened\.?|n\/a|tbd)?$/
		}
		{ lines[NR] = $0 }
		END {
			meta = ""
			for (i = 1; i <= NR; i++) {
				if (meta == "" && lines[i] ~ /^[ \t]*([-*][ \t]+)?\*\*[A-Za-z ]+:\*\*/) meta = prefix_of(lines[i])
				if (lines[i] ~ /^[ \t]*([-*][ \t]+)?\*\*Status:\*\*/) { s_at = i }
				if (lines[i] ~ /^[ \t]*([-*][ \t]+)?\*\*PR:\*\*/) { p_at = i }
			}
			if (s_at) {
				old = after_label(lines[s_at], "**Status:**")
				pfx = prefix_of(lines[s_at])
				lines[s_at] = pfx "**Status:** " new_status ((old == "" || old == "—") ? "" : " (was: " old ")")
			}
			if (pr_ref != "" && p_at) {
				old = after_label(lines[p_at], "**PR:**")
				if (is_placeholder(old)) lines[p_at] = prefix_of(lines[p_at]) "**PR:** " pr_ref
			}
			add_pr = (pr_ref != "" && !p_at)
			need_status = (s_at == 0)
			for (i = 1; i <= NR; i++) {
				print lines[i]
				if (i == p_at && need_status) { print prefix_of(lines[i]) "**Status:** " new_status; need_status = 0 }
			}
			if (need_status || add_pr) {
				print ""
				if (add_pr) print meta "**PR:** " pr_ref
				if (need_status) print meta "**Status:** " new_status
			}
		}' "$file" >"$tmp"; then
		rm -f "$tmp"
		return 1
	fi
	chmod --reference="$file" "$tmp" 2>/dev/null || true
	mv -f "$tmp" "$file"
}

# lb_default_repo STORE_DIR — the store's own repo, per the lesson-store registry.
lb_default_repo() {
	case "$(basename -- "$1")" in
	lessons) printf '%s/blueprintx\n' "$LB_OWNER" ;;
	lessons-claude-toolchain | lessons-dotfiles) printf '%s/dotfiles-linux-dev\n' "$LB_OWNER" ;;
	*) return 1 ;;
	esac
}

lb_core_remaining() {
	gh api rate_limit --jq '.resources.core.remaining' 2>/dev/null || printf '?'
}

lb_usage() {
	printf 'usage: lesson_status_backfill.sh [--apply] [--default-repo OWNER/REPO] STORE_DIR\n' >&2
}

main() {
	local apply=0 store="" default_repo="" file name
	local -i delivered=0 tracked=0 unchanged=0 kept=0 left=0 total=0
	while [ $# -gt 0 ]; do
		case "$1" in
		--apply) apply=1 ;;
		--default-repo)
			default_repo="${2:-}"
			shift
			;;
		-h | --help)
			lb_usage
			return 0
			;;
		-*)
			lb_usage
			return 2
			;;
		*) store="$1" ;;
		esac
		shift
	done
	if [ -z "$store" ] || [ ! -d "$store" ]; then
		lb_usage
		return 2
	fi
	if [ -z "$default_repo" ]; then
		default_repo="$(lb_default_repo "$store")" || {
			printf 'cannot derive the default repo for %s — pass --default-repo OWNER/REPO\n' "$store" >&2
			return 2
		}
	fi
	command -v gh >/dev/null 2>&1 || {
		printf 'gh not found — the forge decides the Status, nothing to do\n' >&2
		return 1
	}

	lb_init
	local core_before core_after
	core_before="$(lb_core_remaining)"

	for file in "$store"/*.md; do
		[ -e "$file" ] || continue
		name="$(basename -- "$file")"
		[ "$name" = "README.md" ] && continue
		total=$((total + 1))
		lb_decide "$file" "$default_repo"
		printf '%s\t%s\t%s\t%s\n' "$name" "${LB_TIER:--}" "${LB_REFS:--}" "$LB_DECISION: $LB_DETAIL"
		case "$LB_DECISION" in
		kept) kept=$((kept + 1)) ;;
		unchanged) unchanged=$((unchanged + 1)) ;;
		left) left=$((left + 1)) ;;
		delivered | tracked)
			[ "$LB_DECISION" = "delivered" ] && delivered=$((delivered + 1)) || tracked=$((tracked + 1))
			if [ "$apply" -eq 1 ]; then
				lb_rewrite "$file" "$LB_STATUS_VALUE" "$LB_PR_REF" ||
					printf '%s\t-\t-\tERROR: rewrite failed, file untouched\n' "$name" >&2
			fi
			;;
		esac
	done

	core_after="$(lb_core_remaining)"
	printf 'summary: store=%s mode=%s lessons=%d delivered=%d tracked=%d unchanged=%d kept=%d left-for-human=%d forge_calls=%d core_remaining=%s->%s\n' \
		"$store" "$([ "$apply" -eq 1 ] && echo apply || echo dry-run)" \
		"$total" "$delivered" "$tracked" "$unchanged" "$kept" "$left" "$LB_CALLS" \
		"$core_before" "$core_after"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	set -uo pipefail
	main "$@"
fi
