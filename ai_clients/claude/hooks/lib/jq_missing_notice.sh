#!/bin/bash
# One-shot "jq is missing" notice for Stop hooks (dotfiles-linux-dev#1169).
#
# A Stop hook cannot fail closed without jq: its stop_hook_active loop-break is read through jq, so
# exit 2 would refuse every stop forever. Exiting 0 instead discards stderr, so the hook is silently
# off. This says it out loud ONCE per session: return 1 (the caller `exit`s with it; a Stop hook
# surfaces stderr on exit 1 without blocking), then 0 on every later stop. Never returns 2.
#
# Needs no jq itself: the session id is cut out of the payload with sed; if it cannot be read the
# marker is keyed on the parent PID, and if even that is unusable the notice simply repeats.
#
# Usage (before any jq use):  jq_missing_announce <hook-name>   # payload on stdin
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	echo "jq_missing_notice.sh is meant to be sourced, not executed." >&2
	exit 1
fi

jq_missing_announce() {
	local hook sid marker
	hook="${1%.sh}"
	sid="$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_.-]*\)".*/\1/p' | head -n1)"
	marker="${TMPDIR:-/tmp}/${hook}.nojq.${sid:-ppid$PPID}.announced"
	[ -e "$marker" ] && return 0
	: >"$marker" 2>/dev/null
	{
		echo "$hook: jq not found, so this Stop hook is OFF this session (it was a silent no-op before)."
		echo "Install it to re-enable the guard: sudo apt install jq"
		echo "Said once per session; later stops pass quietly."
	} >&2
	return 1
}
