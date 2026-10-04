#!/bin/bash
# Reviewer-rung capability probe (dotfiles-linux-dev#479), sourced by session_start_context.sh
# so it fires once per session, not once per s:dev-loop step-4b round.
#
# reviewer_ladder.sh silently skips any rung that resolves nothing — correct ladder
# behaviour ("a rung that resolves nothing is skipped ... it never guesses a name"),
# and completely unobservable: a runtime nobody ever wired looks identical to one
# that was tried and declined. Measured on this machine 2026-09-23:
#   - kimi is on PATH (~/.asdf/installs/nodejs/25.4.0/bin/kimi) and
#     `grep -c kimi reviewer_ladder.sh` returns 0 — installed, never wired.
#   - coderabbit v0.7.6 is on PATH (~/.local/bin/coderabbit), wired nowhere, and
#     `coderabbit auth status` reports "signed out" — installed, unusable.
#
# Three independent columns per rung, because any two can be true while the third
# is false: on PATH, wired into the ladder, authenticated/usable. Warn only on the
# two ACTIONABLE combinations (installed-but-unwired, installed-but-unauthenticated)
# — a rung that is simply absent is not a finding, nobody promised it would be there.
#
# No live entitlement probe here for codex/qwen: reviewer_ladder.sh's own
# _codex_entitlement_probe / _qwen_entitlement_probe shell out to the real CLI and
# cost real request time — running that every session start would spend the exact
# budget the ladder exists to conserve. Only CodeRabbit ships a cheap, local,
# non-interactive `auth status` read; codex/qwen/kimi report "unknown" for the
# authenticated column by design (a documented limitation, not a probe failure) and
# never trigger a report line on that column alone.
set -u

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	echo "reviewer_probe.sh is meant to be sourced, not executed." >&2
	exit 1
fi

# The rung's own binary IS the ladder-membership signal — reviewer_ladder.sh
# invokes each runtime by this exact name (`codex exec`, `qwen -m`, ...).
_reviewer_probe_ladder_file() {
	printf '%s\n' "${REVIEWER_PROBE_LADDER_FILE:-$(dirname "${BASH_SOURCE[0]}")/reviewer_ladder.sh}"
}

# _reviewer_probe_wired BIN — "yes"/"no"/"unknown". unknown only when the ladder
# file itself can't be read (a broken/partial deploy) — never silently "no", which
# would misreport a deploy problem as a wiring gap.
_reviewer_probe_wired() {
	local bin="$1" ladder
	ladder="$(_reviewer_probe_ladder_file)"
	if [ ! -r "$ladder" ]; then
		printf 'unknown\n'
		return 0
	fi
	# ⚠️ Matches the ladder's SELECTION PATH, not the runtime's NAME. The name
	# appears throughout reviewer_ladder.sh in prose, so a bare substring grep
	# answered "is this runtime mentioned?" while claiming to answer "is it
	# wired?". Measured: appending the single comment line
	#   `# kimi was evaluated as a rung and deliberately NOT wired here.`
	# flipped kimi from no to yes -- a comment SAYING a rung is unwired
	# suppressed the installed-but-unwired report about it. The `case "$runtime"`
	# label in _run_runtime_review is what actually dispatches a rung; comments
	# are stripped first so prose can never reach the match.
	if grep -v '^[[:space:]]*#' "$ladder" 2>/dev/null |
		grep -Eq "^[[:space:]]*${bin}\)"; then
		printf 'yes\n'
	else
		printf 'no\n'
	fi
}

# _reviewer_probe_coderabbit_auth_status — the real, bounded local check. Never
# called directly by a test; REVIEWER_PROBE_CODERABBIT_AUTH_CMD (a function/command
# name, same override contract as reviewer_ladder.sh's own *_PROBE hooks) replaces
# it in tests so a bats run never shells out to the real coderabbit binary.
_reviewer_probe_coderabbit_auth_status() {
	timeout "${REVIEWER_PROBE_TIMEOUT:-5}" coderabbit auth status
}

# _reviewer_probe_auth RUNTIME — "yes"/"no"/"unknown". Only coderabbit has a cheap
# local check; see the header for why codex/qwen/kimi always report "unknown".
_reviewer_probe_auth() {
	local runtime="$1"
	case "$runtime" in
	coderabbit)
		local out
		out="$("${REVIEWER_PROBE_CODERABBIT_AUTH_CMD:-_reviewer_probe_coderabbit_auth_status}" 2>/dev/null)"
		case "$out" in
		*"signed out"*) printf 'no\n' ;;
		*"logged in"* | *"authenticated"*) printf 'yes\n' ;;
		*) printf 'unknown\n' ;;
		esac
		;;
	*)
		printf 'unknown\n'
		;;
	esac
}

# _reviewer_probe_rung BIN RUNTIME — prints one report line iff this rung's state is
# actionable. Silent for an absent rung (not on PATH — never a finding) and for a
# rung that is on PATH, wired, and not known to be unauthenticated.
_reviewer_probe_rung() {
	local bin="$1" runtime="$2"
	command -v "$bin" >/dev/null 2>&1 || return 0

	local wired auth
	wired="$(_reviewer_probe_wired "$bin")"
	auth="$(_reviewer_probe_auth "$runtime")"

	# Fully fine: wired, and not known-unauthenticated (auth "unknown" is the
	# documented default for codex/qwen/kimi, not itself a finding).
	[ "$wired" = "yes" ] && [ "$auth" != "no" ] && return 0

	local wired_desc="not wired into the ladder"
	[ "$wired" = "unknown" ] && wired_desc="wiring state unknown (ladder file unreadable)"
	[ "$wired" = "yes" ] && wired_desc="wired"

	local auth_desc="usable state unknown"
	[ "$auth" = "no" ] && auth_desc="NOT authenticated"
	[ "$auth" = "yes" ] && auth_desc="authenticated"

	printf '  - %s: on PATH, %s, %s\n' "$runtime" "$wired_desc" "$auth_desc"
}

# emit_reviewer_probe_status — one [reviewers] block; silent when every rung is
# either absent or fully fine. Never fails the session: every sub-check above
# fails open into "unknown" rather than aborting.
emit_reviewer_probe_status() {
	local lines
	lines="$(
		_reviewer_probe_rung codex codex
		_reviewer_probe_rung qwen qwen
		_reviewer_probe_rung kimi kimi
		_reviewer_probe_rung coderabbit coderabbit
	)"
	[ -n "$lines" ] || return 0

	printf '%s\n' "[reviewers] rung(s) with an actionable gap (installed but unwired or unauthenticated):"
	printf '%s\n' "$lines"
}
