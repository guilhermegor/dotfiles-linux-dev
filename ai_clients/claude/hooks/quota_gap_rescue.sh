#!/bin/bash
# UserPromptSubmit hook: re-run the worktree rescue fan-out after a quota gap.
#
# dotfiles-linux-dev#383. session_start_context.sh's fanout_worktrees() (hooks/lib/worktree_fanout.sh)
# only runs at SessionStart. A quota kill does not start a new session — the SAME one resumes —
# so nothing re-checks the worktrees after a 429 until the next s:dev-loop round (up to an hour
# away) or the owner remembering to ask. This hook is the missing sensor for the trigger
# s:dev-loop step 1 already names in prose ("the declared quota reset time, or the next
# successful call after the user switches accounts"): a wall-clock gap since this session's last
# recorded prompt. It cannot see a 429 directly, but a long gap catches a quota kill, an account
# switch, and an overnight pause alike, without pretending to detect something it cannot.
#
# ⚠️ This is the repo's FIRST UserPromptSubmit hook — it runs on EVERY prompt. It stays cheap
# (below the gap threshold it exits before touching git at all; above it, no `gh` call —
# fanout_worktrees is called with github_ok=0, worktree walk only) and, above all, SILENT when
# it has nothing to say: it reuses fanout_worktrees()'s verdict (interrupted vs. stale revert)
# rather than re-deriving "dirty means lost work" — printing on every stale-revert worktree is
# the exact "cries wolf" failure the sweep hook's own comments warn about.
#
# Fails OPEN on everything: no jq/git, not a repo, no session id, an unreadable/unwritable
# timestamp file. A hook on a per-prompt event that errors loudly gets disabled.
set -u

# Default, not a measurement — nothing has timed how long a real quota reset takes. 20 minutes
# is long enough that a normal back-and-forth conversation never trips it, short enough to
# notice within one work session. Override with QUOTA_GAP_THRESHOLD_SECONDS to tune/test.
: "${QUOTA_GAP_THRESHOLD_SECONDS:=1200}"

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

# shellcheck source=lib/worktree_fanout.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/worktree_fanout.sh" 2>/dev/null || exit 0

main() {
	local payload cwd session_id state_dir state_file now last gap report

	payload="$(cat)"
	cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
	[ -n "$cwd" ] || cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
	session_id="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
	[ -n "$session_id" ] || exit 0

	git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

	# Timestamp lives in the session scratchpad under ~/.claude, never in the repo — it is
	# per-session runtime state, not project content.
	state_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/quota-gap"
	mkdir -p "$state_dir" 2>/dev/null || exit 0
	state_file="$state_dir/$session_id"

	now="$(date +%s)" || exit 0

	last=""
	[ -r "$state_file" ] && last="$(cat "$state_file" 2>/dev/null)"
	# Record THIS prompt as the last-seen turn before deciding anything below, so a gap is
	# always measured from the immediately preceding prompt, never accumulated across prompts.
	#
	# ⚠️ `|| exit 0`, not `|| true` (PR #389 review). If the write fails while the OLD timestamp
	# stays readable, every later prompt measures its gap from that stale value, exceeds the
	# threshold, and repeats the report on EVERY message — the "cries wolf" failure this hook
	# exists to avoid. Unable to record the turn means unable to measure a gap: stay silent.
	#
	# ⚠️ The `{ …; } 2>/dev/null` group is load-bearing, not style. Redirections apply left to
	# right, so in `printf … >"$f" 2>/dev/null` bash fails to OPEN "$f" and prints "Permission
	# denied" BEFORE the `2>/dev/null` takes effect — that form silences printf, not the failed
	# open. Measured: it emitted the error on every prompt against a read-only state file.
	{ printf '%s\n' "$now" >"$state_file"; } 2>/dev/null || exit 0

	[[ "$last" =~ ^[0-9]+$ ]] || exit 0
	gap=$((now - last))
	[ "$gap" -gt "$QUOTA_GAP_THRESHOLD_SECONDS" ] || exit 0

	report="$(fanout_worktrees "$cwd" 0 "" 2>/dev/null)" || exit 0
	# fanout_worktrees() prints an informational line for EVERY dirty worktree, stale reverts
	# included — right for SessionStart, wrong here. Gate on its own "RESUME ... interrupted
	# work" summary line instead, which it only emits when interrupted_names is non-empty: that
	# reuses the classifier's verdict directly rather than re-deriving "dirty means lost work"
	# from the raw per-worktree lines.
	printf '%s\n' "$report" | grep -q 'RESUME .* worktree(s) holding interrupted work' || exit 0

	printf '[quota-gap-rescue] %s minute gap since your last prompt — re-checked worktrees:\n' "$((gap / 60))"
	printf '%s\n' "$report"
	exit 0
}

main
