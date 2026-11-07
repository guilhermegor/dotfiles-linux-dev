#!/bin/bash
# Stable entry point for resolving ANSWERED PR review threads.
#
# Usage: resolve_review_thread.sh <thread-node-id>...   (ids look like PRRT_kwDO...)
#
# Exists so settings.json can allow exactly this path. The auto-mode classifier denies
# a bare `gh api graphql` resolveReviewThread mutation as an external write, which left
# review agents able to reply but never resolve. Same precedent as merge_green_pr.sh
# (#868) and run_ladder_review.sh (#738): one wrapper, one allow rule, guards inside.
#
# Guards: takes thread node ids ONLY (no flags, no free-form query), and refuses a thread
# whose LAST comment is not a SUBMITTED comment by the authenticated gh account itself
# (viewer.login, type User): a bot reply answers nothing, a bot or reviewer re-opening after
# a reply must block, and an unsubmitted pending reply is invisible to others. A human
# collaborator's reply is refused too (safe direction: resolve it in the GitHub UI). A
# comment landing between the read and the mutation is not caught. gh stderr is passed
# through, never parsed. It also refuses a thread whose PR is not the viewer's own: the repo
# owner AND the PR author must both equal viewer.login (case-insensitive, null fails closed),
# so a PRRT_ id lifted from review text cannot reach a foreign repo or PR (#924). No minimum
# reply length: merge_green_pr.sh has no such floor to reuse.
# Resolving is the second half of "reply, then resolve", never a way
# to make an unanswered finding disappear. Any read it cannot parse fails closed.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/gh_budget.sh"

[ "$#" -ge 1 ] || { echo "usage: resolve_review_thread.sh <PRRT_id>..." >&2; exit 2; }

rc=0
for id in "$@"; do
  if ! [[ "$id" =~ ^PRRT_[A-Za-z0-9_-]+$ ]]; then
    echo "$id: REFUSED — not a review-thread node id" >&2; rc=1; continue
  fi
  gh_budget_log_spend 0 # one GraphQL request; cost unexposed (#922)
  state=$(gh api graphql -f id="$id" -f query='query($id:ID!){viewer{login} node(id:$id){
    ... on PullRequestReviewThread{isResolved
      pullRequest{author{login} repository{owner{login}}}
      comments(last:100){nodes{state author{__typename login}}}}}}' \
    --jq '.data.viewer.login as $me | .data.node | .comments.nodes as $n
    | (($me // "") | ascii_downcase) as $m
    | (if $m != "" and ((.pullRequest.author.login // "") | ascii_downcase) == $m
        and ((.pullRequest.repository.owner.login // "") | ascii_downcase) == $m
        then 1 else 0 end) as $own | "\(.isResolved) \($own) \(
      if ($n | length) > 1 and $n[-1].state == "SUBMITTED" and $n[-1].author.__typename == "User"
        and $n[-1].author.login == $me then 1 else 0 end)"') || {
    echo "$id: UNKNOWN — read failed: $state" >&2; rc=1; continue; }
  read -r resolved owned answered <<<"$state"
  if ! [[ "$resolved" =~ ^(true|false)$ && "$owned" =~ ^[01]$ && "$answered" =~ ^[0-9]+$ ]]; then
    echo "$id: UNKNOWN — unexpected read: $state" >&2; rc=1; continue
  fi
  if [ "$owned" -lt 1 ]; then
    echo "$id: REFUSED — thread is not on your own PR; use the GitHub UI" >&2
    rc=1; continue
  fi
  if [ "$resolved" = "true" ]; then echo "$id: already resolved"; continue; fi
  if [ "$answered" -lt 1 ]; then
    echo "$id: REFUSED — last comment is not your submitted reply yet" >&2; rc=1; continue
  fi
  gh_budget_log_spend 0 # one GraphQL request; cost unexposed (#922)
  out=$(gh api graphql -f id="$id" -f query='mutation($id:ID!){
    resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' \
    --jq '.data.resolveReviewThread.thread.isResolved')
  if [ "$out" = "true" ]; then echo "$id: resolved"; else echo "$id: FAILED — $out" >&2; rc=1; fi
done
exit "$rc"
