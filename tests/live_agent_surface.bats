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

# --- dotfiles-dev#551: a dead worktree is not a live writer -----------------------------------
#
# The walk above has no pruning, so a long-lived checkout saturates: measured at 61 worktrees,
# 56 on branches the forge reports MERGED, leaving ~0 genuine live writers while every candidate
# file still read `held`. These cases pin the exclusion AND, more importantly, every direction it
# must refuse to take — a prune that guesses loses work, which is strictly worse than a gate that
# over-holds.
#
# `gh` is stubbed here, unlike every test above it: this is the one path in the file that reaches
# the forge at all. GH_STUB_STATE drives the answer, GH_STUB_LOG records that a call happened,
# and a test asserting ZERO calls is as load-bearing as the ones asserting a verdict.
#
# The stub answers `gh pr list --state all` the way the forge would: one PR per `feature/*`
# branch of the fixture, headed at that branch's current commit. GH_STUB_CROSS=true marks every
# row as a fork PR; GH_STUB_OID overrides every row's head commit (a branch reused after its PR
# closed).

_stub_gh() {
	mkdir -p "$TEST_TMP/bin"
	cat >"$TEST_TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_STUB_LOG"
case "${GH_STUB_STATE:-NONE}" in
FAIL) exit 1 ;;
NONE) printf '[]\n' ;;
*)
	git -C "$GH_STUB_REPO" for-each-ref --format='%(objectname) %(refname:short)' refs/heads/feature/ \
		| jq -Rn --arg s "$GH_STUB_STATE" --arg oid "${GH_STUB_OID:-}" \
			--argjson cross "${GH_STUB_CROSS:-false}" \
			'[inputs | split(" ")
			  | {headRefOid: (if $oid == "" then .[0] else $oid end), headRefName: .[1],
			     state: $s, isCrossRepository: $cross}]'
	;;
esac
STUB
	chmod +x "$TEST_TMP/bin/gh"
	export GH_STUB_LOG="$TEST_TMP/gh_calls"
	export GH_STUB_REPO="$REPO"
	: >"$GH_STUB_LOG"
	PATH="$TEST_TMP/bin:$PATH"
}

# _github_origin — swap the fixture's local-path origin for a GitHub URL, which is what ARMS the
# enhancement. Done AFTER any push, so the upstream ref exists while origin is still reachable.
_github_origin() {
	git -C "$REPO" remote set-url origin git@github.com:acme/widget.git
}

# _pushed_worktree NAME FILE — a worktree whose branch is committed, pushed, and tracking, i.e.
# holding no work its PR does not already account for. Echoes its path.
_pushed_worktree() {
	local name="$1" file="$2"
	local wt="$TEST_TMP/wt-$name"
	git -C "$REPO" worktree add -q -b "feature/$name" "$wt" master
	echo work >"$wt/$file"
	git -C "$wt" add "$file"
	git -C "$wt" commit -q -m "add $file"
	git -C "$wt" push -q -u origin "feature/$name"
	printf '%s\n' "$wt"
}

@test "551: _origin_owner_repo parses the SSH and HTTPS GitHub forms, stripping .git" {
	git -C "$REPO" remote set-url origin git@github.com:acme/widget.git
	run _origin_owner_repo "$REPO"
	[ "$status" -eq 0 ]
	[ "$output" = "acme widget" ]

	git -C "$REPO" remote set-url origin https://github.com/acme/widget.git
	run _origin_owner_repo "$REPO"
	[ "$status" -eq 0 ]
	[ "$output" = "acme widget" ]
}

@test "551: a local-path origin disables the enhancement and spends ZERO gh calls" {
	_stub_gh
	WT="$TEST_TMP/wt-localorigin"
	git -C "$REPO" worktree add -q -b feature/localorigin "$WT" master
	echo work >"$WT/localorigin_work.txt"

	# the fixture clones from a path, which is every repo not cloned from GitHub
	run _origin_owner_repo "$REPO"
	[ "$status" -ne 0 ]

	gate_live_agent_surface "$REPO"
	[ "$LIVE_AGENT_STATUS" = "ok" ]
	[[ "$LIVE_AGENT_PATHS" == *"localorigin_work.txt"* ]]
	# the whole point of "best-effort": an unresolvable origin costs nothing and changes nothing
	[ ! -s "$GH_STUB_LOG" ]
}

@test "551: a forge-MERGED, clean, pushed worktree stops holding its files" {
	_stub_gh
	_pushed_worktree merged merged_work.txt >/dev/null
	_github_origin
	export GH_STUB_STATE=MERGED

	gate_live_agent_surface "$REPO"
	[ "$LIVE_AGENT_STATUS" = "ok" ]
	[[ "$LIVE_AGENT_PATHS" != *"merged_work.txt"* ]]

	run live_agent_classify_files merged_work.txt
	[ "$output" = "free" ]
	# and it got there by ASKING, not by assuming
	[ -s "$GH_STUB_LOG" ]
}

@test "551: a CLOSED PR counts as dead too, not only a merged one" {
	_stub_gh
	_pushed_worktree closed closed_work.txt >/dev/null
	_github_origin
	export GH_STUB_STATE=CLOSED

	gate_live_agent_surface "$REPO"
	# status first: a failed gate clears LIVE_AGENT_PATHS, which would pass the absence check
	[ "$LIVE_AGENT_STATUS" = "ok" ]
	[[ "$LIVE_AGENT_PATHS" != *"closed_work.txt"* ]]
	run live_agent_classify_files closed_work.txt
	[ "$output" = "free" ]
}

@test "551: a closed FORK PR sharing the branch name never marks a local worktree dead" {
	_stub_gh
	_pushed_worktree forked forked_work.txt >/dev/null
	_github_origin
	export GH_STUB_STATE=CLOSED GH_STUB_CROSS=true

	gate_live_agent_surface "$REPO"
	[ "$LIVE_AGENT_STATUS" = "ok" ]
	[[ "$LIVE_AGENT_PATHS" == *"forked_work.txt"* ]]
}

@test "551: a branch REUSED after its PR closed is held — the dead PR's head is not this HEAD" {
	_stub_gh
	_pushed_worktree reused reused_work.txt >/dev/null
	_github_origin
	export GH_STUB_STATE=MERGED GH_STUB_OID=0000000000000000000000000000000000000000

	gate_live_agent_surface "$REPO"
	[ "$LIVE_AGENT_STATUS" = "ok" ]
	[[ "$LIVE_AGENT_PATHS" == *"reused_work.txt"* ]]
}

@test "551: the forge is asked ONCE per gate call, however many worktrees there are" {
	_stub_gh
	_pushed_worktree one one_work.txt >/dev/null
	_pushed_worktree two two_work.txt >/dev/null
	_pushed_worktree three three_work.txt >/dev/null
	_github_origin
	export GH_STUB_STATE=MERGED

	gate_live_agent_surface "$REPO"
	[ "$LIVE_AGENT_STATUS" = "ok" ]
	[ "$(wc -l <"$GH_STUB_LOG")" -eq 1 ]
}

@test "551: a MERGED branch with UNCOMMITTED work is still held — never prune before rescue" {
	_stub_gh
	WT="$(_pushed_worktree dirtymerged dirtymerged_work.txt)"
	echo "work the merged PR never saw" >"$WT/unrescued.txt"
	_github_origin
	export GH_STUB_STATE=MERGED

	gate_live_agent_surface "$REPO"
	[ "$LIVE_AGENT_STATUS" = "ok" ]
	[[ "$LIVE_AGENT_PATHS" == *"unrescued.txt"* ]]
}

@test "551: a MERGED branch AHEAD of its upstream is still held" {
	_stub_gh
	WT="$(_pushed_worktree aheadmerged aheadmerged_work.txt)"
	echo more >"$WT/ahead_only.txt"
	git -C "$WT" add ahead_only.txt
	git -C "$WT" commit -q -m "committed but never pushed"
	_github_origin
	export GH_STUB_STATE=MERGED

	gate_live_agent_surface "$REPO"
	[[ "$LIVE_AGENT_PATHS" == *"ahead_only.txt"* ]]
}

@test "551: a branch with NO upstream is never pruned, whatever the forge says" {
	_stub_gh
	WT="$TEST_TMP/wt-noupstream"
	git -C "$REPO" worktree add -q -b feature/noupstream "$WT" master
	echo work >"$WT/noupstream_work.txt"
	git -C "$WT" add noupstream_work.txt
	git -C "$WT" commit -q -m "add noupstream_work.txt"
	# deliberately never pushed: its commits cannot be verified as already-shipped
	_github_origin
	export GH_STUB_STATE=MERGED

	gate_live_agent_surface "$REPO"
	[[ "$LIVE_AGENT_PATHS" == *"noupstream_work.txt"* ]]
}

@test "551: a branch with no PR at all is UNEXAMINED, never dead" {
	_stub_gh
	_pushed_worktree nopr nopr_work.txt >/dev/null
	_github_origin
	export GH_STUB_STATE=NONE

	gate_live_agent_surface "$REPO"
	[[ "$LIVE_AGENT_PATHS" == *"nopr_work.txt"* ]]
}

@test "551: an OPEN PR is a live writer" {
	_stub_gh
	_pushed_worktree openpr openpr_work.txt >/dev/null
	_github_origin
	export GH_STUB_STATE=OPEN

	gate_live_agent_surface "$REPO"
	[[ "$LIVE_AGENT_PATHS" == *"openpr_work.txt"* ]]
}

@test "551: a gh read failure fails closed to 'not dead', never to 'prune it'" {
	_stub_gh
	_pushed_worktree ghfail ghfail_work.txt >/dev/null
	_github_origin
	export GH_STUB_STATE=FAIL

	gate_live_agent_surface "$REPO"
	# the gate itself still succeeds — an unreadable forge disables the enhancement, it does not
	# turn a healthy local walk into `unknown`
	[ "$LIVE_AGENT_STATUS" = "ok" ]
	[[ "$LIVE_AGENT_PATHS" == *"ghfail_work.txt"* ]]
}

@test "551: _dead_branch_index is empty-but-ok for no PRs and fails on a gh error" {
	_stub_gh
	_pushed_worktree idx idx_work.txt >/dev/null

	export GH_STUB_STATE=NONE
	run _dead_branch_index acme widget
	[ "$status" -eq 0 ]
	[ -z "$output" ]

	export GH_STUB_STATE=MERGED
	run _dead_branch_index acme widget
	[ "$status" -eq 0 ]
	[ "$output" = "$(git -C "$REPO" rev-parse feature/idx)	feature/idx" ]

	# an OPEN PR is not dead, so it never enters the index
	export GH_STUB_STATE=OPEN
	run _dead_branch_index acme widget
	[ -z "$output" ]

	export GH_STUB_STATE=FAIL
	run _dead_branch_index acme widget
	[ "$status" -ne 0 ]
}
