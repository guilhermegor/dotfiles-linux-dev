#!/bin/bash
# Reviewer fallback ladder (dotfiles-linux-dev#444): s:dev-loop step 4b has exactly one
# reviewer and stalls whenever its window is closed (measured on blueprintx
# 2026-09-21: 44 of 56 open PRs never reviewed while the primary reviewer's slot
# was rate-limited most of the day). This lib resolves the two fallback rungs —
# qwen, then codex — by MEASURED capability at run time, never by a hardcoded
# model name. The primary review bot stays step 4b's own existing item 3/4 logic
# (human request / bot ask); this lib only covers what happens when that rung is
# BUSY.
#
# 🔴 `priority` in ~/.codex/models_cache.json is NOT a capability rank — REJECTED
# as the selector. Measured 2026-09-21 on this account: `codex-auto-review`
# (a model named for reviewing) sits at priority 43; `gpt-5.5`, a general model,
# sits at 12. Ranking by priority would pick the general model over the
# review-specialised one while looking principled. Never read `.priority` below.
#
# 🔴 `visibility: list` is ALSO REJECTED as an entitlement proxy, for the same
# reason `priority` is rejected: it looked plausible and measurement disproved
# it. `codex-auto-review` is `visibility: hide` on this account and a live probe
# (`codex exec -m codex-auto-review "reply with the single word OK"`) returned
# OK anyway — hide means "not advertised in the picker", not "not entitled".
# Filtering on visibility would have discarded the one model actually built for
# this job. The only trustworthy entitlement signal is a live trivial call
# (_codex_entitlement_probe / _qwen_entitlement_probe below) — the cache and the
# settings file both list what EXISTS, never what this account is ENTITLED to
# call.
#
# Accepted capability signal, in priority order:
#   1. review-specialised slug (name matches /review/i) that PASSES the live
#      entitlement probe — the most specific evidence available.
#   2. richest `supported_reasoning_levels` set among the remaining models that
#      pass the probe — the only other machine-readable capability field the
#      cache exposes ("number of parameters" is not a field at all).
# Never falls back to guessing a name — a rung that resolves nothing is skipped
# and the ladder falls through to the next rung (fail closed).
#
# qwen exposes no cache-with-visibility/priority equivalent: `~/.qwen/settings.json`
# .modelProviders.openai[] is a flat id list with no rank field to reject. The
# account's own configured default (`.model.name`) is ranked first — it is
# already the entitled choice this account picked — then the rest ordered by
# richer reasoning support, and the winner is still live-probed like codex's.
# qwen ships a NATIVE `--fallback-model` flag (repeatable, max 3, for capacity
# errors 429/503/529) — this lib hands the runner-up candidates to THAT flag
# instead of reimplementing per-model retry; it only entitlement-probes the
# PRIMARY qwen candidate, not each fallback, because --fallback-model already
# covers the capacity-error case for the others.
set -u

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	echo "reviewer_ladder.sh is meant to be sourced, not executed." >&2
	exit 1
fi

LIB_DIR="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=../../../../lib/common.sh
source "$LIB_DIR/../../../../lib/common.sh" 2>/dev/null || true
# Deployed to ~/.claude/hooks/lib/ the relative common.sh above does not exist,
# so a `:` fallback would make every status line (including "no rung
# resolved") vanish — measured 2026-09-21: the first live dry run printed
# nothing at all. Fall back to plain stderr, never to silence.
declare -F print_status >/dev/null 2>&1 || print_status() { printf '%s: %s\n' "$1" "$2" >&2; }

# --- codex rung --------------------------------------------------------------

_codex_cache_path() {
	printf '%s\n' "${REVIEWER_LADDER_CODEX_CACHE:-$HOME/.codex/models_cache.json}"
}

# _codex_entitlement_probe SLUG
# A trivial live call, never a guess from the cache's own fields. Override via
# REVIEWER_LADDER_CODEX_PROBE for tests/dry-run — real tests and DRY_RUN=1 must
# never shell out to the real `codex` binary.
_codex_entitlement_probe() {
	local slug="$1"
	if [ -n "${REVIEWER_LADDER_CODEX_PROBE:-}" ]; then
		"$REVIEWER_LADDER_CODEX_PROBE" "$slug"
		return $?
	fi
	local out
	out="$(timeout "${REVIEWER_LADDER_PROBE_TIMEOUT:-30}" codex exec -m "$slug" \
		--skip-git-repo-check "reply with the single word OK" 2>/dev/null)" || return 1
	[[ "$out" == *OK* ]]
}

# resolve_codex_model
# Sets CODEX_MODEL / CODEX_MODEL_SIGNAL on success; both empty and returns 1 on
# failure (fail closed — malformed/missing cache, or nothing probes usable).
resolve_codex_model() {
	CODEX_MODEL=""
	CODEX_MODEL_SIGNAL=""
	local cache
	cache="$(_codex_cache_path)"
	[ -r "$cache" ] || return 1
	jq -e '.models | type == "array"' "$cache" >/dev/null 2>&1 || return 1

	local review_slugs slug
	review_slugs="$(jq -r '.models[] | select(.slug != null) | select(.slug | test("review"; "i")) | .slug' "$cache" 2>/dev/null)"
	while read -r slug; do
		[ -n "$slug" ] || continue
		if _codex_entitlement_probe "$slug"; then
			CODEX_MODEL="$slug"
			CODEX_MODEL_SIGNAL="review-specialized-slug"
			return 0
		fi
	done <<<"$review_slugs"

	# No review-specialised slug was invocable — rank the rest by the richest
	# supported_reasoning_levels set (descending count, slug as a deterministic
	# tie-break). `priority`/`visibility` are deliberately never read here —
	# see the header comment for the measured rejection of both.
	local ranked
	ranked="$(jq -r '
		.models
		| map(select(.slug != null))
		| sort_by([(- (.supported_reasoning_levels | length)), .slug])
		| .[].slug' "$cache" 2>/dev/null)"
	while read -r slug; do
		[ -n "$slug" ] || continue
		if _codex_entitlement_probe "$slug"; then
			CODEX_MODEL="$slug"
			CODEX_MODEL_SIGNAL="reasoning-levels-richness"
			return 0
		fi
	done <<<"$ranked"

	return 1
}

# --- qwen rung -----------------------------------------------------------

_qwen_settings_path() {
	printf '%s\n' "${REVIEWER_LADDER_QWEN_SETTINGS:-$HOME/.qwen/settings.json}"
}

# _qwen_entitlement_probe ID — same contract as the codex probe above.
_qwen_entitlement_probe() {
	local id="$1"
	if [ -n "${REVIEWER_LADDER_QWEN_PROBE:-}" ]; then
		"$REVIEWER_LADDER_QWEN_PROBE" "$id"
		return $?
	fi
	local out
	out="$(timeout "${REVIEWER_LADDER_PROBE_TIMEOUT:-30}" qwen -m "$id" \
		-p "reply with the single word OK" --output-format text 2>/dev/null)" || return 1
	[[ "$out" == *OK* ]]
}

# resolve_qwen_model
# Sets QWEN_MODEL / QWEN_MODEL_SIGNAL / QWEN_FALLBACK_MODELS (newline list, up
# to 2, handed to the native --fallback-model flag by the caller) on success;
# all empty and returns 1 on failure.
resolve_qwen_model() {
	QWEN_MODEL=""
	QWEN_MODEL_SIGNAL=""
	QWEN_FALLBACK_MODELS=""
	local settings
	settings="$(_qwen_settings_path)"
	[ -r "$settings" ] || return 1
	jq -e '.modelProviders.openai | type == "array"' "$settings" >/dev/null 2>&1 || return 1

	local default_id
	default_id="$(jq -r '.model.name // empty' "$settings" 2>/dev/null)"
	local ranked
	ranked="$(jq -r --arg def "$default_id" '
		.modelProviders.openai
		| map(select(.id != null))
		| sort_by([(if .id == $def then 0 else 1 end),
		           (if (.capabilities.reasoning.thinking // false) then 0 else 1 end),
		           .id])
		| .[].id' "$settings" 2>/dev/null)"

	local id winner="" fallbacks="" fallback_count=0
	while read -r id; do
		[ -n "$id" ] || continue
		if [ -z "$winner" ]; then
			if _qwen_entitlement_probe "$id"; then
				winner="$id"
				if [ "$id" = "$default_id" ]; then
					QWEN_MODEL_SIGNAL="configured-default"
				else
					QWEN_MODEL_SIGNAL="reasoning-capable"
				fi
			fi
		elif [ "$fallback_count" -lt 2 ]; then
			fallbacks="$(printf '%s\n%s' "$fallbacks" "$id" | sed '/^$/d')"
			fallback_count=$((fallback_count + 1))
		fi
	done <<<"$ranked"

	[ -n "$winner" ] || return 1
	QWEN_MODEL="$winner"
	QWEN_FALLBACK_MODELS="$fallbacks"
	return 0
}

# --- kimi / coderabbit / copilot rungs (dotfiles-linux-dev#626) -----------------
#
# Owner policy: every installed reviewer is a rung, and a rung is NEVER removed
# because it is currently paywalled — it fails its live probe and the ladder
# falls through. NEVER SPEND MONEY: no paid/credits flag (coderabbit's
# `--use-credits`) and no pay-per-use API key is ever passed or configured here.
# These CLIs expose no model list, so the model slug is the CLI's own default.

# _rung_probe RUNTIME OVERRIDE_VAR CMD...
# Runs a bounded live probe; REVIEWER_LADDER_<RT>_PROBE overrides it for tests.
_rung_probe() {
	local override="${!2:-}"
	if [ -n "$override" ]; then
		"$override" "$1"
		return $?
	fi
	shift 2
	timeout "${REVIEWER_LADDER_PROBE_TIMEOUT:-30}" "$@" 2>/dev/null
}

_kimi_entitlement_probe() {
	local out
	out="$(_rung_probe kimi REVIEWER_LADDER_KIMI_PROBE kimi -p "reply with the single word OK")" || return 1
	[[ "$out" == *OK* ]]
}

# `coderabbit review --usage` is the cheapest authenticated call: it reads the
# billing period and starts no review, so it consumes nothing.
_coderabbit_entitlement_probe() {
	_rung_probe coderabbit REVIEWER_LADDER_CODERABBIT_PROBE coderabbit review --usage >/dev/null
}

_copilot_entitlement_probe() {
	local out
	out="$(_rung_probe copilot REVIEWER_LADDER_COPILOT_PROBE copilot -s -p "reply with the single word OK")" || return 1
	[[ "$out" == *OK* ]]
}

# --- the ladder ------------------------------------------------------------

# LADDER_CLI_RUNGS: the single-model CLI rungs below qwen and codex, in order.
LADDER_CLI_RUNGS="kimi coderabbit copilot"

# resolve_fallback_reviewer
# Tries qwen, codex, then kimi, coderabbit, copilot — the rungs below the
# primary review bot. Sets LADDER_RUNTIME (qwen|codex|kimi|coderabbit|copilot|
# none), LADDER_MODEL, LADDER_SIGNAL, LADDER_FALLBACK_MODELS (qwen only).
# A rung that fails resolution/probe is skipped in one log line. Returns 1 with
# LADDER_RUNTIME=none ("no rung available") when none resolves — the ladder
# falls through, it never guesses a name.
resolve_fallback_reviewer() {
	LADDER_RUNTIME="none"
	LADDER_MODEL=""
	LADDER_SIGNAL=""
	LADDER_FALLBACK_MODELS=""

	if resolve_qwen_model; then
		LADDER_RUNTIME="qwen"
		LADDER_MODEL="$QWEN_MODEL"
		LADDER_SIGNAL="$QWEN_MODEL_SIGNAL"
		LADDER_FALLBACK_MODELS="$QWEN_FALLBACK_MODELS"
		return 0
	fi
	print_status "info" "rung qwen skipped: no entitled model"

	if resolve_codex_model; then
		LADDER_RUNTIME="codex"
		LADDER_MODEL="$CODEX_MODEL"
		LADDER_SIGNAL="$CODEX_MODEL_SIGNAL"
		return 0
	fi
	print_status "info" "rung codex skipped: no entitled model"

	local rung
	for rung in $LADDER_CLI_RUNGS; do
		if "_${rung}_entitlement_probe"; then
			LADDER_RUNTIME="$rung"
			LADDER_MODEL="default"
			LADDER_SIGNAL="live-probe"
			return 0
		fi
		print_status "info" "rung $rung skipped: probe failed (401/403, quota, expired login or timeout)"
	done

	return 1
}

# --- attribution, blast radius, posting -------------------------------------

# ladder_attribution_line RUNTIME MODEL SIGNAL HEAD_SHA
# The line every fallback review posts (issue #444 item 5) — a reader must
# never have to guess which reviewer produced a finding. issue #564: HEAD_SHA
# rides on a SECOND line ("Reviewed head: <sha>"), never appended to the
# first — the first line is matched by an `$`-anchored regex in three other
# places (review_thread_gate.sh's _gate_ladder_marker_re, and
# review_threads.yml:166/:276), and all three are first-line-anchored via
# `split("\n")[0]`/parameter expansion, never the whole body. Changing that
# line would stop every one of them from matching.
ladder_attribution_line() {
	local runtime="$1" model="$2" signal="$3" head_sha="$4"
	printf 'Fallback review — runtime: %s, model: %s (selected by: %s)\nReviewed head: %s\n' \
		"$runtime" "$model" "$signal" "$head_sha"
}

# ladder_poster_login
# The account _post_pr_comment posts as — `gh`'s authenticated user. Override
# via REVIEWER_LADDER_POSTER for tests. Empty on any gh error (the caller then
# matches no author, i.e. fails closed into "not covered").
ladder_poster_login() {
	if [ -n "${REVIEWER_LADDER_POSTER:-}" ]; then
		printf '%s\n' "$REVIEWER_LADDER_POSTER"
		return 0
	fi
	gh api user --jq '.login' 2>/dev/null
}

# ladder_already_covered COMMENTS_JSON HEAD_DATE HEAD_SHA
# True when a fallback attribution line already exists among a PR's comments,
# AUTHORED BY THE LADDER'S OWN POSTING ACCOUNT, and POSTED ON OR AFTER the
# CURRENT head's commit date — a lower rung never re-reviews what a higher one
# already covered FOR THIS HEAD. COMMENTS_JSON is the `gh api
# .../issues/N/comments` array (or any `[{author|user.login, body,
# created_at|createdAt}]` list); structured, never joined text, because any PR
# commenter can type the marker line and a text match would let them skip the
# review (CWE-345) — that check is unchanged by this function; freshness is an
# independent AND clause next to it.
#
# ⚠️ dotfiles-linux-dev#555: a marker predating the head reviewed a commit the head
# has since moved past and must NOT grant credit for the commit that replaced
# it — measured on #546, a marker 45 minutes older than the head still read as
# "already covered" and the ladder refused the fresh review that would have
# turned the required check green. HEAD_DATE unknown (empty, e.g. a `gh`
# error) fails CLOSED into "not covered", same direction as
# _gate_reported_filter's `$head_date != ""` guard — an unresolvable head
# never silently trusts a stale marker forever; worst case is one extra
# review, never a permanent skip.
#
# ⚠️ dotfiles-linux-dev#564: HEAD_DATE alone is not enough — it is the commit's own
# `committer.date`, which whoever pushes controls, so a backdated push can
# make a NEW head look OLDER than an EXISTING marker and inherit credit for
# code that marker never reviewed (CWE-345's narrower residual left by #555).
# HEAD_SHA is the second, independent AND clause that closes it: the marker's
# OWN second line ("Reviewed head: <sha>", written by ladder_attribution_line)
# must equal the CURRENT head SHA. Neither clause subsumes the other — HEAD_SHA
# answers "was this the same commit", HEAD_DATE still catches a marker written
# before the head existed at all. HEAD_SHA empty (unresolved) OR the marker
# carrying no second line at all (every marker written before this shipped)
# both fail CLOSED into "not covered" — one extra review is the acceptable
# cost, a permanent skip under a new name is not.
ladder_already_covered() {
	local comments="$1" head_date="${2:-}" head_sha="${3:-}" poster
	poster="$(ladder_poster_login)"
	[ -n "$poster" ] || return 1
	printf '%s' "$comments" | jq -e --arg who "$poster" --arg head_date "$head_date" --arg head_sha "$head_sha" '
		type == "array" and any(.[];
			((.author.login // .user.login // "") == $who)
			and ((.body // "") | test("^Fallback review — runtime:"; "m"))
			and (($head_date != "")
			     and ((.created_at // .createdAt // "") >= $head_date))
			and (($head_sha != "")
			     and ((((.body // "") | split("\n"))[1] // "") == ("Reviewed head: " + $head_sha))))
	' >/dev/null 2>&1 || return 1
}

# ladder_recently_pushed PUSHED_EPOCH NOW_EPOCH
# Mirrors step 4b's own "skip if pushed in the last ~10 minutes" rule (a push
# already triggers a re-review, so a fallback ask on top spends a rung for
# nothing).
ladder_recently_pushed() {
	local pushed="$1" now="$2"
	[ -n "$pushed" ] || return 1
	local age=$((now - pushed))
	[ "$age" -lt "${REVIEWER_LADDER_RECENT_PUSH_SECONDS:-600}" ]
}

# ladder_candidate_ok MERGE_STATE_STATUS PUSHED_EPOCH NOW_EPOCH
# The blast-radius gate (issue #444 item 6): not DIRTY, not pushed in the last
# ~10 minutes. "Sole blocker is the review gate" stays where step 4b already
# computes it (its own gh query in the skill) — not duplicated here.
ladder_candidate_ok() {
	local merge_state="$1" pushed="$2" now="$3"
	[ "$merge_state" != "DIRTY" ] || return 1
	! ladder_recently_pushed "$pushed" "$now"
}

# _review_base_ref
# The base `codex review --base` diffs against: REVIEWER_LADDER_BASE, else the
# remote's default branch as the current checkout knows it. Empty (return 1)
# when neither resolves — the caller fails closed rather than diffing against
# a guessed branch name.
_review_base_ref() {
	local base="${REVIEWER_LADDER_BASE:-}"
	if [ -z "$base" ]; then
		base="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)" || return 1
	fi
	# A name is not a ref: a typo in REVIEWER_LADDER_BASE or a dangling
	# origin/HEAD must fail closed here, not inside `codex review`.
	git rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1 || return 1
	printf '%s\n' "$base"
}

# _pr_head_sha OWNER REPO PR_NUMBER
# The forge's own answer for the PR's head commit — the ground truth a
# resolved checkout is asserted against (issue #487). Override via
# REVIEWER_LADDER_HEAD_SHA_CMD for tests. Empty on any `gh` error.
#
# REST, never GraphQL (issue #543): `gh pr view --json` is a GraphQL call,
# and this rung exists for when the forge is degraded — measured live
# 2026-09-27, GraphQL refused this exact call ("API rate limit already
# exceeded") while `gh api .../pulls/{n} --jq .head.sha` answered the same
# instant. A single scalar never needed GraphQL in the first place.
_pr_head_sha() {
	local owner="$1" repo="$2" pr_number="$3"
	if [ -n "${REVIEWER_LADDER_HEAD_SHA_CMD:-}" ]; then
		"$REVIEWER_LADDER_HEAD_SHA_CMD" "$owner" "$repo" "$pr_number"
		return $?
	fi
	gh api "repos/$owner/$repo/pulls/$pr_number" --jq '.head.sha' 2>/dev/null
}

# _pr_head_committed_at OWNER REPO PR_NUMBER
# The forge's own commit date for the PR's current head (issue #555): the ONLY
# ground truth `ladder_already_covered` can anchor a fallback-review marker's
# timestamp to. Without it, a marker that reviewed a since-superseded commit
# reads as covering the CURRENT head forever — the ladder's mirror image of
# #550. Override via REVIEWER_LADDER_HEAD_DATE_CMD for tests. Empty on any
# `gh` error (the caller then fails closed into "not covered" -- see
# ladder_already_covered).
#
# REST, never GraphQL, same reasoning as _pr_head_sha (issue #543): built on
# top of that same head-sha lookup, so a degraded GraphQL layer never blocks
# either call.
_pr_head_committed_at() {
	local owner="$1" repo="$2" pr_number="$3" sha
	if [ -n "${REVIEWER_LADDER_HEAD_DATE_CMD:-}" ]; then
		"$REVIEWER_LADDER_HEAD_DATE_CMD" "$owner" "$repo" "$pr_number"
		return $?
	fi
	sha="$(_pr_head_sha "$owner" "$repo" "$pr_number")"
	[ -n "$sha" ] || return 1
	gh api "repos/$owner/$repo/commits/$sha" --jq '.commit.committer.date' 2>/dev/null
}

# _pr_remote_url OWNER REPO
# The repository `_checkout_pr_worktree` fetches the PR's head FROM — always
# the forge's own owner/repo, never the caller's local `origin` remote
# (issue #487 review, CodeRabbit finding). `origin` can be a fork (no
# `refs/pull/*` at all — the codex rung would always refuse) or point at an
# unrelated repository (fetches a different PR's head entirely, though
# assert_worktree_matches_pr still catches that and fails closed). Override
# via REVIEWER_LADDER_REMOTE_URL_CMD for tests — real tests must never fetch
# over the network.
# ⚠️ For a PRIVATE repo this plain https URL needs a credential helper on
# PATH (e.g. `gh auth setup-git`, which this account's `gh` calls elsewhere
# already assume) — unverified beyond that; this lib does not itself manage
# credentials.
_pr_remote_url() {
	local owner="$1" repo="$2"
	if [ -n "${REVIEWER_LADDER_REMOTE_URL_CMD:-}" ]; then
		"$REVIEWER_LADDER_REMOTE_URL_CMD" "$owner" "$repo"
		return $?
	fi
	printf 'https://github.com/%s/%s.git\n' "$owner" "$repo"
}

# assert_worktree_matches_pr DIR OWNER REPO PR_NUMBER
# The severity of issue #487 in one check: a checkout is never trusted to be
# the PR's head just because something put it there — its HEAD must equal
# what the forge itself reports for that PR, checked live, every call.
# Fails closed (no match, no forge answer, no readable HEAD) rather than
# reviewing whatever happens to be at DIR.
#
# Sets ASSERT_WORKTREE_STATUS (issue #543) so the caller can tell an ABSENT
# forge answer from a CONTRADICTED one — those are different facts and only
# one of them means the checkout is wrong:
#   unanswerable — _pr_head_sha returned nothing (forge unreachable/refused)
#   mismatched   — a real answer came back, but HEAD differs (or unreadable)
#   matched      — HEAD equals the forge's answer
assert_worktree_matches_pr() {
	local dir="$1" owner="$2" repo="$3" pr_number="$4"
	local wanted got
	ASSERT_WORKTREE_STATUS="unanswerable"
	wanted="$(_pr_head_sha "$owner" "$repo" "$pr_number")"
	[ -n "$wanted" ] || return 1
	ASSERT_WORKTREE_STATUS="mismatched"
	got="$(git -C "$dir" rev-parse HEAD 2>/dev/null)" || return 1
	[ -n "$got" ] || return 1
	if [ "$got" = "$wanted" ]; then
		ASSERT_WORKTREE_STATUS="matched"
		return 0
	fi
	return 1
}

# _checkout_pr_worktree OWNER REPO PR_NUMBER
# Resolves the PR's head into its OWN detached worktree — never the caller's
# ambient cwd (issue #487: `codex review` diffs whatever is checked out, and
# nothing previously connected that to the PR number it was handed). Sets
# PR_WORKTREE_DIR on success. Override via REVIEWER_LADDER_CHECKOUT_CMD for
# tests — it must print the resolved worktree dir on success, nothing on
# failure, same contract as the real implementation.
_checkout_pr_worktree() {
	PR_WORKTREE_DIR=""
	local owner="$1" repo="$2" pr_number="$3"
	if [ -n "${REVIEWER_LADDER_CHECKOUT_CMD:-}" ]; then
		PR_WORKTREE_DIR="$("$REVIEWER_LADDER_CHECKOUT_CMD" "$owner" "$repo" "$pr_number")"
		[ -n "$PR_WORKTREE_DIR" ]
		return $?
	fi
	local dir url
	dir="$(mktemp -d "${TMPDIR:-/tmp}/reviewer-ladder-pr${pr_number}-XXXXXX")" || return 1
	url="$(_pr_remote_url "$owner" "$repo")"
	if ! git fetch --quiet "$url" "pull/$pr_number/head" 2>/dev/null ||
		! git worktree add --detach --quiet "$dir" FETCH_HEAD 2>/dev/null; then
		rmdir "$dir" 2>/dev/null
		return 1
	fi
	if ! assert_worktree_matches_pr "$dir" "$owner" "$repo" "$pr_number"; then
		if [ "$ASSERT_WORKTREE_STATUS" = "unanswerable" ]; then
			# issue #543: an ABSENT forge answer is not a CONTRADICTED one —
			# say which. This is the shape a GraphQL outage produces; the
			# checkout itself was never inspected.
			print_status "error" "PR #$pr_number: cannot reach the forge to verify the head — refusing"
		else
			print_status "error" "PR #$pr_number: checked-out HEAD does not match the forge's head — refusing"
		fi
		git worktree remove --force "$dir" 2>/dev/null
		return 1
	fi
	PR_WORKTREE_DIR="$dir"
}

# _teardown_pr_worktree DIR
# Torn down after every use, success or failure — a leaked worktree per
# ladder ask is its own slow failure (issue #487's own scope note).
_teardown_pr_worktree() {
	local dir="$1"
	[ -n "$dir" ] || return 0
	git worktree remove --force "$dir" 2>/dev/null || rm -rf "$dir" 2>/dev/null
}

# _run_runtime_review RUNTIME MODEL FALLBACKS PR_NUMBER [WORKDIR]
# Invokes the resolved CLI's own non-interactive review subcommand and prints
# its findings. Override via REVIEWER_LADDER_RUN_CMD for tests/dry-run — never
# executed when DRY_RUN=1 (run_fallback_review returns before reaching this).
# WORKDIR (default: caller's cwd) is where the codex arm runs: `codex review`
# reads the working tree, it does not fetch a PR by number (issue #487), so
# the caller must hand it a checkout already proven to be the PR's head —
# see _checkout_pr_worktree. qwen's own `review run PR_NUMBER` needs no
# checkout at all and ignores WORKDIR.
_run_runtime_review() {
	local runtime="$1" model="$2" fallbacks="$3" pr_number="$4" workdir="${5:-.}"
	if [ -n "${REVIEWER_LADDER_RUN_CMD:-}" ]; then
		"$REVIEWER_LADDER_RUN_CMD" "$runtime" "$model" "$fallbacks" "$pr_number"
		return $?
	fi
	case "$runtime" in
	codex)
		# `codex review` has no --skip-git-repo-check (that flag belongs to
		# `codex exec`, the probe); measured live 2026-09-21 on #447, the first
		# real run: "unexpected argument '--skip-git-repo-check'". `-m` is a
		# global option and stays before the subcommand.
		local base
		base="$(_review_base_ref)" || {
			print_status "error" "cannot resolve the review base (set REVIEWER_LADDER_BASE)"
			return 1
		}
		# `--base` and the positional [PROMPT] are mutually exclusive (measured
		# live on #434: "the argument '--base <BRANCH>' cannot be used with
		# '[PROMPT]'"); the PR label rides on --title instead.
		local output
		output="$(cd "$workdir" && codex -m "$model" review --base "$base" --title "PR #$pr_number")" || return 1
		# issue #487: an empty diff is never a legitimate review of an open PR
		# — it means the checkout matched the base, not the PR's head. Fail
		# closed instead of posting the runtime's own "nothing to say" text.
		if [ -z "$output" ] || [[ "$output" == *"No changes are present relative to the specified merge base"* ]]; then
			print_status "error" "codex reported an empty diff for PR #$pr_number — refusing to post it as a review"
			return 1
		fi
		# The comment must read as repo paths, never as this run's throwaway
		# worktree location — strip both the LOGICAL path handed to us and its
		# CANONICAL (symlink-resolved) form, since they can differ (e.g. macOS
		# `$TMPDIR` vs. its `/private/...` realpath) and either one can appear
		# verbatim in codex's own output.
		if [ "$workdir" != "." ]; then
			local real_workdir
			real_workdir="$(cd "$workdir" && pwd -P)" 2>/dev/null
			output="${output//"$workdir"\//}"
			if [ -n "$real_workdir" ] && [ "$real_workdir" != "$workdir" ]; then
				output="${output//"$real_workdir"\//}"
			fi
		fi
		printf '%s\n' "$output"
		;;
	qwen)
		local fb_args=() fb
		while read -r fb; do
			[ -n "$fb" ] || continue
			fb_args+=(--fallback-model "$fb")
		done <<<"$fallbacks"
		# No --json: that prints the raw result object, and the caller posts
		# this output verbatim as the review comment.
		qwen -m "$model" "${fb_args[@]}" review run "$pr_number"
		;;
	coderabbit)
		# Reviews the verified PR-head checkout against the base. Never
		# `--use-credits` or any paid flag (#626: no rung may spend money).
		local cr_base
		cr_base="$(_review_base_ref)" || {
			print_status "error" "cannot resolve the review base (set REVIEWER_LADDER_BASE)"
			return 1
		}
		(cd "$workdir" && timeout "${REVIEWER_LADDER_RUN_TIMEOUT:-900}" \
			coderabbit review --agent --base "$cr_base")
		;;
	kimi | copilot)
		# No review subcommand: hand the verified checkout's diff in the prompt,
		# so no tool permission (and no --yolo/--allow-all) is ever needed.
		local rv_base diff prompt
		rv_base="$(_review_base_ref)" || {
			print_status "error" "cannot resolve the review base (set REVIEWER_LADDER_BASE)"
			return 1
		}
		diff="$(git -C "$workdir" diff "${rv_base}...HEAD" | head -c 200000)"
		[ -n "$diff" ] || return 1
		prompt="Review PR #$pr_number. Report concrete bugs and risks as a markdown list with file:line. Diff:"$'\n'"$diff"
		if [ "$runtime" = "kimi" ]; then
			timeout "${REVIEWER_LADDER_RUN_TIMEOUT:-900}" kimi -p "$prompt"
		else
			timeout "${REVIEWER_LADDER_RUN_TIMEOUT:-900}" copilot -s -p "$prompt"
		fi
		;;
	*)
		return 1
		;;
	esac
}

# _post_pr_comment OWNER REPO PR_NUMBER BODY
# Override via REVIEWER_LADDER_POST_CMD for tests/dry-run.
#
# REST, never GraphQL (issue #543), same reasoning as _pr_head_sha: `gh pr
# comment` is GraphQL, and posting is the last step of the one rung meant to
# survive a degraded forge — measured live 2026-09-21, a correct review was
# produced then thrown away here with "GraphQL: API rate limit already
# exceeded" while REST stayed healthy throughout the same outage.
_post_pr_comment() {
	local owner="$1" repo="$2" pr_number="$3" body="$4"
	if [ -n "${REVIEWER_LADDER_POST_CMD:-}" ]; then
		"$REVIEWER_LADDER_POST_CMD" "$owner" "$repo" "$pr_number" "$body"
		return $?
	fi
	jq -n --arg b "$body" '{body: $b}' |
		gh api --method POST "repos/$owner/$repo/issues/$pr_number/comments" --input -
}

# run_fallback_review OWNER REPO PR_NUMBER MERGE_STATE PUSHED_EPOCH NOW_EPOCH COMMENTS_JSON [--dry-run]
# The one entrypoint callers use. One PR per call is the blast-radius cap
# (issue #444 item 6) — there is no loop-over-PRs form of this function.
# COMMENTS_JSON is the PR's issue-comment array as gh returns it (see
# ladder_already_covered). DRY_RUN=1 (env) or a trailing --dry-run resolves
# and prints the chosen rung+model WITHOUT invoking a runtime, probing, or
# posting anything (issue #444 item 7) — tests and manual verification MUST
# use this path. A dry run therefore reports the cache's top-ranked candidate
# UNPROBED: the probe is itself a live model call, and "no runtime" has to
# mean no runtime.
run_fallback_review() {
	local owner="$1" repo="$2" pr_number="$3" merge_state="$4" \
		pushed="$5" now="$6" comments="$7"
	local dry_run="${DRY_RUN:-0}"
	[ "${8:-}" = "--dry-run" ] && dry_run=1

	# issue #555: the head's own commit date anchors a marker's freshness.
	# issue #564: the head's own SHA anchors which commit the marker actually
	# reviewed. Both fetched once, up front, since ladder_already_covered has
	# no way to resolve either itself (it takes plain JSON in, never a `gh`
	# call).
	local head_date head_sha
	head_date="$(_pr_head_committed_at "$owner" "$repo" "$pr_number")"
	head_sha="$(_pr_head_sha "$owner" "$repo" "$pr_number")"

	# Every marker reader requires a non-empty SHA, so a review posted without
	# one is spent and can never count as coverage — the next run repeats it.
	# Fail closed BEFORE any model call rather than after.
	if [ -z "$head_sha" ]; then
		print_status "error" "PR #$pr_number: cannot resolve the head SHA — refusing to review without one"
		return 1
	fi

	if ladder_already_covered "$comments" "$head_date" "$head_sha"; then
		print_status "info" "PR #$pr_number already covered by a higher rung — skipping"
		return 0
	fi
	if ! ladder_candidate_ok "$merge_state" "$pushed" "$now"; then
		print_status "info" "PR #$pr_number is not a fallback candidate (DIRTY or recently pushed)"
		return 1
	fi

	# Dynamic scoping: these locals are what the probes read while we are on
	# the stack, so a dry run never reaches the real `codex`/`qwen` binaries.
	# `true` accepts every candidate, which is exactly "unprobed".
	local REVIEWER_LADDER_CODEX_PROBE="${REVIEWER_LADDER_CODEX_PROBE:-}" \
		REVIEWER_LADDER_QWEN_PROBE="${REVIEWER_LADDER_QWEN_PROBE:-}" \
		REVIEWER_LADDER_KIMI_PROBE="${REVIEWER_LADDER_KIMI_PROBE:-}" \
		REVIEWER_LADDER_CODERABBIT_PROBE="${REVIEWER_LADDER_CODERABBIT_PROBE:-}" \
		REVIEWER_LADDER_COPILOT_PROBE="${REVIEWER_LADDER_COPILOT_PROBE:-}"
	if [ "$dry_run" = "1" ]; then
		: "${REVIEWER_LADDER_CODEX_PROBE:=true}"
		: "${REVIEWER_LADDER_QWEN_PROBE:=true}"
		: "${REVIEWER_LADDER_KIMI_PROBE:=true}"
		: "${REVIEWER_LADDER_CODERABBIT_PROBE:=true}"
		: "${REVIEWER_LADDER_COPILOT_PROBE:=true}"
	fi

	if ! resolve_fallback_reviewer; then
		print_status "warning" "no rung available (qwen, codex, kimi, coderabbit, copilot all unavailable)"
		return 1
	fi

	local attribution
	attribution="$(ladder_attribution_line "$LADDER_RUNTIME" "$LADDER_MODEL" "$LADDER_SIGNAL" "$head_sha")"

	if [ "$dry_run" = "1" ]; then
		print_status "info" "DRY RUN (candidates unprobed) — would probe, then post to PR #$pr_number: $attribution"
		return 0
	fi

	# Only codex reads the working tree (issue #487) — qwen's own
	# `review run PR_NUMBER` already fetches the PR itself. Resolving a
	# worktree only when it is actually needed keeps qwen's rung free of a
	# fetch+worktree round trip it has no use for.
	local workdir="." worktree_dir=""
	if [[ " codex $LADDER_CLI_RUNGS " == *" $LADDER_RUNTIME "* ]]; then
		if ! _checkout_pr_worktree "$owner" "$repo" "$pr_number"; then
			print_status "error" "PR #$pr_number: cannot check out a verified head for codex — refusing to review"
			return 1
		fi
		workdir="$PR_WORKTREE_DIR"
		worktree_dir="$PR_WORKTREE_DIR"
	fi

	local findings rc=0
	findings="$(_run_runtime_review "$LADDER_RUNTIME" "$LADDER_MODEL" "$LADDER_FALLBACK_MODELS" "$pr_number" "$workdir")" || rc=1
	[ -n "$worktree_dir" ] && _teardown_pr_worktree "$worktree_dir"
	[ "$rc" -eq 0 ] || return 1

	local body
	body="$attribution"$'\n\n'"$findings"
	_post_pr_comment "$owner" "$repo" "$pr_number" "$body"
}
