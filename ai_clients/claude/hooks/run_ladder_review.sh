#!/bin/bash
# Stable entry point for ONE reviewer-ladder fallback review (dotfiles-linux-dev#738).
#
# Usage: run_ladder_review.sh <pr-number>      (run inside a clone of the PR's repo)
#
# Exists so settings.json can allow exactly this path instead of a `source … &&
# run_fallback_review …` compound, which the auto-mode classifier judged
# inconsistently. It takes ONE positive-integer PR number — the ladder's
# one-PR-per-invocation cap — and nothing else. Never passes paid/credit flags;
# the ladder's own guards (free rungs only, no re-review of a covered head) stay
# the safety boundary.
#
# The pushed epoch is the HEAD COMMIT's committer date, never NOW: a NOW epoch
# makes the ladder refuse every PR as "recently pushed".
set -u

pr="${1:-}"
if [[ ! "$pr" =~ ^[1-9][0-9]*$ ]] || [ "$#" -ne 1 ]; then
	echo "usage: run_ladder_review.sh <pr-number> (a positive integer, exactly one)" >&2
	exit 2
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/reviewer_ladder.sh
source "$here/lib/reviewer_ladder.sh" || exit 1

slug="$(git remote get-url origin 2>/dev/null | sed -E 's#\.git$##; s#^.*[:/]([^/:]+/[^/]+)$#\1#')"
owner="${slug%%/*}"
repo="${slug#*/}"
if [ -z "$owner" ] || [ "$owner" = "$slug" ]; then
	echo "cannot derive OWNER/REPO from the origin remote" >&2
	exit 1
fi

read -r head merge_state < <(gh api "repos/$owner/$repo/pulls/$pr" --jq '"\(.head.sha) \(.mergeable_state)"')
[ -n "${head:-}" ] || { echo "cannot resolve PR #$pr head" >&2; exit 1; }

committed="$(gh api "repos/$owner/$repo/commits/$head" --jq .commit.committer.date)"
pushed="$(date -d "$committed" +%s 2>/dev/null)" || { echo "bad committer date: $committed" >&2; exit 1; }
now="$(date +%s)"
comments="$(gh api --paginate "repos/$owner/$repo/issues/$pr/comments" --jq '.[]' | jq -s .)"
[ -n "$comments" ] || comments='[]'

# REST reports lowercase `dirty`; the lib compares GraphQL's uppercase DIRTY.
run_fallback_review "$owner" "$repo" "$pr" "${merge_state^^}" "$pushed" "$now" "$comments"
