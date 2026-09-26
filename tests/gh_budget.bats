#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/gh_budget.sh (dotfiles-dev#407) — pure text
# classification, no network. Fixtures are captured response bodies, not live API calls, so the
# suite stays deterministic in CI. Covers all four required cases: a real GitHub API 403, a
# CodeRabbit review-slot notice, a CodeRabbit chat-quota notice, and an unrecognised notice.

setup() {
	source "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/gh_budget.sh"
	LATCH_DIR="$(mktemp -d)"
	export GH_BUDGET_LATCH_FILE="$LATCH_DIR/latch"
	BIN="$LATCH_DIR/bin"
	mkdir -p "$BIN"
	export PATH="$BIN:$PATH"
}

teardown() {
	rm -rf "$LATCH_DIR"
}

@test "the exact measured 2026-09-20 18:20:02Z GitHub 403 classifies as github-api-limit" {
	gh_budget_classify 'API rate limit exceeded for user ID 55053188'
	[ "$GH_BUDGET_CLASS" = "github-api-limit" ]
}

@test "gh CLI's GraphQL-prefixed form of the same error also classifies as github-api-limit" {
	gh_budget_classify 'GraphQL: API rate limit exceeded for user ID 55053188.'
	[ "$GH_BUDGET_CLASS" = "github-api-limit" ]
}

@test "GitHub's secondary rate limit (abuse detection) also classifies as github-api-limit" {
	gh_budget_classify 'You have exceeded a secondary rate limit. Please wait a few minutes.'
	[ "$GH_BUDGET_CLASS" = "github-api-limit" ]
}

@test "a CodeRabbit review-slot notice classifies as coderabbit-review-limit, not github" {
	gh_budget_classify '⚠️ Rate limit exceeded — please wait 4 minutes and 37 seconds before requesting another review.'
	[ "$GH_BUDGET_CLASS" = "coderabbit-review-limit" ]
}

@test "a CodeRabbit chat-quota notice classifies as coderabbit-chat-limit, a DIFFERENT limit" {
	gh_budget_classify 'You have exceeded the maximum number of chat messages per hour. Please wait before sending another chat message.'
	[ "$GH_BUDGET_CLASS" = "coderabbit-chat-limit" ]
}

@test "an unrecognised notice classifies as unknown, never defaults to ok" {
	gh_budget_classify 'CodeRabbit is reviewing your changes...'
	[ "$GH_BUDGET_CLASS" = "unknown" ]
}

@test "empty text classifies as unknown" {
	gh_budget_classify ''
	[ "$GH_BUDGET_CLASS" = "unknown" ]
}

@test "gh_budget_is_terminal is true only for github-api-limit" {
	gh_budget_classify 'API rate limit exceeded for user ID 55053188'
	gh_budget_is_terminal
}

@test "gh_budget_is_terminal is false for a CodeRabbit review-limit notice" {
	gh_budget_classify 'Rate limit exceeded — please wait before requesting another review.'
	run gh_budget_is_terminal
	[ "$status" -ne 0 ]
}

@test "gh_budget_is_terminal is false for a CodeRabbit chat-limit notice" {
	gh_budget_classify 'exceeded the maximum number of chat messages per hour'
	run gh_budget_is_terminal
	[ "$status" -ne 0 ]
}

@test "gh_budget_is_terminal is false for unknown" {
	gh_budget_classify 'something unrelated entirely'
	run gh_budget_is_terminal
	[ "$status" -ne 0 ]
}

# --- 403 latch (dotfiles-dev#445) -----------------------------------------------------------------

@test "gh_budget_latch_path honours GH_BUDGET_LATCH_FILE" {
	[ "$(gh_budget_latch_path)" = "$GH_BUDGET_LATCH_FILE" ]
}

@test "no marker file means the latch is not active" {
	run gh_budget_latch_active
	[ "$status" -ne 0 ]
}

@test "a freshly written latch is active" {
	gh_budget_latch_write 300
	run gh_budget_latch_active
	[ "$status" -eq 0 ]
}

@test "a latch written with a negative TTL is already expired" {
	gh_budget_latch_write -5
	run gh_budget_latch_active
	[ "$status" -ne 0 ]
}

@test "an unparsable marker file is treated as not active" {
	echo "not-a-number" > "$GH_BUDGET_LATCH_FILE"
	run gh_budget_latch_active
	[ "$status" -ne 0 ]
}

@test "gh_budget_latch_write defaults to a 45s burst-backoff TTL" {
	gh_budget_latch_write
	now="$(date +%s)"
	until="$(cat "$GH_BUDGET_LATCH_FILE")"
	diff=$((until - now))
	[ "$diff" -gt 35 ]
	[ "$diff" -le 45 ]
}

# --- gh_budget_reset_ttl: primary exhaustion vs. secondary/concurrency burst (dotfiles-dev#445 follow-up) --

stub_gh_rate_limit() {
    # $1 = core remaining, $2 = core reset (epoch), $3 = graphql remaining, $4 = graphql reset.
    cat > "$BIN/gh" <<STUB
#!/bin/bash
case "\$*" in
"api rate_limit")
    cat <<JSON
{"resources":{"core":{"remaining":$1,"reset":$2},"graphql":{"remaining":$3,"reset":$4}}}
JSON
    ;;
*) exit 1 ;;
esac
STUB
    chmod +x "$BIN/gh"
}

@test "primary exhaustion (core remaining near zero) waits for the real reset" {
    reset=$(( $(date +%s) + 900 ))
    stub_gh_rate_limit 0 "$reset" 5000 9999999999
    ttl="$(gh_budget_reset_ttl 45)"
    [ "$ttl" -gt 890 ]
    [ "$ttl" -le 900 ]
}

@test "a secondary/concurrency burst (remaining still high) uses the short backoff, not the reset" {
    stub_gh_rate_limit 5000 9999999999 4977 9999999999
    ttl="$(gh_budget_reset_ttl 45)"
    [ "$ttl" -eq 45 ]
}

@test "an unreadable rate_limit call falls back to the burst backoff, never assumes exhaustion" {
    cat > "$BIN/gh" <<'STUB'
#!/bin/bash
exit 1
STUB
    chmod +x "$BIN/gh"
    ttl="$(gh_budget_reset_ttl 45)"
    [ "$ttl" -eq 45 ]
}

# --- gh_budget_quota_exhausted: dotfiles-dev#511 P1 -- GraphQL can be exhausted while core isn't --

@test "quota_exhausted is true when graphql remaining is under the floor, core healthy" {
    stub_gh_rate_limit 5000 9999999999 0 9999999999
    run gh_budget_quota_exhausted
    [ "$status" -eq 0 ]
}

@test "quota_exhausted is true when core remaining is under the floor, graphql healthy" {
    stub_gh_rate_limit 0 9999999999 5000 9999999999
    run gh_budget_quota_exhausted
    [ "$status" -eq 0 ]
}

@test "quota_exhausted is false when both core and graphql are healthy" {
    stub_gh_rate_limit 5000 9999999999 4977 9999999999
    run gh_budget_quota_exhausted
    [ "$status" -ne 0 ]
}

@test "quota_exhausted is false (fails closed to 'proceed') on an unreadable rate_limit call" {
    cat > "$BIN/gh" <<'STUB'
#!/bin/bash
exit 1
STUB
    chmod +x "$BIN/gh"
    run gh_budget_quota_exhausted
    [ "$status" -ne 0 ]
}

# --- gh_budget_latch_default_dir / gh_budget_latch_path: never bare world-writable /tmp ----------
# dotfiles-dev#511 review (Minor): the old default was a FIXED, PREDICTABLE filename directly
# under /tmp. On a shared host another local user can pre-create that name with a far-future
# timestamp and disable the sweep indefinitely. Every test here unsets the setup()-exported
# GH_BUDGET_LATCH_FILE to exercise the real default-resolution path.

@test "default latch dir prefers XDG_RUNTIME_DIR when it exists" {
    unset GH_BUDGET_LATCH_FILE
    export XDG_RUNTIME_DIR="$LATCH_DIR/xdg"
    mkdir -p "$XDG_RUNTIME_DIR"
    run gh_budget_latch_default_dir
    [ "$output" = "$XDG_RUNTIME_DIR" ]
}

@test "default latch dir falls back to a private HOME/.cache, never bare /tmp" {
    unset GH_BUDGET_LATCH_FILE
    unset XDG_RUNTIME_DIR
    export HOME="$LATCH_DIR/fakehome"
    run gh_budget_latch_default_dir
    [ "$output" = "$HOME/.cache" ]
    [ -d "$HOME/.cache" ]
}

@test "gh_budget_latch_path never resolves under bare /tmp with no override and no XDG dir" {
    unset GH_BUDGET_LATCH_FILE
    unset XDG_RUNTIME_DIR
    export HOME="$LATCH_DIR/fakehome2"
    run gh_budget_latch_path
    # $LATCH_DIR (mktemp -d's default TMPDIR) legitimately sits under /tmp in this test sandbox,
    # so the real assertion is "resolves under the private HOME/.cache", not "contains no /tmp
    # substring anywhere" -- the bug this guards against is a FIXED name directly at /tmp's own
    # top level (world-writable, predictable), never a private dir that happens to live there.
    [ "$output" = "$HOME/.cache/dotfiles-dev-sweep-403-until" ]
}

# --- gh_budget_latch_write: a real write failure must be reported, never swallowed ----------------
# dotfiles-dev#511 review (Minor): the old version discarded the redirect's own exit status
# entirely (`2>/dev/null`, nothing checking `$?`), so a failed write was indistinguishable from a
# successful one to every caller.

@test "gh_budget_latch_write succeeds and returns 0 when the path is writable" {
    run gh_budget_latch_write 45
    [ "$status" -eq 0 ]
    [ -f "$GH_BUDGET_LATCH_FILE" ]
}

@test "gh_budget_latch_write reports failure instead of swallowing it" {
    # A read-only PARENT dir, not a directory standing in for the file: the write now goes to a
    # temp file first (atomic rename, dotfiles-dev#511 CodeRabbit follow-up), and `mv` onto an
    # existing directory MOVES INTO it rather than failing -- the write must be blocked at its
    # source (no permission to create anything in the directory at all) to still reproduce.
    mkdir -p "$LATCH_DIR/readonly"
    chmod 500 "$LATCH_DIR/readonly"
    export GH_BUDGET_LATCH_FILE="$LATCH_DIR/readonly/marker"
    run gh_budget_latch_write 45
    [ "$status" -ne 0 ]
    [[ "$output" == *"could not write latch marker"* ]]
}

@test "gh_budget_latch_write leaves no leftover temp file behind on success" {
    # Confirms the temp-then-rename contract cleans up after itself -- a real concurrent-read
    # race is inherently timing-dependent and not something this suite tries to reproduce
    # deterministically; this checks the artifact the atomic write leaves (or doesn't).
    gh_budget_latch_write 45
    shopt -s nullglob
    leftovers=("$GH_BUDGET_LATCH_FILE".tmp.*)
    shopt -u nullglob
    [ "${#leftovers[@]}" -eq 0 ]
}
