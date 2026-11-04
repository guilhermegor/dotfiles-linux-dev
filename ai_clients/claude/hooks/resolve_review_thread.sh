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
# with no reply from a human account (a bot reply answers nothing; agents post as the
# owner). Resolving is the second half of "reply, then resolve", never a way to make an
# unanswered finding disappear. Any read it cannot parse fails closed.
set -uo pipefail

[ "$#" -ge 1 ] || { echo "usage: resolve_review_thread.sh <PRRT_id>..." >&2; exit 2; }

rc=0
for id in "$@"; do
  if ! [[ "$id" =~ ^PRRT_[A-Za-z0-9_-]+$ ]]; then
    echo "$id: REFUSED — not a review-thread node id" >&2; rc=1; continue
  fi
  state=$(gh api graphql -f id="$id" -f query='query($id:ID!){node(id:$id){
    ... on PullRequestReviewThread{isResolved
      comments(first:100){nodes{author{__typename}}}}}}' \
    --jq '.data.node | "\(.isResolved) \([.comments.nodes[1:][]
      | select(.author.__typename == "User")] | length)"' 2>&1) || {
    echo "$id: UNKNOWN — read failed: $state" >&2; rc=1; continue; }
  read -r resolved replies <<<"$state"
  if ! [[ "$resolved" =~ ^(true|false)$ && "$replies" =~ ^[0-9]+$ ]]; then
    echo "$id: UNKNOWN — unexpected read: $state" >&2; rc=1; continue
  fi
  if [ "$resolved" = "true" ]; then echo "$id: already resolved"; continue; fi
  if [ "$replies" -lt 1 ]; then
    echo "$id: REFUSED — no human reply on the thread yet" >&2; rc=1; continue
  fi
  out=$(gh api graphql -f id="$id" -f query='mutation($id:ID!){
    resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' \
    --jq '.data.resolveReviewThread.thread.isResolved' 2>&1)
  if [ "$out" = "true" ]; then echo "$id: resolved"; else echo "$id: FAILED — $out" >&2; rc=1; fi
done
exit "$rc"
