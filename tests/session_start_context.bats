#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/session_start_context.sh — the fan-out
# classifier added for dotfiles-linux-dev#318.
#
# The discriminator (lessons-dotfiles: a-staged-deletion-set-is-a-stale-revert-not-lost-work.md):
# dirty-file COUNT is not the signal, the SIGN of the diff against HEAD is. Net insertions or
# untracked files → interrupted work, resume it. Net deletions of paths that already exist on
# origin/<default branch> → a stale revert, ignore it.
#
# Strategy: build a bare "origin" repo plus a real `git worktree add` layout under a throwaway
# temp dir, so `git worktree list --porcelain` (which the hook parses) reflects real worktrees —
# never the live repo or ~/.claude.
#
# Run locally:  bats tests/

setup() {
	HOOK="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/session_start_context.sh"
	TEST_TMP="$(mktemp -d)"

	# Bare "origin" seeded with one shipped file, cloned locally, then registered as a
	# worktree container so `git worktree list --porcelain` enumerates real worktrees.
	ORIGIN="$TEST_TMP/origin.git"
	git init -q --bare "$ORIGIN"

	SEED="$TEST_TMP/seed"
	git clone -q "$ORIGIN" "$SEED"
	git -C "$SEED" config user.email "test@example.com"
	git -C "$SEED" config user.name "Test"
	printf 'shipped line 1\nshipped line 2\nshipped line 3\nshipped line 4\nshipped line 5\n' >"$SEED/shipped.txt"
	git -C "$SEED" add shipped.txt
	git -C "$SEED" commit -q -m "seed"
	git -C "$SEED" push -q origin HEAD:refs/heads/master
	git -C "$SEED" symbolic-ref HEAD refs/heads/master >/dev/null 2>&1 || true

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

run_hook() {
	run bash -c "CLAUDE_PROJECT_DIR='$REPO' PATH='$PATH' bash '$HOOK' </dev/null"
}

# --- net insertions / untracked files → interrupted -----------------------------------------

@test "a worktree with net insertions is classified as interrupted work to resume" {
	WT="$TEST_TMP/wt-insert"
	git -C "$REPO" worktree add -q -b feat-insert "$WT" master
	printf 'line one\nline two\nline three\n' >"$WT/new_work.txt"
	git -C "$WT" add new_work.txt

	run_hook
	[ "$status" -eq 0 ]
	[[ "$output" == *"worktree wt-insert:"*"INTERRUPTED WORK, resume it"* ]]
	[[ "$output" == *"RESUME 1 worktree(s) holding interrupted work: wt-insert"* ]]
}

# --- net deletions of paths present on origin/master → stale ---------------------------------

@test "a worktree staging a net deletion of already-shipped content is classified as stale" {
	WT="$TEST_TMP/wt-revert"
	git -C "$REPO" worktree add -q -b feat-revert "$WT" master
	git -C "$WT" rm -q shipped.txt
	printf 'x\n' >"$WT/tiny.txt"
	git -C "$WT" add tiny.txt

	run_hook
	[ "$status" -eq 0 ]
	[[ "$output" == *"worktree wt-revert:"*"stale revert, do NOT rescue"* ]]
	[[ "$output" != *"INTERRUPTED WORK"*"wt-revert"* ]]
	[[ "$output" != *"RESUME"*"wt-revert"* ]]
}

# --- clean worktree → not reported at all -----------------------------------------------------

@test "a clean worktree is not reported" {
	WT="$TEST_TMP/wt-clean"
	git -C "$REPO" worktree add -q -b feat-clean "$WT" master

	run_hook
	[ "$status" -eq 0 ]
	[[ "$output" != *"wt-clean"* ]]
}

# --- anonymous worktree-agent-<id> branch is flagged, on either verdict ----------------------

@test "an anonymous worktree-agent branch holding real work is flagged as unreferenced" {
	WT="$TEST_TMP/worktree-agent-abc123"
	git -C "$REPO" worktree add -q -b worktree-agent-abc123 "$WT" master
	printf 'rescued content\nmore\n' >"$WT/rescued.txt"
	git -C "$WT" add rescued.txt

	run_hook
	[ "$status" -eq 0 ]
	[[ "$output" == *"INTERRUPTED WORK, resume it"*"[anonymous branch, no issue reference]"* ]]
}

# --- the PR listing reaches past gh's default 30 (dotfiles-linux-dev#606) ---------------------------

@test "the fan-out PR listing passes an explicit --limit above gh's default of 30" {
	FAKE_BIN="$TEST_TMP/bin"
	mkdir -p "$FAKE_BIN"
	GH_LOG="$TEST_TMP/gh.log"
	printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s"\necho "[]"\n' "$GH_LOG" >"$FAKE_BIN/gh"
	chmod +x "$FAKE_BIN/gh"
	git -C "$REPO" remote set-url origin https://github.com/example/repo.git

	run bash -c "CLAUDE_PROJECT_DIR='$REPO' PATH='$FAKE_BIN:$PATH' bash '$HOOK' </dev/null"
	[ "$status" -eq 0 ]
	run grep -E -- 'pr list .*--limit [0-9]+' "$GH_LOG"
	[ "$status" -eq 0 ]
	limit="$(grep -oE -- '--limit [0-9]+' "$GH_LOG" | head -1 | awk '{print $2}')"
	[ "$limit" -gt 30 ]
}

# --- non-vacuousness: prove the classifier can say "stale", not just always "interrupted" ----

@test "non-vacuous control: classify_worktree_diff itself returns stale for a pure deletion" {
	WT="$TEST_TMP/wt-revert2"
	git -C "$REPO" worktree add -q -b feat-revert2 "$WT" master
	git -C "$WT" rm -q shipped.txt

	run bash -c "source '$HOOK'; classify_worktree_diff '$WT' master"
	[ "$status" -eq 0 ]
	[[ "$output" == "stale"* ]]
}
