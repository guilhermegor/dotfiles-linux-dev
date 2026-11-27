#!/bin/bash
# One-shot "jq is missing" notice for Stop hooks (dotfiles-linux-dev#1169).
#
# A Stop hook cannot fail closed without jq: its stop_hook_active loop-break is read through jq, so
# exit 2 would refuse every stop forever. Exiting 0 instead discards stderr, so the hook is silently
# off. This says it out loud ONCE per session: return 1 (the caller `exit`s with it; a Stop hook
# surfaces stderr on exit 1 without blocking), then 0 on every later stop. Never returns 2.
#
# Needs no jq itself: the session id is cut out of the payload with sed. If it cannot be read the
# marker is keyed on $PPID, which is per-spawn, not per-session (measured: every shell the harness
# starts has a fresh parent), so the notice then repeats on every stop. Noisier, never silent.
# One notice per hook is intended: each names a different guard that is off.
#
# The marker lives in $XDG_RUNTIME_DIR (per-user, 0700), else $TMPDIR or /tmp with $UID in the name,
# and is created with noclobber (O_EXCL), so the create is the test: atomic, and a pre-planted
# symlink is never followed or truncated.
#
# Usage (before any jq use):  jq_missing_announce <hook-name>   # payload on stdin
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	echo "jq_missing_notice.sh is meant to be sourced, not executed." >&2
	exit 1
fi

jq_missing_announce() {
	local hook sid dir marker
	hook="${1%.sh}"
	sid="$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_.-]*\)".*/\1/p' | head -n1)"
	dir="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
	marker="$dir/${hook}.nojq.${sid:-ppid$PPID}.announced"
	[ -n "${XDG_RUNTIME_DIR:-}" ] || marker="${marker%.announced}.uid${UID:-0}.announced"
	if ! (set -C; : >"$marker") 2>/dev/null; then
		# Exists (or is a planted symlink): already announced. Unwritable dir: announce every time.
		{ [ -e "$marker" ] || [ -L "$marker" ]; } && return 0
	fi
	{
		echo "$hook: jq not found, so this Stop hook is OFF this session (it was a silent no-op before)."
		echo "Install it to re-enable the guard: sudo apt install jq"
		echo "Said once per session; later stops pass quietly."
	} >&2
	return 1
}
