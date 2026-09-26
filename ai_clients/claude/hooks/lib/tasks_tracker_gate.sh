#!/bin/bash
# Shared missing-tracker gate (dotfiles-dev#485): "which in-flight multi-step effort has no
# tasks.md tracker", mirroring orphaned_issues.sh / roadmap_unblock.sh in shape -- generic across
# repos (owner/repo arguments, nothing hardcoded), sourced by s:dev-loop step 2 (SWEEP) instead of
# re-deriving the walk by hand.
#
# The predicate that had to be settled first (measured, dotfiles-dev#485): every one of this
# repo's .specs/features/<slug>/ directories carries a plan.md, and none carries a tasks.md -- so
# "has plan.md, lacks tasks.md" fires on every feature at once, including long-finished ones, and
# a check that reports N findings the day it ships is a check nobody reads twice. The missing half
# is "in-flight," and the filesystem alone cannot answer that -- a plan.md sitting untouched for
# months looks identical to one written this morning. This gate answers it from the forge instead:
# a feature directory is a candidate only when its slug is mentioned by an OPEN issue or PR's
# title/body -- "in-flight by the forge, not by the filesystem." A finished feature has no open
# issue/PR still naming it, so it reports nothing -- the legitimate quiet case the issue required.
#
# Rejected alternatives (recorded so they are not re-proposed): a "split" signal (more than one
# open issue referencing the same slug) answers a different question -- was this decomposed, not
# whether a tracker is missing; a staleness signal (tasks.md existed, stopped updating) requires a
# tasks.md to already exist and so cannot catch the never-created case this issue is about.
#
# Contract:
#   gate_missing_tracker OWNER REPO [ROOT=.]
#     Sets two globals (never partial -- a failure leaves both empty AND returns 1):
#       TRACKER_STATUS = ok | unknown
#       TRACKER_REPORT = newline-separated candidate lines, one per feature directory with a
#                        plan.md/design.md/spec.md, no tasks.md, and at least one OPEN issue or PR
#                        mentioning the feature slug in its title/body --
#                        ".specs/features/<slug> has no tasks.md -- referenced by open #<n> (<url>)".
#                        Empty when no candidate is found (still TRACKER_STATUS=ok).
#     Returns 1 and sets TRACKER_STATUS=unknown on any gh read failure -- never silently treats an
#     unreadable search as "not referenced".
set -u

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	echo "tasks_tracker_gate.sh is meant to be sourced, not executed." >&2
	exit 1
fi

# _tracker_feature_dirs ROOT
# Prints one feature slug per line: a directory directly under ROOT/.specs/features/ that
# carries at least one of plan.md/design.md/spec.md but no tasks.md.
_tracker_feature_dirs() {
	local root="$1" dir slug
	local features_dir="$root/.specs/features"
	[ -d "$features_dir" ] || return 0
	for dir in "$features_dir"/*/; do
		[ -d "$dir" ] || continue
		[ -f "$dir/tasks.md" ] && continue
		if [ -f "$dir/plan.md" ] || [ -f "$dir/design.md" ] || [ -f "$dir/spec.md" ]; then
			slug="$(basename "$dir")"
			printf '%s\n' "$slug"
		fi
	done
}

gate_missing_tracker() {
	local owner="$1" repo="$2" root="${3:-.}"
	local slug_repo="$owner/$repo"
	TRACKER_STATUS="unknown"
	TRACKER_REPORT=""

	local slugs
	slugs="$(_tracker_feature_dirs "$root")"

	# Each candidate slug below costs one `gh search issues` call, and the search API's limit is
	# 30/minute -- an order of magnitude tighter than core's 5000/hour. This gate runs from
	# SubagentStop, so several agents finishing together multiply the burst. Refuse to spend an
	# unbounded number of calls: report unknown rather than a partial answer, since a truncated
	# candidate list is indistinguishable from "no candidate" to every caller.
	local slug_count
	slug_count="$(printf '%s\n' "$slugs" | sed '/^$/d' | wc -l)"
	if [ "$slug_count" -gt "${TRACKER_MAX_SEARCHES:-25}" ]; then
		return 1
	fi

	local feature_slug hit report=""
	while IFS= read -r feature_slug; do
		[ -n "$feature_slug" ] || continue
		hit="$(gh search issues --repo "$slug_repo" --state open --include-prs --match title,body \
			"$feature_slug" --json number,url --jq '(.[0] // empty) | "#\(.number) (\(.url))"' 2>/dev/null)" \
			|| return 1
		[ -n "$hit" ] || continue
		report="$(printf '%s\n%s' "$report" \
			".specs/features/$feature_slug has no tasks.md -- referenced by open $hit")"
	done <<<"$slugs"

	# shellcheck disable=SC2034 # read by callers after this returns, not within this file
	TRACKER_REPORT="$(printf '%s\n' "$report" | sed '/^$/d' | sort -u)"
	# shellcheck disable=SC2034 # read by callers after this returns, not within this file
	TRACKER_STATUS="ok"
	return 0
}
