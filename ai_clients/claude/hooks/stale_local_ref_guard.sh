#!/bin/bash
# PreToolUse (Bash matcher) hook: block `git worktree add`/`git checkout`/
# `git switch` when the target is a bare local branch name that is STALE
# against `origin/<branch>` — dotfiles-linux-dev#410.
#
# Measured 2026-09-18 (blueprintx#512): `git worktree add <path>
# fix/precommit-ci-parity-384` checked out a local ref 3 commits behind the
# real PR head. The file under review did not exist at that revision, and a
# review pass publicly refuted three real CodeRabbit findings (two Major) as
# "not in this PR", resolving all three threads on that false premise. The
# wrong answer read as plausible — it cited real commands and quoted real
# output — so nothing caught it until an unrelated `git merge` surfaced the
# very files the replies said did not exist.
#
# The comparison is the two-line one the issue itself specifies: local SHA
# vs `origin/<branch>` SHA, stale only when they differ and local is not
# ahead (ordinary unpushed work is never blocked). See
# lib/stale_local_ref_gate.sh for the full decision table.
#
# ⚠️ NOT YET WIRED into ai_clients/claude/settings.json's PreToolUse Bash
# array: that file was held by a concurrent PR at the time this hook was
# written (dotfiles-linux-dev#410 scope note). Wiring is a one-line addition, same
# shape as every other entry in that array — add it the next time
# settings.json is touched.
#
# Hook I/O contract (same as branch_requires_issue_guard.sh): silent on
# stdout, speaks through exit code + stderr. Fails OPEN on anything it
# cannot resolve — no jq, an unparsable payload, a command it cannot
# statically identify as a checkout of an existing ref, or refs it cannot
# read (see gate_stale_local_ref's `unreadable`/`no_remote` states).
set -u

command -v jq >/dev/null 2>&1 || exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/stale_local_ref_gate.sh
source "$HOOK_DIR/lib/stale_local_ref_gate.sh"

# Prefixing the command with this stands the guard aside, for a deliberate
# checkout of a known-stale ref (e.g. bisecting history).
ESCAPE_HATCH='ALLOW_STALE_LOCAL_REF=1'

main() {
	local payload tool command branch

	payload="$(cat)"
	tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"
	[[ "$tool" == "Bash" ]] || exit 0

	command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
	[[ -n "$command" ]] || exit 0

	[[ "$command" == *"$ESCAPE_HATCH"* ]] && exit 0

	branch="$(stale_ref_target "$command")" || exit 0
	[[ -n "$branch" ]] || exit 0

	gate_stale_local_ref "$branch"
	[[ "$STALE_REF_STATUS" == "stale" ]] || exit 0

	{
		echo "BLOCKED: '$branch' is a stale local branch ref."
		echo
		echo "$STALE_REF_DETAIL"
		echo
		echo "Fetch first, then target the remote-qualified form:"
		echo "  git fetch origin"
		echo "  <your command, using origin/$branch instead of $branch>"
		echo
		echo "A stale local ref reads plausibly and prints success while quietly answering the"
		echo "wrong question — measured cost: three CodeRabbit findings (two Major) were publicly"
		echo "refuted as \"not in this PR\" and resolved on that false premise (blueprintx#512)."
		echo
		echo "Genuinely need the stale local ref (e.g. bisecting)? Re-run with:"
		echo "  ${ESCAPE_HATCH} <your command>"
	} >&2
	exit 2
}

main "$@"
