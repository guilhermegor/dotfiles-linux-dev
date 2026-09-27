#!/bin/bash
# Classifies a dev-loop round's read failure or CodeRabbit roster notice into the ONE limit it
# actually hit (dotfiles-dev#407). Two distinct quotas share the substring "rate limit" and mean
# OPPOSITE things:
#
#   1. the GITHUB API/GraphQL budget (a failed `gh`/REST/GraphQL call, HTTP 403/429) — the board
#      itself is unreadable; nothing about the reviewer is known. Terminal for this round:
#      retrying in a loop against an already-exhausted budget cannot succeed. Measured
#      2026-09-20 18:20:02Z: "API rate limit exceeded for user ID 55053188", HTTP 403, on
#      repos/{o}/{r}/issues/comments — and a sibling agent once burned 261k tokens re-diagnosing
#      the identical 403 across ten sweeps instead of stopping.
#   2. the CODERABBIT review-slot quota — a roster COMMENT the board successfully returned,
#      saying the reviewer is busy. The board is readable; only the reviewer isn't done yet.
#
# Misreading (1) as (2) makes a live loop believe the reviewer is busy when it actually went
# blind; misreading (2) as (1) throws away a perfectly good busy-signal as "unknown/unreadable".
# An unrecognised notice must classify UNKNOWN and never default to OK — same rule
# hooks/lib/free_surface.sh and hooks/lib/review_thread_gate.sh already apply to their own reads.
#
# ⚠️ Never classify from `gh api rate_limit` alone — that endpoint has been measured reporting
# quota it does not have. The ground truth is a REAL call's captured exit code/HTTP status/body;
# this library calls no API itself, it only classifies text a caller already captured.
set -u

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	echo "gh_budget.sh is meant to be sourced, not executed." >&2
	exit 1
fi

# gh_budget_classify TEXT
# Sets GH_BUDGET_CLASS to exactly one of:
#   github-api-limit        — the GitHub API/GraphQL budget is exhausted: the board is UNKNOWN
#                              this round, terminal, do not retry in a loop.
#   coderabbit-review-limit — CodeRabbit's own review-slot quota; board readable, reviewer busy.
#   coderabbit-chat-limit   — CodeRabbit's SEPARATE chat quota; review slot is untouched/free.
#   unknown                 — matched neither known signature; never treat as OK.
# Always returns 0 — classifying never fails, only the RESULT can be "unknown".
gh_budget_classify() {
	local text_lc
	text_lc="${1,,}"
	GH_BUDGET_CLASS="unknown"

	# GitHub's OWN api/graphql rate-limit error text, checked FIRST because it also contains the
	# substring "rate limit" that CodeRabbit's unrelated review-slot notice uses below.
	if [[ "$text_lc" == *"api rate limit exceeded"* ]] || [[ "$text_lc" == *"secondary rate limit"* ]]; then
		GH_BUDGET_CLASS="github-api-limit"
		return 0
	fi

	# CodeRabbit's chat quota, checked before the generic "rate limit" match below: its own
	# notice is identified by "chat message", independent of whether "rate limit" also appears.
	if [[ "$text_lc" == *"chat message"* ]]; then
		GH_BUDGET_CLASS="coderabbit-chat-limit"
		return 0
	fi

	if [[ "$text_lc" == *"rate limit"* ]]; then
		GH_BUDGET_CLASS="coderabbit-review-limit"
		return 0
	fi

	return 0
}

# gh_budget_is_terminal
# True (0) only right after gh_budget_classify found the GITHUB API budget itself exhausted —
# the signal that a round must stop and report UNKNOWN rather than retry (dotfiles-dev#407).
gh_budget_is_terminal() {
	[[ "${GH_BUDGET_CLASS:-}" == "github-api-limit" ]]
}

# --- 403 latch (dotfiles-dev#445) -----------------------------------------------------------------
# A hook-side twin of the agent-side lesson "the completion sweep retries a dead API until the
# agent's budget is spent": a 403 is terminal until GitHub's own reset, so re-probing every time a
# SubagentStop fires (measured: more than once per finished agent, unbounded with N agents) is pure
# waste. These three functions are the whole latch — write a marker on a real 403, and let any
# caller check it before spending a single gh call.

# gh_budget_latch_default_dir
# A private base directory for the default latch path — never bare /tmp, which is world-writable
# and lets another local user on a shared host disable the sweep indefinitely by pre-creating the
# predictable filename with a far-future timestamp (dotfiles-dev#511 review). Prefers
# $XDG_RUNTIME_DIR (already private, mode 0700, per the XDG spec — the check below only confirms
# it EXISTS, since a spec-compliant runtime dir is never created on demand by this script). Falls
# back to "$HOME/.cache" (created mode 0700 if missing). If even that mkdir fails (no $HOME, a
# read-only home, ...), this still falls back to bare /tmp as the last resort a caller with no
# private directory anywhere has left — gh_budget_latch_write's own write-failure check is what
# keeps THAT last-resort case from failing silently rather than pretending it is safe.
gh_budget_latch_default_dir() {
	if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ]; then
		printf '%s\n' "$XDG_RUNTIME_DIR"
		return 0
	fi
	# -m on `mkdir -p` only sets the mode of the DEEPEST directory (SC2174) — chmod separately so
	# ".cache" ends up 0700 even if $HOME itself had to be created too.
	if [ -n "${HOME:-}" ] && mkdir -p "$HOME/.cache" 2>/dev/null && chmod 700 "$HOME/.cache" 2>/dev/null; then
		printf '%s\n' "$HOME/.cache"
		return 0
	fi
	printf '%s\n' "/tmp"
}

# gh_budget_latch_path
# $GH_BUDGET_LATCH_FILE overrides it (tests, or a caller wanting a scoped marker); otherwise a
# fixed filename under gh_budget_latch_default_dir, shared by every dotfiles-dev hook process on
# this machine, since the exhausted budget is account-wide, never per-repo.
gh_budget_latch_path() {
	printf '%s\n' "${GH_BUDGET_LATCH_FILE:-$(gh_budget_latch_default_dir)/dotfiles-dev-sweep-403-until}"
}

# gh_budget_latch_write [TTL_SECONDS]
# Marks the budget exhausted until now+TTL. Default is $GH_BUDGET_LATCH_TTL, or 45s — a short
# burst-backoff, not a long guess — because callers are expected to pass an explicit TTL from
# gh_budget_reset_ttl() below once a real 403 has fired; this default only covers a caller that
# skips that step.
#
# Writes to a TEMP file in the same directory, then `mv` over the real path — never `>` directly
# on the marker (dotfiles-dev#511 review, CodeRabbit follow-up): a plain `>` truncates the file
# the instant it opens, before `printf` has written anything, so a concurrent
# gh_budget_latch_active() read in that window sees an EMPTY marker and treats the budget as not
# latched, triggering exactly the extra probe this file exists to avoid. `mv` on the same
# filesystem is atomic, so any concurrent reader sees either the old marker or the complete new
# one, never a partial write. The temp file lives next to the target (not $TMPDIR) so the `mv` is
# guaranteed same-filesystem — a cross-filesystem `mv` silently falls back to copy+unlink, which
# is not atomic.
#
# Returns 0 on a confirmed write, 1 (with a message on stderr) if either the temp write or the
# rename failed — e.g. the marker directory is owned by another user and not writable.
# dotfiles-dev#511 review: the old version discarded this status entirely (`2>/dev/null` with
# nothing checking `$?`), so a failed write meant the sweep silently kept re-running the full
# fan-out forever with no record of why the latch never took. Callers decide what to do with a
# failure; this function's only job is to stop hiding it.
gh_budget_latch_write() {
	local ttl="${1:-${GH_BUDGET_LATCH_TTL:-45}}" path tmp
	path="$(gh_budget_latch_path)"
	tmp="$path.tmp.$$"
	if ! printf '%s\n' "$(($(date +%s) + ttl))" >"$tmp" 2>/dev/null; then
		rm -f "$tmp" 2>/dev/null
		echo "gh_budget_latch_write: could not write latch marker at $path" >&2
		return 1
	fi
	if ! mv -f "$tmp" "$path" 2>/dev/null; then
		rm -f "$tmp" 2>/dev/null
		echo "gh_budget_latch_write: could not install latch marker at $path" >&2
		return 1
	fi
	return 0
}

# gh_budget_latch_active
# True (0) while a marker written by gh_budget_latch_write has not yet expired. False on no
# marker, an unparsable one, or an expired one — every one of those means "safe to call gh
# again", never "assume still exhausted".
gh_budget_latch_active() {
	local path until
	path="$(gh_budget_latch_path)"
	[ -f "$path" ] || return 1
	until="$(cat "$path" 2>/dev/null)"
	[[ "$until" =~ ^[0-9]+$ ]] || return 1
	[ "$(date +%s)" -lt "$until" ]
}

# gh_budget_reset_ttl [BURST_TTL]
# A measured TTL for gh_budget_latch_write, given a REAL 403/429 already fired — this never
# decides WHETHER the budget is exhausted (gh_budget_classify's job alone, off a real call's own
# error text, per this file's header). `gh api rate_limit` costs nothing against any budget, so
# once terminal is already known it is safe to spend one free call telling apart the two shapes
# a GitHub 403 actually has:
#   - primary exhaustion: `remaining` near zero on core or graphql — wait for the real `reset`.
#   - a secondary/concurrency burst: `remaining` still high — the documented quota was never
#     touched, and the right wait is seconds, not minutes.
# Measured dotfiles-dev#445 follow-up, 2026-09-25: two real 403s on this repo, both with core
# `remaining:5000/used:0` — a burst, not the documented quota, clearing in under a minute both
# times. A 300s fixed latch was suppressing the sweep ~5 minutes over a ~40s condition.
# Falls back to BURST_TTL (default 45s) on anything unreadable — an unreadable rate_limit read
# must never be upgraded to "assume primary exhaustion", since this file's own header already
# documents that endpoint reporting healthy quota it does not have; the failure mode of guessing
# wrong here is only an extra cheap probe, never a suppressed real 403.
gh_budget_reset_ttl() {
	local burst_ttl="${1:-45}" json now remaining reset resource ttl
	json="$(gh api rate_limit 2>/dev/null)" || {
		printf '%s\n' "$burst_ttl"
		return 0
	}
	now="$(date +%s)"
	for resource in core graphql; do
		remaining="$(printf '%s' "$json" | jq -r ".resources.$resource.remaining // empty" 2>/dev/null)"
		reset="$(printf '%s' "$json" | jq -r ".resources.$resource.reset // empty" 2>/dev/null)"
		if [[ "$remaining" =~ ^[0-9]+$ ]] && [ "$remaining" -lt 5 ] && [[ "$reset" =~ ^[0-9]+$ ]]; then
			ttl=$((reset - now))
			[ "$ttl" -gt 0 ] && printf '%s\n' "$ttl" && return 0
		fi
	done
	printf '%s\n' "$burst_ttl"
}

# gh_budget_quota_exhausted [FLOOR]
# True (0) when `gh api rate_limit` reports EITHER core or graphql `remaining` under FLOOR
# (default 5) — the one place this file deliberately reads rate_limit to decide exhaustion
# rather than only to size a TTL after a real call already failed (dotfiles-dev#511 review
# finding): gh_budget_gate's REST-only probe passes cleanly while GraphQL alone is exhausted, so
# every per-PR GraphQL call in the sweep's fan-out then fails one at a time with no latch ever
# written — the exact repeated-fan-out #445 exists to stop.
# This is safe against this file's OWN "never trust rate_limit alone" warning in only ONE
# direction: rate_limit has been measured UNDER-reporting exhaustion (a real burst 403 with
# remaining:5000/used:0 — see gh_budget_reset_ttl above), never OVER-reporting it, so a real,
# near-zero `remaining` here is not a false positive. It does NOT catch a burst (remaining stays
# high during one) — a burst still needs a real failed call, which is what the REST probe
# provides for its own budget.
gh_budget_quota_exhausted() {
	local floor="${1:-5}" json remaining resource
	json="$(gh api rate_limit 2>/dev/null)" || return 1
	for resource in core graphql; do
		remaining="$(printf '%s' "$json" | jq -r ".resources.$resource.remaining // empty" 2>/dev/null)"
		if [[ "$remaining" =~ ^[0-9]+$ ]] && [ "$remaining" -lt "$floor" ]; then
			return 0
		fi
	done
	return 1
}
