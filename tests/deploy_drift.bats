#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/deploy_drift.sh — the drift detector added for
# dotfiles-linux-dev#345 (nothing detected that ~/.claude/ was stale relative to source; a stale
# ai_clients/claude/commands/issue.md ran for 5 days and filed duplicate issues #336/#337).
#
# Synthetic tree with three commands/*.md files: one identical (source == live), one divergent
# (source and live both exist but differ), one never deployed (source only, live absent) — the
# same failure mode that let rules/web.md and 4 skills go unnoticed. Never-deployed must be
# counted as divergent, not skipped, or the detector reproduces the exact miss #345 reports.
#
# Run locally:  bats tests/

setup() {
	LIB="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/lib/deploy_drift.sh"
	TEST_TMP="$(mktemp -d)"
	REPO_ROOT="$TEST_TMP/repo"
	CLAUDE_DIR="$TEST_TMP/claude"
	mkdir -p "$REPO_ROOT/ai_clients/claude/commands" "$CLAUDE_DIR/commands"

	printf 'same content\n' >"$REPO_ROOT/ai_clients/claude/commands/identical.md"
	printf 'same content\n' >"$CLAUDE_DIR/commands/identical.md"

	printf 'new version\n' >"$REPO_ROOT/ai_clients/claude/commands/divergent.md"
	printf 'old version\n' >"$CLAUDE_DIR/commands/divergent.md"

	printf 'brand new\n' >"$REPO_ROOT/ai_clients/claude/commands/missing.md"

	source "$LIB"
}

teardown() {
	rm -rf "$TEST_TMP"
}

@test "deploy_drift_counts counts the divergent file and the never-deployed file, not the identical one" {
	run deploy_drift_counts "$REPO_ROOT" "$CLAUDE_DIR"
	[ "$status" -eq 0 ]

	local divergent never
	IFS=$'\t' read -r divergent never <<<"$output"
	[ "$divergent" = "2" ]
	[ "$never" = "1" ]
}

@test "emit_deploy_drift_status reports one line naming the counts and the fix command" {
	run emit_deploy_drift_status "$REPO_ROOT" "$CLAUDE_DIR"
	[ "$status" -eq 0 ]
	[[ "$output" == *"[deploy-drift] 2 file(s)"* ]]
	[[ "$output" == *"1 never deployed"* ]]
	[[ "$output" == *"make ai_clients"* ]]
}

@test "emit_deploy_drift_status is silent when source matches live exactly" {
	rm -f "$REPO_ROOT/ai_clients/claude/commands/divergent.md" "$CLAUDE_DIR/commands/divergent.md"
	rm -f "$REPO_ROOT/ai_clients/claude/commands/missing.md"

	run emit_deploy_drift_status "$REPO_ROOT" "$CLAUDE_DIR"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "emit_deploy_drift_status is silent outside a dotfiles-dev checkout (no ai_clients/claude)" {
	local other="$TEST_TMP/not-dotfiles"
	mkdir -p "$other"

	run emit_deploy_drift_status "$other" "$CLAUDE_DIR"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}
