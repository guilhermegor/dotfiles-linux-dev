#!/bin/bash
# PreToolUse (Bash matcher) hook: refuse `gh pr merge` while any review thread is unanswered or
# unresolved, OR while a reviewer's check on the head commit is still mid-flight. Queries GitHub
# LIVE, at the moment of merging.
#
# Why a hook and not a rule: the rule already existed, in prose, in three places, and was
# violated anyway. blueprintx PR #180 merged with two review threads open and unanswered, and
# every visible signal said it was fine. The failure needs no carelessness — it is structural:
#
#   1. CI evaluates review threads on `pull_request`, which fires WHEN YOU PUSH. A reviewer
#      posting after your last push does not re-trigger it, so the green check is a conclusion
#      about a PR state that no longer exists. A stale check looks exactly like a passing one.
#   2. A reviewer bot resolves its OWN threads on seeing the fix, so `isResolved` records the
#      bot's satisfaction rather than the author's reasoning — the reply can be missing while
#      everything reads closed.
#   3. Whoever merges is the same person who would have to remember to re-check. Any rule of the
#      form "remember to look again just before merging" is exactly the kind that fails.
#
# So this fires at the only moment that cannot go stale: immediately before the merge call.
# It is the LAST of three layers, each covering what the others cannot —
#   - GitHub's `required_conversation_resolution` ruleset: server-side, live, but enforces only
#     the RESOLVE half; it cannot tell a reply from silence.
#   - the repo's CI gate: checks both halves, but only when something re-triggers it.
#   - this guard: both halves, live, on the merge itself.
#
# A fourth question, added by dotfiles-linux-dev#379: the three layers above all ask "is every thread
# FINISHED?", and a PR with ZERO threads satisfies that vacuously — it cannot distinguish "the
# reviewer looked and found nothing" from "the reviewer has not spoken yet". Measured on #376:
# merged with CodeRabbit's check still PENDING and `reviewThreads.nodes == []`; three Major
# findings landed minutes later. So this guard additionally blocks while a reviewer's check
# (CheckRun/StatusContext, matched against `.review-bots.yaml`) sits in a non-terminal state on
# the PR's head commit — `statusCheckRollup` is inherently head-scoped, which is what makes it
# the right signal here (a *review object*, by contrast, is only created when the reviewer has a
# finding — dotfiles-linux-dev#378 finished with an empty thread list, an empty `reviews.nodes`, AND a
# terminal SUCCESS check, and that is the ordinary shape of a clean PR, not a red flag).
# Once the check reaches a terminal state, the existing thread logic above is the whole verdict
# again — zero threads plus a terminal check means "reviewed, nothing found", not "unreviewed".
# Same fail-open principle as everywhere else in this file: a repo with no roster, or a reviewer
# with no check in the rollup yet, is silent on this axis — dotfiles-dev has exactly one
# maintainer and a structurally empty Reviewers panel (#268), and a guard that demanded a
# reviewer's presence would brick every merge here.
#
# A fifth question, dotfiles-linux-dev#462: `--auto` does not merge anything — it tells GitHub to
# merge only once every REQUIRED check goes green, which includes the very reviewer check this
# guard is waiting for. So the guard was blocking the one form of the command that already
# honours its own rule, and the state it protects against (merging past an unfinished review)
# cannot occur through `--auto`. Detected off the real argv via `hooks/lib/gh_cmd_match.py`
# (never a regex over the raw command text — a `--auto` inside a quoted `--title`/`--body`
# value must not count, same reasoning as the body-template guards). An unparseable command is
# "unknown", not "has --auto", and keeps today's blocking behaviour.
#
# Hook I/O contract: PreToolUse exit 2 BLOCKS the call and feeds stderr back to the model.
# It fails OPEN on anything it cannot resolve (no gh, no jq, no network, no PR, a PR in another
# repo) — a guard that blocks on its own blindness gets disabled, and then protects nothing.

set -u

command -v jq >/dev/null 2>&1 || exit 0
command -v gh >/dev/null 2>&1 || exit 0

# Prefixing the command makes the guard stand aside, for the rare deliberate case. Covers BOTH
# conditions below (unfinished threads and a still-running reviewer check) — one hatch, because
# it is the same "I am deliberately merging before review settles" override either way:
#   ALLOW_UNRESOLVED_THREADS=1 gh pr merge 123 --squash
ESCAPE_HATCH='ALLOW_UNRESOLVED_THREADS=1'

# Floor for a "substantive" reply, matching the repo-side gate: excludes "done" / "fixed"
# without ever arguing with a real answer.
MIN_REPLY_CHARS=100

ROSTER_FILE='.review-bots.yaml'

read_query() {
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
      commits(last:1) {
        nodes {
          commit {
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

# Reviewer logins whose comments are FINDINGS, never answers.
#
# ⚠️ Normalised WITHOUT the `[bot]` suffix. REST reports `coderabbitai[bot]` and the roster is
# written that way, but GraphQL's `author.login` returns `coderabbitai`. Comparing the two
# spellings literally is what made the repo-side gate silently vacuous for its whole life — it
# reported "all threads answered" on a PR where nobody had replied to anything.
roster_logins() {
	if [ -f "$ROSTER_FILE" ]; then
		sed -n 's/^[[:space:]]*-[[:space:]]*login:[[:space:]]*//p' "$ROSTER_FILE" \
			| sed 's/\[bot\]$//' | sed '/^$/d'
		return 0
	fi
	# No roster: fall back to treating any bot account as a reviewer, resolved per comment in the
	# jq filter below.
	#
	# ⚠️ The discriminator there is `author.__typename == "Bot"`, NOT a `[bot]` login suffix.
	# GraphQL strips that suffix (the warning above), so a suffix test matched NOTHING and every
	# bot counted as a human reply. Measured on this repo, which ships no roster: all 11
	# CodeRabbit findings on dotfiles-linux-dev#127 were reported as "replied" when nobody had replied
	# to any of them. `__typename` is the API's own answer to the question and cannot drift.
	printf '__NO_ROSTER__\n'
}

main() {
	local payload tool command number repo owner name threads roster problems running

	payload="$(cat)"
	tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"
	[[ "$tool" == "Bash" ]] || exit 0

	command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
	[[ -n "$command" ]] || exit 0

	# Only `gh pr merge`, with or without the rtk proxy prefix.
	printf '%s' "$command" \
		| grep -Eq '(^|[;&|][[:space:]]*)(rtk[[:space:]]+)?gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)' \
		|| exit 0

	# Explicit opt-out.
	printf '%s' "$command" | grep -q "$ESCAPE_HATCH" && exit 0

	# `--auto` off the REAL argv (dotfiles-linux-dev#462, see the header). Stand aside only when the
	# matcher positively reports both `matched` and `auto`; every other outcome -- no python3,
	# an untokenizable command, a `--auto` that lives inside a quoted value -- leaves the checks
	# below running, so uncertainty keeps today's blocking behaviour rather than waving a merge
	# through on a guess.
	if command -v python3 >/dev/null 2>&1; then
		local match_json
		if match_json="$(printf '%s' "$command" \
			| python3 "$(dirname "${BASH_SOURCE[0]}")/lib/gh_cmd_match.py" pr 2>/dev/null)" \
			&& [[ -n "$match_json" ]] \
			&& [[ "$(printf '%s' "$match_json" | jq -r '.matched and .auto' 2>/dev/null)" == "true" ]]; then
			exit 0
		fi
	fi

	# The MERGE TARGET, not "whatever PR this branch happens to be on".
	#
	# ⚠️ `gh pr merge` takes its target as a number, a branch name OR a URL, in any position among
	# the flags, and `--repo` can aim the whole call at another repository. Matching only a number
	# glued to `gh pr merge` meant `gh pr merge --squash 42` fell through to the current branch:
	# the guard then vetted a DIFFERENT PR than the one being merged, and a clean branch PR waved
	# through a merge of a PR with open threads — the guard reporting on the wrong subject is
	# worse than no guard, because it reads as a pass.
	#
	# `gh pr view` already resolves all three spellings, so the parsing job is only to find the
	# first positional and the `--repo` value. Its `.url` then carries owner/repo, which is why
	# `gh repo view` is gone: that one always answered about the CURRENT directory.
	local -a toks=() view_args=()
	local tok target="" repo_arg="" i j
	read -ra toks <<<"$(printf '%s' "$command" | tr '\n' ' ')"
	for ((i = 1; i < ${#toks[@]}; i++)); do
		[[ "${toks[i]}" == "merge" && "${toks[i - 1]}" == "pr" ]] && break
	done
	for ((j = i + 1; j < ${#toks[@]}; j++)); do
		tok="${toks[j]}"
		case "$tok" in
			--repo=*) repo_arg="${tok#*=}"; continue ;;
			--repo | -R) repo_arg="${toks[j + 1]:-}"; ((j++)); continue ;;
			# Flags that consume the next token. Skipping the VALUE too is the point: without it a
			# word inside `--body "fix the thing"` reads as a branch name and becomes the target.
			--body | -b | --body-file | -F | --subject | -t | --author-email | -A | --match-head-commit)
				((j++)); continue ;;
			-*) continue ;;
		esac
		# gh accepts exactly one positional, so the first one is the target.
		[ -z "$target" ] && target="$tok"
	done
	# Anything that cannot be a number, a URL or a branch name is quoting debris, not a target.
	[[ -n "$target" && ! "$target" =~ ^([0-9]+|https?://[^[:space:]]+|[A-Za-z0-9][A-Za-z0-9._/-]*)$ ]] \
		&& target=""
	[ -n "$target" ] && view_args+=("$target")
	[ -n "$repo_arg" ] && view_args+=(--repo "$repo_arg")

	local pr_json url
	pr_json="$(gh pr view "${view_args[@]}" --json number,url 2>/dev/null)" || exit 0
	number="$(printf '%s' "$pr_json" | jq -r '.number // empty' 2>/dev/null)"
	[[ "$number" =~ ^[0-9]+$ ]] || exit 0

	url="$(printf '%s' "$pr_json" | jq -r '.url // empty' 2>/dev/null)"
	repo="${url#*://*/}"
	repo="${repo%%/pull/*}"
	owner="${repo%%/*}"
	name="${repo##*/}"
	[[ -n "$owner" && -n "$name" && "$owner" != "$repo" ]] || exit 0

	threads="$(gh api graphql -f query="$(read_query)" \
		-F owner="$owner" -F repo="$name" -F number="$number" 2>/dev/null)" || exit 0
	printf '%s' "$threads" | jq -e '.data.repository.pullRequest.reviewThreads' >/dev/null 2>&1 \
		|| exit 0

	roster="$(roster_logins)"

	# A thread is FINISHED when it holds a substantive comment from outside the reviewer roster
	# AND is resolved. Anything else is reported, with the reason.
	problems="$(printf '%s' "$threads" | jq -r \
		--argjson min "$MIN_REPLY_CHARS" \
		--arg roster "$roster" '
		($roster | split("\n") | map(select(length > 0))) as $bots
		| .data.repository.pullRequest.reviewThreads.nodes[]
		| . as $t
		| ($t.comments.nodes
		   | map(select(
		       (if ($bots | index("__NO_ROSTER__"))
		        then ((.author.__typename // "") != "Bot")
		        else ($bots | index(.author.login // "") | not) end)
		       and ((.body // "" | length) >= $min)))
		   | length) as $answers
		| if $answers == 0 then
		    "  \($t.path // "?"): no reply from anyone outside the reviewer roster"
		  elif ($t.isResolved | not) then
		    "  \($t.path // "?"): replied, but the conversation is still OPEN"
		  else empty end
	' 2>/dev/null)"

	# ⚠️ A single page is not the whole PR. `first:100` / `first:50` silently DROP whatever does
	# not fit, and a dropped thread reads exactly like an absent one — a false "all clean", the
	# one verdict this must never emit by accident. Cursor pagination in bash for two nested
	# connections buys nothing here: the counts already say when a page is short, and "I cannot
	# see all of it" is the honest report either way.
	local truncated
	truncated="$(printf '%s' "$threads" | jq -r '
		.data.repository.pullRequest.reviewThreads as $rt
		| [ (if ($rt.totalCount // 0) > ($rt.nodes | length) then
		       "  UNREADABLE: \($rt.totalCount) review threads exist, only \($rt.nodes | length) fit one page"
		     else empty end),
		    ($rt.nodes[]
		     | select((.comments.totalCount // 0) > (.comments.nodes | length))
		     | "  UNREADABLE: \(.path // "?"): \(.comments.totalCount) comments, only \(.comments.nodes | length) read") ]
		| join("\n")' 2>/dev/null)"
	[ -n "$truncated" ] && problems="$(printf '%s\n%s' "$truncated" "$problems")"

	# A reviewer's check still mid-flight on THIS head commit (statusCheckRollup is inherently
	# head-scoped) is the "reviewer has not spoken yet" case an empty thread list cannot express.
	# Silent (no match) whenever there is no roster, or the roster's check has not appeared in the
	# rollup at all — the fail-open floor, same reasoning as roster_logins()'s __NO_ROSTER__ path.
	#
	# ⚠️ `index()` binds `.` to ITS OWN INPUT (the $bots array), not the checked-in object — the
	# same fault review_thread_gate.sh's header warns about. `. as $ctx` first, then `$ctx.…`
	# inside the index() argument, is what keeps the lookup pointed at the check, not the array.
	running="$(printf '%s' "$threads" | jq -r \
		--arg roster "$roster" '
		($roster | split("\n") | map(select(length > 0 and . != "__NO_ROSTER__")) | map(ascii_downcase)
		 | map(select(. != "github-actions"))) as $bots
		| if ($bots | length) == 0 then empty else
		    (.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes // [])[]
		    | . as $ctx
		    | if $ctx.__typename == "CheckRun" then
		        select($ctx.status != "COMPLETED")
		        | select(($bots | index(($ctx.checkSuite.app.slug // "") | ascii_downcase)) != null)
		        | "  \($ctx.name // "?"): reviewer check is \($ctx.status) — review still running"
		      elif $ctx.__typename == "StatusContext" then
		        select($ctx.state == "PENDING" or $ctx.state == "EXPECTED")
		        | select(($bots | index(($ctx.creator.login // "") | ascii_downcase)) != null)
		        | "  \($ctx.context // "?"): reviewer check is \($ctx.state) — review still running"
		      else empty end
		  end
	' 2>/dev/null)"

	[[ -z "$problems" && -z "$running" ]] && exit 0

	{
		echo "BLOCKED: PR #${number}'s review is not finished."
		echo
		if [ -n "$running" ]; then
			echo "Review still running:"
			printf '%s\n' "$running"
			echo
		fi
		if [ -n "$problems" ]; then
			echo "Review threads not finished:"
			printf '%s\n' "$problems"
			echo
			echo "A finding takes BOTH halves, and neither implies the other:"
			echo "  1. REPLY with what changed and why — a reviewer bot resolving its own thread"
			echo "     records ITS satisfaction, never your reasoning, and the reasoning is what"
			echo "     the next session reads."
			echo "  2. RESOLVE the conversation once the reply is posted — otherwise nothing"
			echo "     distinguishes a finished exchange from one still in progress."
			echo
		fi
		echo "Checked live: CI evaluates threads on push, so a review arriving after your last"
		echo "push leaves that check green while showing a state that no longer exists — and an"
		echo "EMPTY thread list means nothing while the reviewer's own check is still running."
		echo
		echo "Deliberate exception: ${ESCAPE_HATCH} <your command>"
	} >&2
	exit 2
}

main "$@"
