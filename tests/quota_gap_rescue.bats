#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/quota_gap_rescue.sh — the UserPromptSubmit hook added
# for dotfiles-linux-dev#383 to re-run the worktree rescue fan-out after a wall-clock gap since the
# session's last prompt.
#
# Same bare-origin + real `git worktree add` strategy as tests/session_start_context.bats, so
# `fanout_worktrees()` (hooks/lib/worktree_fanout.sh) sees a real worktree layout.
#
# Run locally:  bats tests/

setup() {
	HOOK="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/quota_gap_rescue.sh"
	TEST_TMP="$(mktemp -d)"
	STATE_DIR="$TEST_TMP/claude_home"
	SID="test-session-1"

	ORIGIN="$TEST_TMP/origin.git"
	git init -q --bare "$ORIGIN"

	SEED="$TEST_TMP/seed"
	git clone -q "$ORIGIN" "$SEED"
	git -C "$SEED" config user.email "test@example.com"
	git -C "$SEED" config user.name "Test"
	printf 'shipped line 1\nshipped line 2\n' >"$SEED/shipped.txt"
	git -C "$SEED" add shipped.txt
	git -C "$SEED" commit -q -m "seed"
	git -C "$SEED" push -q origin HEAD:refs/heads/master

	REPO="$TEST_TMP/repo"
	git clone -q "$ORIGIN" "$REPO"
	git -C "$REPO" config user.email "test@example.com"
	git -C "$REPO" config user.name "Test"
	git -C "$REPO" remote set-head origin master >/dev/null 2>&1 \
		|| git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
}

teardown() {
	rm -rf "$TEST_TMP"
}

seed_state() {
	# Pre-seed the last-recorded-turn timestamp $1 seconds in the past.
	local seconds_ago="$1"
	mkdir -p "$STATE_DIR/quota-gap"
	echo "$(($(date +%s) - seconds_ago))" >"$STATE_DIR/quota-gap/$SID"
}

run_hook() {
	run bash -c "CLAUDE_CONFIG_DIR='$STATE_DIR' PATH='$PATH' bash '$HOOK' <<<'{\"cwd\":\"$REPO\",\"session_id\":\"$SID\"}'"
}

# --- gap exceeded + interrupted work -> prints ------------------------------------------------

@test "gap exceeded with an interrupted worktree prints the rescue report" {
	WT="$TEST_TMP/wt-insert"
	git -C "$REPO" worktree add -q -b feat-insert "$WT" master
	printf 'new work\n' >"$WT/new_work.txt"
	git -C "$WT" add new_work.txt

	seed_state 1800

	run_hook
	[ "$status" -eq 0 ]
	[[ "$output" == *"quota-gap-rescue"* ]]
	[[ "$output" == *"wt-insert"*"INTERRUPTED WORK, resume it"* ]]
}

# --- PR #389 review: an unwritable timestamp must not repeat the report every prompt ----------
# The write happens BEFORE the gap check. With `|| true`, a failed write left the stale timestamp
# readable, so every later prompt re-measured the same old gap and re-printed the report.

@test "an unwritable timestamp file stays silent instead of repeating the report every prompt" {
	[ "$(id -u)" -ne 0 ] || skip "root ignores file permissions, so the write cannot be made to fail"
	WT="$TEST_TMP/wt-insert"
	git -C "$REPO" worktree add -q -b feat-insert "$WT" master
	printf 'new work\n' >"$WT/new_work.txt"
	git -C "$WT" add new_work.txt

	seed_state 1800
	chmod 444 "$STATE_DIR/quota-gap/$SID"

	run_hook
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	# The stale timestamp is still the one on disk — the condition that made it repeat.
	run_hook
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

# --- gap exceeded + all clean (or only stale reverts) -> silent -------------------------------

@test "gap exceeded with every worktree clean is silent" {
	WT="$TEST_TMP/wt-clean"
	git -C "$REPO" worktree add -q -b feat-clean "$WT" master

	seed_state 1800

	run_hook
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "gap exceeded with only a stale-revert worktree is silent" {
	WT="$TEST_TMP/wt-revert"
	git -C "$REPO" worktree add -q -b feat-revert "$WT" master
	git -C "$WT" rm -q shipped.txt
	printf 'x\n' >"$WT/tiny.txt"
	git -C "$WT" add tiny.txt

	seed_state 1800

	run_hook
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

# --- gap not exceeded -> silent, and cheap (never walks worktrees) ----------------------------

@test "gap not exceeded is silent even with interrupted work waiting" {
	WT="$TEST_TMP/wt-insert"
	git -C "$REPO" worktree add -q -b feat-insert "$WT" master
	printf 'new work\n' >"$WT/new_work.txt"
	git -C "$WT" add new_work.txt

	seed_state 60

	run_hook
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "the first prompt of a session (no prior timestamp) is silent and seeds state" {
	run_hook
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[ -f "$STATE_DIR/quota-gap/$SID" ]
}

@test "no session_id in the payload fails open silently" {
	run bash -c "CLAUDE_CONFIG_DIR='$STATE_DIR' PATH='$PATH' bash '$HOOK' <<<'{\"cwd\":\"$REPO\"}'"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "not a git repo fails open silently" {
	NOTREPO="$TEST_TMP/not-a-repo"
	mkdir -p "$NOTREPO"
	run bash -c "CLAUDE_CONFIG_DIR='$STATE_DIR' PATH='$PATH' bash '$HOOK' <<<'{\"cwd\":\"$NOTREPO\",\"session_id\":\"$SID\"}'"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}
