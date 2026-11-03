#!/bin/bash
# Stable entry point for squash-merging GREEN PRs (dotfiles-linux-dev#868).
#
# Usage: merge_green_pr.sh <pr-number>...      (run inside a clone of the PRs' repo)
#
# Exists so settings.json can allow exactly this path. On a single-maintainer repo no
# PR can get a human approval, so the auto-mode classifier denies every merge as "Merge
# Without Review". A glob rule on `gh pr merge` cannot help: measured on layouts-cvm, the
# GraphQL-backed `gh pr merge` failed on rate limit and the shapes that were denied were a
# bare `gh api -X PUT .../merge`, a `for` loop and a scratch script. Same precedent as
# run_ladder_review.sh (#738): one wrapper, one allow rule, the guards live inside it.
#
# Takes positive integers ONLY: no flags, so no --admin and no merge_method choice (always
# squash). REST only, zero GraphQL. Per PR it refuses unless the PR is not a draft, its
# mergeable_state is `clean`, and every required check-run on the head (the base branch's
# protection contexts PLUS "Review threads answered") concluded `success`; an unreadable
# protection is UNKNOWN and fails closed. The merge PUT pins the head sha, so a push after
# the checks were read is refused by GitHub. Prints one line per PR; exits 1 if any was
# refused. Run it as `cd <absolute-repo-path> && …`: OWNER/REPO come from the cwd's origin.
set -u

if [ "$#" -lt 1 ]; then
	echo "usage: merge_green_pr.sh <pr-number>... (positive integers only, no flags)" >&2
	exit 2
fi
for a in "$@"; do
	if [[ ! "$a" =~ ^[1-9][0-9]*$ ]]; then
		echo "usage: merge_green_pr.sh <pr-number>... (positive integers only, no flags)" >&2
		exit 2
	fi
done

slug="$(git remote get-url origin 2>/dev/null | sed -E 's#\.git$##; s#^.*[:/]([^/:]+/[^/]+)$#\1#')"
owner="${slug%%/*}"
repo="${slug#*/}"
if [ -z "$owner" ] || [ "$owner" = "$slug" ]; then
	echo "cannot derive OWNER/REPO from the origin remote" >&2
	exit 1
fi

GATE_CHECK="Review threads answered"

# ponytail: one plain retry; swap for gh_budget_with_backoff once it exists on master
# (gh_budget.sh only classifies today).
gh_retry() { gh "$@" 2>/dev/null || { sleep "${MERGE_GREEN_RETRY_SLEEP:-2}"; gh "$@" 2>/dev/null; }; }

merge_one() {
	local pr="$1" info head state draft base author prot required checks bad name files

	info="$(gh_retry api "repos/$owner/$repo/pulls/$pr" \
		--jq '[.head.sha, .mergeable_state, (.draft|tostring), .base.ref, .user.login] | @tsv')" && [ -n "$info" ] ||
		{ echo "#$pr UNKNOWN: cannot read the PR"; return 1; }
	IFS=$'\t' read -r head state draft base author <<<"$info"
	[ -n "$head" ] && [ -n "$base" ] && [ -n "$author" ] || { echo "#$pr UNKNOWN: malformed PR read"; return 1; }
	[ "$author" = "$me" ] || { echo "#$pr REFUSED: author '$author' is not '$me' — merge by hand"; return 1; }
	[ "$draft" = "false" ] || { echo "#$pr REFUSED: draft"; return 1; }
	[ "$state" = "clean" ] || { echo "#$pr REFUSED: mergeable_state is '$state', not clean"; return 1; }

	# A PR can add a workflow that posts a green check with a required name, so the
	# check gate below is only trustworthy for a PR that cannot change CI definitions.
	files="$(gh_retry api --paginate "repos/$owner/$repo/pulls/$pr/files?per_page=100" --jq '.[].filename')" ||
		{ echo "#$pr UNKNOWN: cannot read the PR's files"; return 1; }
	if grep -q -E '^\.github/(workflows|actions)/' <<<"$files"; then
		echo "#$pr REFUSED: touches CI definitions — merge by hand"
		return 1
	fi

	prot="$(gh_retry api "repos/$owner/$repo/branches/$base/protection" \
		--jq '[(.required_status_checks.contexts // [])[], (.required_status_checks.checks // [])[].context] | unique | .[]')" ||
		{ echo "#$pr UNKNOWN: cannot read branch protection of $base"; return 1; }
	required="$(printf '%s\n%s\n' "$prot" "$GATE_CHECK" | sed '/^$/d' | sort -u)"

	checks="$(gh_retry api --paginate "repos/$owner/$repo/commits/$head/check-runs?per_page=100" \
		--jq '.check_runs[] | [.name, (.conclusion // "pending")] | @tsv')" ||
		{ echo "#$pr UNKNOWN: cannot read check-runs of $head"; return 1; }

	bad=""
	while IFS= read -r name; do
		# Every run with this name must be success; a missing or mixed name is not green.
		if ! awk -F'\t' -v n="$name" '$1==n {seen=1; if ($2!="success") fail=1} END {exit !(seen && !fail)}' <<<"$checks"; then
			bad="$bad [$name]"
		fi
	done <<<"$required"
	[ -z "$bad" ] || { echo "#$pr REFUSED: required check not green:$bad"; return 1; }

	if gh_retry api -X PUT "repos/$owner/$repo/pulls/$pr/merge" \
		-f merge_method=squash -f sha="$head" >/dev/null; then
		echo "#$pr MERGED squash at ${head:0:12}"
	else
		echo "#$pr REFUSED: merge PUT failed (head moved, or branch protection blocks it)"
		return 1
	fi
}

main() {
	local pr rc=0
	# The remote is writable by an agent, so the target is trusted only if its owner is
	# the authenticated user; each PR's author must be that user too (bots go to a prompt).
	me="$(gh_retry api user --jq .login)" && [ -n "$me" ] ||
		{ echo "UNKNOWN: cannot read the authenticated user"; return 1; }
	if [ "$owner" != "$me" ]; then
		echo "REFUSED: repo owner '$owner' is not '$me' — merge by hand"
		return 1
	fi
	for pr in "$@"; do
		merge_one "$pr" || rc=1
	done
	return "$rc"
}

main "$@"
