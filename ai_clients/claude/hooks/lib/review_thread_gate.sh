#!/bin/bash
# Shared review-thread gate: ONE implementation of "is this PR's review done?",
# extracted from open_review_threads_nudge.sh (dotfiles-dev#167) so a second
# caller (the SubagentStop board sweep) calls the SAME gate instead of
# re-deriving the verdict. blueprintx measured what re-deriving costs: its
# sweep re-implemented review-thread logic, inherited the gate's own bug PLUS
# a new one of its own (matched a bare `thread` substring inside a sentence
# that meant the opposite, misreporting 27 PRs clean). One implementation,
# called from both places, cannot drift from itself.
#
# Generic across repos: takes owner/repo/number/roster-file as arguments,
# nothing hardcoded. Callers are responsible for `cd` into the repo whose
# `.review-bots.yaml` (if any) should apply — this file reads it as a plain
# relative path, matching the convention the roster file itself established.
#
# Contract: call `gate_pr_thread_state OWNER REPO NUMBER [ROSTER_FILE]`.
# It sets two globals and returns nothing meaningful (check GATE_STATUS):
#   GATE_STATUS = clean | problems | running | unreviewed | unreadable
#   GATE_DETAIL = human-readable multi-line detail (empty when clean)
#
# `unreviewed` (dotfiles-dev#505) is distinct from `clean`: `clean` means "no
# unanswered thread was found", which is also true of a PR no roster reviewer
# has ever looked at -- reviewThreads is empty either way, so the original
# three-state verdict could not tell "reviewed, nothing to answer" apart from
# "nobody has spoken". `unreviewed` fires only when no roster reviewer has
# submitted a review AND posted no completion comment on the current head --
# derived from the roster (_gate_roster_logins), never from `reviews | length`,
# so a human review by the PR's own author or a bot outside the roster does
# not count as a reviewer having reported.
# shellcheck disable=SC2034 # both are read by every caller after the call returns
set -u

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	echo "review_thread_gate.sh is meant to be sourced, not executed." >&2
	exit 1
fi

_gate_min_reply_chars=100

# The reviewer ladder's attribution marker (#455's exact regex, lifted verbatim from
# review_threads.yml's `ladder_marker_re` -- dotfiles-dev#490). A text match on this line ALONE
# is the CWE-345 hole #455 closed for the merge gate: any PR commenter can paste this line into a
# comment they wrote themselves. It is only ever trusted paired with authorAssociation below.
_gate_ladder_marker_re='^Fallback review — runtime: (qwen|codex), model: .+ \(selected by: .+\)$'

_gate_query() {
	cat <<'GRAPHQL'
query($owner:String!, $repo:String!, $number:Int!) {
  repository(owner:$owner, name:$repo) {
    pullRequest(number:$number) {
      reviewThreads(first:100) {
        totalCount
        nodes {
          isResolved
          path
          comments(first:50) { totalCount nodes { author { login __typename } body } }
        }
      }
      comments(last:100) {
        totalCount
        nodes { id author { login __typename } authorAssociation body createdAt }
      }
      reviews(first:100) {
        totalCount
        nodes { author { login __typename } state commit { oid } }
      }
      commits(last:1) {
        nodes {
          commit {
            oid
            committedDate
            statusCheckRollup {
              contexts(first:100) {
                totalCount
                nodes {
                  __typename
                  ... on CheckRun {
                    name
                    status
                    checkSuite { app { slug } }
                  }
                  ... on StatusContext {
                    context
                    state
                    creator { login }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
GRAPHQL
}

# ⚠️ Normalised WITHOUT the `[bot]` suffix: REST reports `coderabbitai[bot]`, GraphQL returns
# `coderabbitai`. Comparing the two literally is what left the repo-side gate silently vacuous.
_gate_roster_logins() {
	local roster_file="$1"
	if [ -n "$roster_file" ] && [ -f "$roster_file" ]; then
		sed -n 's/^[[:space:]]*-[[:space:]]*login:[[:space:]]*//p' "$roster_file" \
			| sed 's/\[bot\]$//' | sed '/^$/d'
		return 0
	fi
	# No roster: fall back to treating any bot account as a reviewer, resolved per comment in the
	# jq filter below via `author.__typename == "Bot"` (GraphQL strips `[bot]`, so a suffix test
	# on this path matches nothing and every bot reply would misread as human).
	printf '__NO_ROSTER__\n'
}

# The jq program behind `problems`, extracted so tests can run it against a fixture without a
# network round-trip -- same shape as _gate_query() above.
#
# ⚠️ `index()` evaluates its ARGUMENT with `.` bound to index's own input, which here is the
# $bots ARRAY -- not the comment. The same fault sat in _gate_running_filter (`.creator.login`,
# `.checkSuite.app.slug`) and was found only once that filter became reachable from a test. Writing `$bots | index(.author.login)` therefore indexes an
# array with a string, and jq aborts the whole program with exit 5:
#
#     jq: error (at <stdin>:0): Cannot index array with string "author"
#
# Under the workflow's `set -euo pipefail` that killed the step before it could print a verdict,
# so the required check failed with no diagnostic at all. Binding the comment to $c first is what
# keeps the lookup pointed at the comment. The bug was invisible for as long as it existed
# because it needs BOTH a roster file (else the __NO_ROSTER__ branch runs, which never touches
# index()) AND at least one review thread (else `nodes[]` yields nothing and the filter is never
# evaluated) -- every PR gated until PR #325 had zero threads.
_gate_problems_filter() {
	cat <<'JQ'
($roster | split("\n") | map(select(length > 0))) as $bots
| .data.repository.pullRequest.reviewThreads.nodes[]
| . as $t
| ($t.comments.nodes
   | map(. as $c | select(
       (if ($bots | index("__NO_ROSTER__"))
        then (($c.author.__typename // "") != "Bot")
        else ($bots | index($c.author.login // "") | not) end)
       and (($c.body // "" | length) >= $min)))
   | length) as $answers
| if $answers == 0 then
    "  \($t.path // "?"): needs a REPLY (and then a resolve)"
  elif ($t.isResolved | not) then
    "  \($t.path // "?"): replied — still needs RESOLVING"
  else empty end
JQ
}

# The jq program behind `truncated`, extracted for the same reason as _gate_problems_filter:
# a filter a test can reach is a filter a test can break.
_gate_truncated_filter() {
	cat <<'JQ'
.data.repository.pullRequest.reviewThreads as $rt
| .data.repository.pullRequest.comments as $pc
| .data.repository.pullRequest.reviews as $rv
| [ (if ($rt.totalCount // 0) > ($rt.nodes | length) then
       "  UNREADABLE: \($rt.totalCount) review threads exist, only \($rt.nodes | length) fit one page"
     else empty end),
    ($rt.nodes[]
     | select((.comments.totalCount // 0) > (.comments.nodes | length))
     | "  UNREADABLE: \(.path // "?"): \(.comments.totalCount) comments, only \(.comments.nodes | length) read"),
    (if ($pc.totalCount // 0) > ($pc.nodes | length) then
       "  UNREADABLE: \($pc.totalCount) PR comments exist, only \($pc.nodes | length) fit one page (comment channel)"
     else empty end),
    (if ($rv.totalCount // 0) > ($rv.nodes | length) then
       "  UNREADABLE: \($rv.totalCount) reviews exist, only \($rv.nodes | length) fit one page (review channel)"
     else empty end) ]
| join("\n")
JQ
}

# The jq program behind the COMMENT-channel half of `problems` (dotfiles-dev#490): the reviewer
# ladder's fallback review posts as a plain PR comment, never a review thread, so it was invisible
# to every filter above by construction -- the gate read one channel and called it "clean" for both.
#
# A ladder comment is identified by its first line matching the attribution marker AND an
# unforgeable authorAssociation (OWNER/MEMBER/COLLABORATOR) -- see _gate_ladder_marker_re's own
# comment for why the text match alone is not enough (CWE-345, lifted from #455).
#
# "Carried findings" is read from the body's STRUCTURE -- a "finding" heading or a `[Pn]` severity
# marker -- never from one runtime's severity vocabulary alone (the issue's own warning: codex and
# qwen's output shapes differ, and the rung resolved at run time is not fixed). A ladder review
# with neither is a clean report (dotfiles-dev#490's #438 fixture) and must not fire.
#
# "Answered" mirrors the thread path's own rule: a later, substantive (>= $min chars) comment --
# but the discriminator that stops a finding from being "answered" by ITSELF is comment IDENTITY
# (this comment's `id` is not the ladder comment's own `id`), never author identity.
#
# ⚠️ dotfiles-dev#511 (measured, its own comment ids/timestamps): the ladder posts its fallback
# review under the OPERATOR's own token (the only account authorAssociation trusts here), and the
# operator is also the only account that can reply to it -- so an author-INEQUALITY test made every
# ladder finding structurally unanswerable: ladder comment 5830451560 (guilhermegor, 09:55:56Z), a
# 900+ char substantive reply at 5830636642 (guilhermegor, 10:09:02Z), and the filter still reported
# `$answers == 0` because both share one login. `createdAt > $lc.createdAt` already excludes the
# ladder comment from counting itself (a comment cannot postdate its own timestamp); `.id` is kept
# as the explicit, unforgeable "not the same comment" guard the ordering alone does not name.
_gate_comment_findings_filter() {
	cat <<'JQ'
(.data.repository.pullRequest.comments.nodes // []) as $cs
| ($cs | map(select(
    (((.body // "") | split("\n")[0]) | test($marker))
    and ((.authorAssociation // "") | test("^(OWNER|MEMBER|COLLABORATOR)$"))
  ))) as $ladder
| $ladder[]
| . as $lc
| select(
    (($lc.body // "") | test("finding"; "i"))
    or (($lc.body // "") | test("\\[P[0-9]+\\]"))
  )
| ($cs
   | map(select(
       ((.id // "__missing__") != ($lc.id // "__ladder__"))
       and ((.createdAt // "") > ($lc.createdAt // ""))
       and (((.body // "") | length) >= $min)
       # A ladder review is a REPORT, never an answer to an earlier one. Excluding only
       # $lc.id let the NEXT fallback review clear this finding: it carries a distinct id,
       # a later timestamp and easily 100+ characters, so a second review saying "no issues
       # found" would silently satisfy a finding nobody addressed.
       and ((((.body // "") | split("\n")[0]) | test($marker)) | not)))
   | length) as $answers
| if $answers == 0 then "  unanswered ladder finding (comment channel)" else empty end
JQ
}

# The jq program behind `running`.
_gate_running_filter() {
	cat <<'JQ'
($roster | split("\n") | map(select(length > 0)) | map(ascii_downcase)
 | map(select(. != "github-actions"))) as $bots
| (.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts) as $c
| ([$c.nodes[]?
   | . as $n
   | if $n.__typename == "CheckRun" then
       select($n.status != "COMPLETED")
       | select(($bots | index(($n.checkSuite.app.slug // "") | ascii_downcase)) != null)
       | $n.name
     elif $n.__typename == "StatusContext" then
       select($n.state == "PENDING" or $n.state == "EXPECTED")
       | select(($bots | index(($n.creator.login // "") | ascii_downcase)) != null)
       | $n.context
     else empty end]
   + (if ($c.totalCount // 0) > ($c.nodes | length)
      then ["\($c.totalCount - ($c.nodes | length)) further check(s) this page could not read"]
      else [] end))
| join(", ")
JQ
}

# The jq program behind `unreviewed` (dotfiles-dev#505): has ANY roster reviewer reported on this
# PR at all -- via a submitted review object, a completion comment ("full review finished", the
# CodeRabbit marker CI's own workflow greps for), or a verified ladder review comment. Prints
# "true"/"false"; the caller reads it as a plain string, same pattern as the other filters.
#
# ⚠️ Derived from the ROSTER, never from `reviews | length` -- a human review by the PR's own
# author, or a bot outside the roster, must not count (the issue's own warning). No roster
# (__NO_ROSTER__) falls back to "any Bot account", the same fallback _gate_problems_filter already
# uses, via __typename rather than a forgeable login substring (CWE-345, dotfiles-dev#455).
_gate_reported_filter() {
	cat <<'JQ'
($roster | split("\n") | map(select(length > 0)) | map(ascii_downcase)) as $bots
| ($bots | index("__no_roster__")) as $no_roster
| (.data.repository.pullRequest.reviews.nodes // []) as $revs
| (.data.repository.pullRequest.comments.nodes // []) as $cs
| (.data.repository.pullRequest.commits.nodes[0].commit // {}) as $head
| ($head.oid // "") as $head_oid
| ($head.committedDate // "") as $head_date
| (def is_roster: . as $n
     | if $no_roster then (($n.author.__typename // "") == "Bot")
       else (($bots | index(($n.author.login // "") | ascii_downcase)) != null) end;
   # A report counts only if it is about the CURRENT head. A review carries the commit it
   # judged, so compare oids; a completion comment carries none, so the head's commit date is
   # the only available ordering. PENDING is a review the reviewer has not submitted -- it is
   # not a report at all. Fail closed: an unknown oid/date never satisfies the gate.
   ($revs | any(is_roster
                and ((.state // "") != "PENDING")
                and (($head_oid != "") and ((.commit.oid // "") == $head_oid))))
   or ($cs | any(is_roster
                 and (((.body // "") | ascii_downcase) | test("full review finished"))
                 and (($head_date != "") and ((.createdAt // "") >= $head_date))))
   or ($cs | any(
        (((.body // "") | split("\n")[0]) | test($marker))
        and ((.authorAssociation // "") | test("^(OWNER|MEMBER|COLLABORATOR)$"))
      )))
JQ
}

# _gate_run_jq JSON FILTER ERRFILE [jq args...]
# Run FILTER over JSON, echo jq's stdout, return jq's exit status, and leave jq's stderr in
# ERRFILE -- a path the CALLER owns, because a command substitution runs in a subshell and the
# helper cannot hand the text back through a variable.
#
# ⚠️ Returning the status is the entire point. `jq ... 2>/dev/null` with the status discarded
# turns a program ABORT into empty output, and empty output is exactly what "nothing to report"
# looks like -- so a crashed filter reaches the `clean` branch (dotfiles-dev#331). Measured on
# the #329 bug: under the workflow's `set -euo pipefail` the step died with a bare `exit code 5`,
# but called from a hook -- neither hook caller uses `set -e` -- the same broken filter returned
# GATE_STATUS=clean. The `set -e` was an accident of one caller, never a property of this gate.
_gate_run_jq() {
	local json="$1" filter="$2" errfile="$3"
	shift 3
	printf '%s' "$json" | jq -r "$@" "$filter" 2>"$errfile"
}

# Record the unreadable verdict for a filter that aborted, carrying jq's own words so the failure
# is diagnosable from the check output instead of needing a bisect -- #329 took one.
_gate_filter_aborted() {
	local errfile="$1" which="$2" detail
	detail="$(head -1 "$errfile" 2>/dev/null)"
	rm -f "$errfile"
	GATE_STATUS="unreadable"
	GATE_DETAIL="the $which filter aborted -- state unknown, not clean${detail:+: $detail}"
}

gate_pr_thread_state() {
	local owner="$1" repo="$2" number="$3" roster_file="${4:-.review-bots.yaml}"
	local threads roster problems truncated running comment_problems reported
	GATE_STATUS="unreadable"
	GATE_DETAIL="could not reach the GitHub API"

	local attempt attempts=3
	threads=""
	for attempt in $(seq 1 "$attempts"); do
		threads="$(gh api graphql -f query="$(_gate_query)" \
			-F owner="$owner" -F repo="$repo" -F number="$number" 2>/dev/null)" || threads=""
		# GraphQL answers 200 with a PARTIAL body: `errors` alongside a half-filled `data`.
		# Accepting that reads a truncated thread list as the whole truth.
		# ⚠️ Every stubbed `gh` fixture anywhere in the test suite that feeds this function must
		# include a `comments` key (even empty) or this check never passes and the gate exhausts
		# its retries into GATE_STATUS=unreadable — the exact break #497 caused in
		# tests/open_review_threads_nudge.bats and tests/review_threads_trigger.bats, whose
		# fixtures predated the `comments` field this query added for #490.
		if printf '%s' "$threads" | jq -e '
			(.errors | not)
			and (.data.repository.pullRequest.reviewThreads != null)
			and (.data.repository.pullRequest.comments != null)
		' >/dev/null 2>&1; then
			break
		fi
		threads=""
		[ "$attempt" -lt "$attempts" ] && sleep $((attempt * 3))
	done
	if [ -z "$threads" ]; then
		GATE_STATUS="unreadable"
		GATE_DETAIL="review threads unreadable after $attempts attempts — state unknown, not clean"
		return 0
	fi

	roster="$(_gate_roster_logins "$roster_file")"

	local jq_err
	jq_err="$(mktemp)"

	problems="$(_gate_run_jq "$threads" "$(_gate_problems_filter)" "$jq_err" \
		--argjson min "$_gate_min_reply_chars" --arg roster "$roster")" || {
		_gate_filter_aborted "$jq_err" "thread"
		return 0
	}

	# ⚠️ A single page is not the whole PR — a dropped thread reads exactly like an absent one.
	truncated="$(_gate_run_jq "$threads" "$(_gate_truncated_filter)" "$jq_err")" || {
		_gate_filter_aborted "$jq_err" "truncation"
		return 0
	}
	[ -n "$truncated" ] && problems="$(printf '%s\n%s' "$truncated" "$problems")"

	# The COMMENT channel (dotfiles-dev#490) -- the ladder's fallback review lives here, never in
	# reviewThreads above. Run and merged exactly like the thread-problems filter, so an unanswered
	# ladder finding turns the same GATE_STATUS=problems, naming its own channel in GATE_DETAIL.
	comment_problems="$(_gate_run_jq "$threads" "$(_gate_comment_findings_filter)" "$jq_err" \
		--argjson min "$_gate_min_reply_chars" --arg marker "$_gate_ladder_marker_re")" || {
		_gate_filter_aborted "$jq_err" "comment"
		return 0
	}
	[ -n "$comment_problems" ] && problems="$(printf '%s\n%s' "$problems" "$comment_problems")"

	# Reviewer checks (CheckRun or StatusContext) still running, minus the repo's own CI app.
	running="$(_gate_run_jq "$threads" "$(_gate_running_filter)" "$jq_err" --arg roster "$roster")" || {
		_gate_filter_aborted "$jq_err" "running-checks"
		return 0
	}

	# Has ANY roster reviewer reported at all (dotfiles-dev#505)? A PR nobody has looked at yet has
	# no threads and no comment-channel findings either, so it reaches here indistinguishable from
	# "reviewed, nothing to answer" unless this is checked as its own signal.
	reported="$(_gate_run_jq "$threads" "$(_gate_reported_filter)" "$jq_err" \
		--arg roster "$roster" --arg marker "$_gate_ladder_marker_re")" || {
		_gate_filter_aborted "$jq_err" "reviewer-reported"
		return 0
	}

	rm -f "$jq_err"

	if [ -n "$problems" ]; then
		GATE_STATUS="problems"
		GATE_DETAIL="$problems"
	elif [ -n "$running" ]; then
		GATE_STATUS="running"
		GATE_DETAIL="$running"
	elif [ "$reported" != "true" ]; then
		GATE_STATUS="unreviewed"
		GATE_DETAIL="no roster reviewer has submitted a review or posted a completion comment on this head"
	else
		GATE_STATUS="clean"
		GATE_DETAIL=""
	fi
}
