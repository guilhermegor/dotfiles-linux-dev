#!/usr/bin/env bats
#
# Unit tests for gate_live_agent_surface / live_agent_classify_files
# (ai_clients/claude/hooks/lib/free_surface.sh, dotfiles-dev#501).
#
# dotfiles-dev#501: three places defined "dispatch collision" and disagreed — #433 says
# agent-vs-agent, s:dev-loop step 6 and free_surface.sh's ONLY gate (gate_free_surface) said
# agent-vs-open-PR. This file exercises the NEW, distinct gate that answers the agent-vs-agent
# question with real git worktrees (never gh-stubbed — this gate is local-only), plus a
# consistency pin between dev-loop.md's stated rule and this implementation, so a future prose
# or code drift fails a test instead of waiting for a reader to notice.
#
# Strategy mirrors tests/session_start_context.bats: a bare "origin" plus real
# `git worktree add` worktrees under a throwaway temp dir.

setup() {
	LIB="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/lib/free_surface.sh"
	# shellcheck source=/dev/null
	source "$LIB"
	TEST_TMP="$(mktemp -d)"

	ORIGIN="$TEST_TMP/origin.git"
	git init -q --bare "$ORIGIN"

	REPO="$TEST_TMP/repo"
	git clone -q "$ORIGIN" "$REPO"
	git -C "$REPO" config user.email "test@example.com"
	git -C "$REPO" config user.name "Test"
	echo base >"$REPO/base.txt"
	git -C "$REPO" add base.txt
	git -C "$REPO" commit -q -m base
	git -C "$REPO" push -q origin HEAD:refs/heads/master
	git -C "$REPO" remote set-head origin master >/dev/null 2>&1 \
		|| git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
}

teardown() {
	rm -rf "$TEST_TMP"
}

# --- a live agent blocks --------------------------------------------------------------------

@test "a worktree with committed, unpushed-to-a-PR work holds its files" {
	WT="$TEST_TMP/wt-committed"
	git -C "$REPO" worktree add -q -b feature/committed "$WT" master
	echo committed >"$WT/committed.txt"
	git -C "$WT" add committed.txt
	git -C "$WT" commit -q -m "add committed.txt"

	gate_live_agent_surface "$REPO"
	[ "$LIVE_AGENT_STATUS" = "ok" ]
	[[ "$LIVE_AGENT_PATHS" == *"committed.txt"* ]]

	run live_agent_classify_files committed.txt
	[[ "$output" == "held:committed.txt" ]]
}

@test "a fresh worktree with only uncommitted changes (no commits yet) still holds its files" {
	WT="$TEST_TMP/wt-dirty"
	git -C "$REPO" worktree add -q -b feature/dirty "$WT" master
	echo dirty >"$WT/dirty.txt"
	# deliberately NOT committed — an agent that just started, before its first commit

	gate_live_agent_surface "$REPO"
	[ "$LIVE_AGENT_STATUS" = "ok" ]
	[[ "$LIVE_AGENT_PATHS" == *"dirty.txt"* ]]

	run live_agent_classify_files dirty.txt
	[[ "$output" == "held:dirty.txt" ]]
}

@test "an untracked file in a live worktree holds too, not only a tracked diff" {
	WT="$TEST_TMP/wt-untracked"
	git -C "$REPO" worktree add -q -b feature/untracked "$WT" master
	echo new >"$WT/new_untracked.txt"

	gate_live_agent_surface "$REPO"
	run live_agent_classify_files new_untracked.txt
	[[ "$output" == "held:new_untracked.txt" ]]
}

# --- an idle worktree (nothing live) is free -------------------------------------------------

@test "a worktree with no diff from default and a clean tree holds nothing" {
	WT="$TEST_TMP/wt-idle"
	git -C "$REPO" worktree add -q -b feature/idle "$WT" master

	gate_live_agent_surface "$REPO"
	[ "$LIVE_AGENT_STATUS" = "ok" ]

	run live_agent_classify_files anything.txt
	[[ "$output" == "free" ]]
}

@test "with no other worktrees at all, everything is free" {
	gate_live_agent_surface "$REPO"
	[ "$LIVE_AGENT_STATUS" = "ok" ]
	[ -z "$LIVE_AGENT_PATHS" ]

	run live_agent_classify_files anything.txt
	[[ "$output" == "free" ]]
}

# --- an open-PR-only overlap must NOT show up here — that's the whole bug (dotfiles-dev#501) --

@test "gate_live_agent_surface never calls gh — a frozen open-PR branch is invisible to it" {
	WT="$TEST_TMP/wt-frozen"
	git -C "$REPO" worktree add -q -b feature/frozen "$WT" master
	echo frozen >"$WT/frozen.txt"
	git -C "$WT" add frozen.txt
	git -C "$WT" commit -q -m "frozen work, imagine an open PR sitting in review"
	# No PR is opened here on purpose — the point is this gate does not need one, or `gh`, to
	# answer correctly: a live agent (this worktree) still holds frozen.txt regardless.

	# `gh` deliberately absent from PATH for this one call: gate_live_agent_surface must not
	# need it — a real gh-less environment must still get the right, non-UNKNOWN answer.
	local no_gh_dir bin
	no_gh_dir="$(mktemp -d)"
	for tool in git sed sort tr grep cat; do
		bin="$(command -v "$tool")"
		[ -n "$bin" ] && ln -s "$bin" "$no_gh_dir/$tool"
	done
	PATH="$no_gh_dir" gate_live_agent_surface "$REPO"
	rm -rf "$no_gh_dir"

	[ "$LIVE_AGENT_STATUS" = "ok" ]
	[[ "$LIVE_AGENT_PATHS" == *"frozen.txt"* ]]
}

# --- fail closed, never free, when liveness cannot be determined (dotfiles-dev#501) ----------

@test "not a git repo at all: fails closed to unknown, never free" {
	local rc=0
	gate_live_agent_surface "$TEST_TMP" || rc=$?
	[ "$rc" -eq 1 ]
	[ "$LIVE_AGENT_STATUS" = "unknown" ]
	[ -z "$LIVE_AGENT_PATHS" ]
}

@test "a nonexistent directory fails closed to unknown, never free" {
	local rc=0
	gate_live_agent_surface "$TEST_TMP/does-not-exist" || rc=$?
	[ "$rc" -eq 1 ]
	[ "$LIVE_AGENT_STATUS" = "unknown" ]
}

# --- the pin: dev-loop.md's stated rule must name THIS implementation (dotfiles-dev#501) -----
# The issue's own words: "One test that fails if the three ever disagree again — ideally
# asserting the skill's stated rule against the gate's actual behaviour, so prose drift is
# caught mechanically rather than by a reader noticing." This is that test: it greps the skill
# for the function names its own prose promises to call, then confirms free_surface.sh actually
# defines each one. Rename or drop either side and this fails — a reader no longer has to.

@test "dev-loop.md step 6 names a live-agent function free_surface.sh actually implements" {
	SKILL="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/skills/dev-loop.md"
	local -a fns
	mapfile -t fns < <(grep -oE 'gate_live_agent_surface|live_agent_classify_files' "$SKILL" | sort -u)

	[ "${#fns[@]}" -gt 0 ]
	for fn in "${fns[@]}"; do
		run grep -qE "^${fn}\(\)" "$LIB"
		[ "$status" -eq 0 ]
	done
}

@test "dev-loop.md step 6 no longer states the open-PR-is-the-collision rule (dotfiles-dev#501)" {
	SKILL="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/skills/dev-loop.md"
	run grep -F "Compute the free surface: the exact files the open PRs touch, versus the exact files each open" "$SKILL"
	[ "$status" -ne 0 ]
}

@test "dev-loop.md step 6 still states the agent-vs-agent collision rule from dotfiles-dev#433" {
	SKILL="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/skills/dev-loop.md"
	run grep -F "Collision is between LIVE AGENTS" "$SKILL"
	[ "$status" -eq 0 ]
}

# --- dotfiles-dev#523 review (codex fallback rung): three fail-open / over-broad paths --------

@test "called FROM a linked worktree, the main checkout's dirty files still hold" {
	WT="$TEST_TMP/wt-caller"
	git -C "$REPO" worktree add -q -b feature/caller "$WT" master
	# the MAIN checkout is on master (== default) and is the one holding work
	echo agentwork >"$REPO/main_checkout_work.txt"

	# cwd is the LINKED worktree, so the main checkout is an "other" worktree here
	gate_live_agent_surface "$WT"
	[ "$LIVE_AGENT_STATUS" = "ok" ]
	[[ "$LIVE_AGENT_PATHS" == *"main_checkout_work.txt"* ]]

	run live_agent_classify_files main_checkout_work.txt
	[[ "$output" == "held:main_checkout_work.txt" ]]
}

@test "the caller's own worktree is excluded by path, not by being on the default branch" {
	WT="$TEST_TMP/wt-self"
	git -C "$REPO" worktree add -q -b feature/self "$WT" master
	echo mine >"$WT/caller_own_file.txt"

	# asking from inside WT: WT's own dirt is the CALLER's, not another agent's
	gate_live_agent_surface "$WT"
	[ "$LIVE_AGENT_STATUS" = "ok" ]
	[[ "$LIVE_AGENT_PATHS" != *"caller_own_file.txt"* ]]
}

@test "an unreadable sibling worktree fails closed to unknown, never free" {
	WT="$TEST_TMP/wt-unreadable"
	git -C "$REPO" worktree add -q -b feature/unreadable "$WT" master
	echo held >"$WT/would_be_held.txt"
	# break only the worktree's own git pointer: it is still listed and still a directory,
	# so the loop reaches it and its working-tree reads fail
	echo "not a gitdir pointer" >"$WT/.git"

	local rc=0
	gate_live_agent_surface "$REPO" || rc=$?
	[ "$rc" -eq 1 ]
	[ "$LIVE_AGENT_STATUS" = "unknown" ]
}

@test "a clone with no refs/remotes/origin/HEAD still resolves the default branch" {
	git -C "$REPO" symbolic-ref --delete refs/remotes/origin/HEAD
	run git -C "$REPO" symbolic-ref --quiet --short refs/remotes/origin/HEAD
	[ "$status" -ne 0 ]

	WT="$TEST_TMP/wt-nohead"
	git -C "$REPO" worktree add -q -b feature/nohead "$WT" master
	echo work >"$WT/nohead_work.txt"

	gate_live_agent_surface "$REPO"
	[ "$LIVE_AGENT_STATUS" = "ok" ]
	[[ "$LIVE_AGENT_PATHS" == *"nohead_work.txt"* ]]
}

# --- dotfiles-dev#523 review, second round: three more fail-open paths ------------------------

@test "a DETACHED sibling worktree still holds its dirty files" {
	WT="$TEST_TMP/wt-detached"
	# what an agent checking out a PR head produces: no `branch` line in --porcelain at all
	git -C "$REPO" worktree add -q --detach "$WT" master
	run git -C "$WT" symbolic-ref -q HEAD
	[ "$status" -ne 0 ]
	echo detachedwork >"$WT/detached_work.txt"

	gate_live_agent_surface "$REPO"
	[ "$LIVE_AGENT_STATUS" = "ok" ]
	[[ "$LIVE_AGENT_PATHS" == *"detached_work.txt"* ]]

	run live_agent_classify_files detached_work.txt
	[[ "$output" == "held:detached_work.txt" ]]
}

@test "committed divergence is read against origin/<default>, so a missing LOCAL default still holds" {
	WT="$TEST_TMP/wt-nolocaldefault"
	git -C "$REPO" worktree add -q -b feature/nolocal "$WT" master
	echo committed >"$WT/nolocal_committed.txt"
	git -C "$WT" add nolocal_committed.txt
	git -C "$WT" commit -q -m "add nolocal_committed.txt"
	# the local branch named `master` is gone; refs/remotes/origin/master is not
	git -C "$REPO" checkout -q --detach master
	git -C "$REPO" branch -q -D master
	run git -C "$REPO" rev-parse --verify --quiet refs/heads/master
	[ "$status" -ne 0 ]

	gate_live_agent_surface "$REPO"
	[ "$LIVE_AGENT_STATUS" = "ok" ]
	[[ "$LIVE_AGENT_PATHS" == *"nolocal_committed.txt"* ]]
}

@test "a non-ASCII pathname is held literally, not in git's quoted form" {
	WT="$TEST_TMP/wt-quoted"
	git -C "$REPO" worktree add -q -b feature/quoted "$WT" master
	echo work >"$WT/café.txt"
	# pin the precondition: git's DEFAULT quoting is what used to break the comparison
	run git -C "$WT" ls-files --others --exclude-standard
	[[ "$output" == *'\303\251'* ]]

	gate_live_agent_surface "$REPO"
	[ "$LIVE_AGENT_STATUS" = "ok" ]
	[[ "$LIVE_AGENT_PATHS" == *"café.txt"* ]]

	run live_agent_classify_files "café.txt"
	[[ "$output" == "held:café.txt" ]]
}
