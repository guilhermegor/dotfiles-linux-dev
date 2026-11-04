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
# refused. OWNER/REPO come from the cwd's origin: from a shell already in the repo run it
# bare (`~/.claude/hooks/merge_green_pr.sh 27 29`, no `cd`); `cd <absolute-repo-path> && …`
# works too. A required check pinned to an app (protection app_id, ruleset integration_id)
# must come from that app's check-run; unpinned (null/-1) is matched by name. The gate cannot
# see CI code that is not under .github/.
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

# READ-ONLY calls only (never the merge PUT). One retry, and only for a transient error:
# a deterministic 4xx (404/405/409/422) is final. Each attempt's output is held apart, so a
# paginated read that fails midway cannot leave partial rows in front of the retry's rows.
# ponytail: swap for gh_budget_with_backoff once it exists on master (gh_budget.sh only
# classifies today).
gh_retry() {
	local out err
	err="$(mktemp)" || return 1
	if out="$(gh "$@" 2>"$err")"; then
		rm -f "$err"
		printf '%s\n' "$out"
		return 0
	fi
	if grep -q -E 'HTTP (404|405|409|422)' "$err"; then
		rm -f "$err"
		return 1
	fi
	sleep "${MERGE_GREEN_RETRY_SLEEP:-2}"
	rm -f "$err"
	out="$(gh "$@" 2>/dev/null)" || return 1
	printf '%s\n' "$out"
}

# Prints the base branch's required contexts: classic protection plus rulesets, one per line.
# "Branch not protected" (404) is an empty list; any other read failure fails the call.
required_contexts() {
	local base="$1" err classic rules
	err="$(mktemp)" || return 1
	if ! classic="$(gh api "repos/$owner/$repo/branches/$base/protection" \
		--jq '[(.required_status_checks.contexts // [])[] | [., "-1"], ((.required_status_checks.checks // [])[] | [.context, ((.app_id // -1)|tostring)])] | .[] | @tsv' 2>"$err")"; then
		if grep -q 'Branch not protected' "$err"; then
			classic=""
		else
			rm -f "$err"
			return 1
		fi
	fi
	rm -f "$err"
	rules="$(gh_retry api --paginate "repos/$owner/$repo/rules/branches/$base" \
		--jq '.[] | select(.type=="required_status_checks") | .parameters.required_status_checks[] | [.context, ((.integration_id // -1)|tostring)] | @tsv')" || return 1
	printf '%s\n%s\n' "$classic" "$rules" | sed '/^$/d'
}

merge_one() {
	local pr="$1" info head state draft base author changed try
	local required checks statuses bad name files

	# mergeable_state is computed lazily: poll while GitHub still says unknown/null.
	for try in 1 2 3; do
		info="$(gh_retry api "repos/$owner/$repo/pulls/$pr" \
			--jq '[(.head.sha // "-"), (.mergeable_state // "unknown"), ((.draft // false)|tostring), (.base.ref // "-"), (.user.login // "-"), ((.changed_files // "-")|tostring)] | @tsv')" && [ -n "$info" ] ||
			{ echo "#$pr UNKNOWN: cannot read the PR"; return 1; }
		# "-" placeholders keep every field non-empty: tab is IFS whitespace and would
		# otherwise collapse an empty field and shift the columns.
		IFS=$'\t' read -r head state draft base author changed <<<"$info"
		[ "$state" = "unknown" ] || break
		[ "$try" -lt 3 ] && sleep "${MERGE_GREEN_RETRY_SLEEP:-2}"
	done
	{ [ "$head" != "-" ] && [ "$base" != "-" ] && [ "$author" != "-" ] && [[ "$changed" =~ ^[0-9]+$ ]]; } ||
		{ echo "#$pr UNKNOWN: malformed PR read"; return 1; }
	# GitHub logins are case-insensitive.
	[ "${author,,}" = "${me,,}" ] || { echo "#$pr REFUSED: author '$author' is not '$me' — merge by hand"; return 1; }
	[ "$draft" = "false" ] || { echo "#$pr REFUSED: draft"; return 1; }
	# has_hooks is clean with pre-receive hooks; both are mergeable.
	[[ "$state" == "clean" || "$state" == "has_hooks" ]] ||
		{ echo "#$pr REFUSED: mergeable_state is '$state', not clean"; return 1; }

	# A PR can add a workflow that posts a green check with a required name, so the
	# check gate below is only trustworthy for a PR that cannot change CI definitions.
	files="$(gh_retry api --paginate "repos/$owner/$repo/pulls/$pr/files?per_page=100" --jq '.[] | [.filename, (.previous_filename // "")] | @tsv')" ||
		{ echo "#$pr UNKNOWN: cannot read the PR's files"; return 1; }
	# The files endpoint stops at 3000, so a short list could hide a .github/ change.
	if [ "$(grep -c . <<<"$files")" -ne "$changed" ]; then
		echo "#$pr REFUSED: file list incomplete — merge by hand"
		return 1
	fi
	# Either column: a rename out of .github/ keeps the old path in previous_filename.
	if grep -q -E $'(^|\t)\\.github/(workflows|actions)/' <<<"$files"; then
		echo "#$pr REFUSED: touches CI definitions — merge by hand"
		return 1
	fi

	required="$(required_contexts "$base")" ||
		{ echo "#$pr UNKNOWN: cannot read the required checks of $base"; return 1; }
	required="$(printf '%s\n%s\t-1\n' "$required" "$GATE_CHECK" | sed '/^$/d' | sort -u)"

	# Checks API plus the commit Status API (a required context may be posted via either).
	# State is normalised to "success"; GitHub counts skipped/neutral as passing, so they
	# are accepted too, except for the review gate itself (strict success).
	checks="$(gh_retry api --paginate "repos/$owner/$repo/commits/$head/check-runs?per_page=100" \
		--jq '.check_runs[] | [.name, (.conclusion // "pending"), "::check::", ((.app.id // -1)|tostring)] | @tsv')" ||
		{ echo "#$pr UNKNOWN: cannot read check-runs of $head"; return 1; }
	# A commit status is forgeable by any token with repo access, this account's own gh
	# included (a personal token cannot create a check-run). So a status never satisfies
	# the review gate, and for any other context it counts only when its creator is not
	# the authenticated user. Third column: "::check::" for a check-run, else the creator.
	statuses="$(gh_retry api "repos/$owner/$repo/commits/$head/status" \
		--jq '.statuses[] | [.context, .state, (.creator.login // "-"), "-"] | @tsv')" ||
		{ echo "#$pr UNKNOWN: cannot read commit statuses of $head"; return 1; }
	checks="$(printf '%s\n%s\n' "$checks" "$statuses")"

	bad=""
	while IFS=$'\t' read -r name app; do
		# No app_id (empty, null or -1) means any app; otherwise the check-run's app.id must
		# equal it. A commit status carries no app ("-"), so it never meets a pinned app.
		{ [ -z "$app" ] || [ "$app" = "null" ]; } && app="-1"
		# Every counted run with this name must pass; a missing or mixed name is not green.
		if ! awk -F'\t' -v n="$name" -v app="$app" -v gate="$GATE_CHECK" -v me="${me,,}" '
			$1==n && (app=="-1" || $4==app) {
				if ($3!="::check::" && (n==gate || tolower($3)==me)) next
				seen=1
				ok=($2=="success" || (n!=gate && ($2=="skipped" || $2=="neutral")))
				if (!ok) fail=1
			}
			END {exit !(seen && !fail)}' <<<"$checks"; then
			bad="$bad [$name]"
		fi
	done <<<"$required"
	[ -z "$bad" ] || { echo "#$pr REFUSED: required check not green:$bad"; return 1; }

	# The PUT is never retried: a call that succeeded server-side but errored client-side
	# would be re-sent into a 405/409 and misreported. On failure, ask whether it merged.
	if gh api -X PUT "repos/$owner/$repo/pulls/$pr/merge" \
		-f merge_method=squash -f sha="$head" >/dev/null 2>&1; then
		echo "#$pr MERGED squash at ${head:0:12}"
	elif [ "$(gh_retry api "repos/$owner/$repo/pulls/$pr" --jq .merged 2>/dev/null)" = "true" ]; then
		echo "#$pr MERGED squash at ${head:0:12} (PUT errored, PR is merged)"
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
	# Case-insensitive; an org-owned repo never equals a user login, so it is refused on
	# purpose (merge those by hand).
	if [ "${owner,,}" != "${me,,}" ]; then
		echo "REFUSED: repo owner '$owner' is not '$me' — merge by hand"
		return 1
	fi
	for pr in "$@"; do
		merge_one "$pr" || rc=1
	done
	return "$rc"
}

main "$@"
