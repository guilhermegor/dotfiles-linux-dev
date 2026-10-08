#!/usr/bin/env bats
#
# Unit tests for ai_clients/lib/upstream_guard.sh (dotfiles-linux-dev#643): a deploy
# from a checkout behind its upstream reverted a merged fix in ~/.claude.
#
# Fixture: a bare "origin", a "dev" clone that pushes commits, and a "deploy" clone
# that is the checkout under test. Run locally:  bats tests/

setup() {
	ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	TMP="$(mktemp -d)"
	export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
		GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
	unset AI_CLIENTS_ALLOW_STALE AI_CLIENTS_UPSTREAM_CHECKED

	git init -q --bare -b main "$TMP/origin.git"
	git clone -q "$TMP/origin.git" "$TMP/dev" 2>/dev/null
	git -C "$TMP/dev" checkout -q -b main
	git -C "$TMP/dev" commit -q --allow-empty -m one
	git -C "$TMP/dev" push -q -u origin main
	git clone -q "$TMP/origin.git" "$TMP/deploy"

	print_status() { echo "[$1] $2"; }
	source "$ROOT/ai_clients/lib/upstream_guard.sh"
}

teardown() {
	rm -rf "$TMP"
}

advance_origin() {
	git -C "$TMP/dev" commit -q --allow-empty -m two
	git -C "$TMP/dev" push -q origin main
}

@test "up to date checkout is allowed" {
	run ai_clients_upstream_guard "$TMP/deploy"
	[ "$status" -eq 0 ]
}

@test "checkout behind upstream is refused and names the count" {
	advance_origin
	run ai_clients_upstream_guard "$TMP/deploy"
	[ "$status" -eq 1 ]
	[[ "$output" == *"1 commit(s) behind origin/main"* ]]
}

@test "checkout ahead of upstream is allowed" {
	git -C "$TMP/deploy" commit -q --allow-empty -m local
	run ai_clients_upstream_guard "$TMP/deploy"
	[ "$status" -eq 0 ]
}

@test "AI_CLIENTS_ALLOW_STALE=1 downgrades the refusal to a warning" {
	advance_origin
	AI_CLIENTS_ALLOW_STALE=1 run ai_clients_upstream_guard "$TMP/deploy"
	[ "$status" -eq 0 ]
	[[ "$output" == *"deploying anyway"* ]]
}

@test "unreachable upstream warns and does not block" {
	git -C "$TMP/deploy" remote set-url origin "$TMP/does-not-exist.git"
	run ai_clients_upstream_guard "$TMP/deploy"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Could not fetch"* ]]
}

@test "branch without an upstream warns and does not block" {
	git -C "$TMP/deploy" checkout -q -b scratch
	run ai_clients_upstream_guard "$TMP/deploy"
	[ "$status" -eq 0 ]
	[[ "$output" == *"No upstream"* ]]
}

@test "second call in the same process tree skips the check" {
	advance_origin
	AI_CLIENTS_UPSTREAM_CHECKED=1 run ai_clients_upstream_guard "$TMP/deploy"
	[ "$status" -eq 0 ]
}

@test "router and every client main.sh call the guard" {
	local f
	for f in "$ROOT"/ai_clients/main.sh "$ROOT"/ai_clients/*/main.sh; do
		run grep -q '^    ai_clients_upstream_guard || exit 1$' "$f"
		[ "$status" -eq 0 ]
	done
}
