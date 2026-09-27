#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/reviewer_ladder.sh (dotfiles-dev#444).
# Fixture-driven only: no network, no real `codex`/`qwen` invocation. Every probe
# and every runtime/post call is stubbed via the lib's own override hooks
# (REVIEWER_LADDER_*_PROBE, REVIEWER_LADDER_RUN_CMD, REVIEWER_LADDER_POST_CMD).

setup() {
    source "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/reviewer_ladder.sh"
    FIXTURES="$BATS_TEST_DIRNAME/fixtures/reviewer_ladder"
}

# --- codex resolver ----------------------------------------------------------

@test "resolves the review-specialized slug when present and invocable" {
    export REVIEWER_LADDER_CODEX_CACHE="$FIXTURES/codex_full.json"
    fake_probe() { [ "$1" = "codex-auto-review" ]; }
    export REVIEWER_LADDER_CODEX_PROBE=fake_probe

    local rc=0
    resolve_codex_model || rc=$?
    [ "$rc" -eq 0 ]
    [ "$CODEX_MODEL" = "codex-auto-review" ]
    [ "$CODEX_MODEL_SIGNAL" = "review-specialized-slug" ]
}

@test "codex: never selects by priority — reasoning richness wins regardless of priority value" {
    export REVIEWER_LADDER_CODEX_CACHE="$FIXTURES/codex_no_review.json"
    # Every candidate probes usable — priority=99 (gpt-5.5) and priority=3 (luna)
    # both lose to priority=7 (terra), which has the richest reasoning-level set.
    fake_probe() { return 0; }
    export REVIEWER_LADDER_CODEX_PROBE=fake_probe

    local rc=0
    resolve_codex_model || rc=$?
    [ "$rc" -eq 0 ]
    [ "$CODEX_MODEL" = "gpt-5.6-terra" ]
    [ "$CODEX_MODEL_SIGNAL" = "reasoning-levels-richness" ]
}

@test "codex: falls through to reasoning richness when the review slug is not invocable" {
    export REVIEWER_LADDER_CODEX_CACHE="$FIXTURES/codex_full.json"
    # codex-auto-review exists in the cache but the probe refuses it (entitlement
    # gap) — gpt-reserve (richest reasoning set) must win instead.
    fake_probe() { [ "$1" != "codex-auto-review" ]; }
    export REVIEWER_LADDER_CODEX_PROBE=fake_probe

    local rc=0
    resolve_codex_model || rc=$?
    [ "$rc" -eq 0 ]
    [ "$CODEX_MODEL" = "gpt-reserve" ]
    [ "$CODEX_MODEL_SIGNAL" = "reasoning-levels-richness" ]
}

@test "codex: no review model in the cache falls straight to reasoning richness" {
    export REVIEWER_LADDER_CODEX_CACHE="$FIXTURES/codex_no_review.json"
    fake_probe() { return 0; }
    export REVIEWER_LADDER_CODEX_PROBE=fake_probe

    local rc=0
    resolve_codex_model || rc=$?
    [ "$rc" -eq 0 ]
    [ "$CODEX_MODEL" = "gpt-5.6-terra" ]
}

@test "codex: fails closed when nothing probes usable — a rung that resolves nothing" {
    export REVIEWER_LADDER_CODEX_CACHE="$FIXTURES/codex_full.json"
    fake_probe() { return 1; }
    export REVIEWER_LADDER_CODEX_PROBE=fake_probe

    local rc=0
    resolve_codex_model || rc=$?
    [ "$rc" -eq 1 ]
    [ -z "$CODEX_MODEL" ]
    [ -z "$CODEX_MODEL_SIGNAL" ]
}

@test "codex: fails closed on a malformed cache (no models key), never guesses" {
    export REVIEWER_LADDER_CODEX_CACHE="$FIXTURES/codex_malformed.json"
    fake_probe() { return 0; }
    export REVIEWER_LADDER_CODEX_PROBE=fake_probe

    local rc=0
    resolve_codex_model || rc=$?
    [ "$rc" -eq 1 ]
    [ -z "$CODEX_MODEL" ]
}

@test "codex: fails closed on an empty models array" {
    export REVIEWER_LADDER_CODEX_CACHE="$FIXTURES/codex_empty.json"
    fake_probe() { return 0; }
    export REVIEWER_LADDER_CODEX_PROBE=fake_probe

    run resolve_codex_model
    [ "$status" -eq 1 ]
}

@test "codex: fails closed when the cache file is missing" {
    export REVIEWER_LADDER_CODEX_CACHE="$FIXTURES/does_not_exist.json"
    fake_probe() { return 0; }
    export REVIEWER_LADDER_CODEX_PROBE=fake_probe

    run resolve_codex_model
    [ "$status" -eq 1 ]
}

# --- qwen resolver -------------------------------------------------------

@test "qwen: resolves the account's configured default when it probes usable" {
    export REVIEWER_LADDER_QWEN_SETTINGS="$FIXTURES/qwen_settings.json"
    fake_probe() { [ "$1" = "qwen3.5-plus" ]; }
    export REVIEWER_LADDER_QWEN_PROBE=fake_probe

    local rc=0
    resolve_qwen_model || rc=$?
    [ "$rc" -eq 0 ]
    [ "$QWEN_MODEL" = "qwen3.5-plus" ]
    [ "$QWEN_MODEL_SIGNAL" = "configured-default" ]
}

@test "qwen: falls to the next candidate when the default fails entitlement, and fills fallbacks" {
    export REVIEWER_LADDER_QWEN_SETTINGS="$FIXTURES/qwen_settings.json"
    fake_probe() { [ "$1" != "qwen3.5-plus" ]; }
    export REVIEWER_LADDER_QWEN_PROBE=fake_probe

    local rc=0
    resolve_qwen_model || rc=$?
    [ "$rc" -eq 0 ]
    [ "$QWEN_MODEL" = "qwen3.6-plus" ]
    [ "$QWEN_MODEL_SIGNAL" = "reasoning-capable" ]
    # up to 2 runner-up candidates handed to qwen's native --fallback-model,
    # not probed individually
    [ -n "$QWEN_FALLBACK_MODELS" ]
}

@test "qwen: fails closed on malformed settings (no modelProviders key)" {
    export REVIEWER_LADDER_QWEN_SETTINGS="$FIXTURES/qwen_malformed.json"
    fake_probe() { return 0; }
    export REVIEWER_LADDER_QWEN_PROBE=fake_probe

    local rc=0
    resolve_qwen_model || rc=$?
    [ "$rc" -eq 1 ]
    [ -z "$QWEN_MODEL" ]
}

@test "qwen: fails closed when nothing probes usable" {
    export REVIEWER_LADDER_QWEN_SETTINGS="$FIXTURES/qwen_settings.json"
    fake_probe() { return 1; }
    export REVIEWER_LADDER_QWEN_PROBE=fake_probe

    local rc=0
    resolve_qwen_model || rc=$?
    [ "$rc" -eq 1 ]
}

# --- the ladder ------------------------------------------------------------

@test "ladder: qwen resolves first when both rungs are available" {
    export REVIEWER_LADDER_QWEN_SETTINGS="$FIXTURES/qwen_settings.json"
    export REVIEWER_LADDER_CODEX_CACHE="$FIXTURES/codex_full.json"
    fake_qwen_probe() { return 0; }
    fake_codex_probe() { return 0; }
    export REVIEWER_LADDER_QWEN_PROBE=fake_qwen_probe
    export REVIEWER_LADDER_CODEX_PROBE=fake_codex_probe

    local rc=0
    resolve_fallback_reviewer || rc=$?
    [ "$rc" -eq 0 ]
    [ "$LADDER_RUNTIME" = "qwen" ]
}

@test "ladder: falls through to codex when the qwen rung resolves nothing" {
    export REVIEWER_LADDER_QWEN_SETTINGS="$FIXTURES/qwen_malformed.json"
    export REVIEWER_LADDER_CODEX_CACHE="$FIXTURES/codex_full.json"
    fake_codex_probe() { [ "$1" = "codex-auto-review" ]; }
    export REVIEWER_LADDER_CODEX_PROBE=fake_codex_probe

    local rc=0
    resolve_fallback_reviewer || rc=$?
    [ "$rc" -eq 0 ]
    [ "$LADDER_RUNTIME" = "codex" ]
    [ "$LADDER_MODEL" = "codex-auto-review" ]
}

@test "ladder: neither rung resolves — LADDER_RUNTIME stays none, returns 1" {
    export REVIEWER_LADDER_QWEN_SETTINGS="$FIXTURES/qwen_malformed.json"
    export REVIEWER_LADDER_CODEX_CACHE="$FIXTURES/codex_malformed.json"

    local rc=0
    resolve_fallback_reviewer || rc=$?
    [ "$rc" -eq 1 ]
    [ "$LADDER_RUNTIME" = "none" ]
}

# --- attribution, blast radius --------------------------------------------

@test "attribution line names the runtime, model, and selection signal" {
    run ladder_attribution_line "codex" "codex-auto-review" "review-specialized-slug"
    [[ "$output" == "Fallback review — runtime: codex, model: codex-auto-review (selected by: review-specialized-slug)" ]]
}

ATTRIBUTION='Fallback review — runtime: codex, model: codex-auto-review (selected by: review-specialized-slug)'

@test "already-covered: the ladder's own attribution comment blocks a re-review" {
    export REVIEWER_LADDER_POSTER=ladder-bot
    run ladder_already_covered "$(jq -cn --arg a "$ATTRIBUTION" \
        '[{user:{login:"someone"},body:"some comment"},{user:{login:"ladder-bot"},body:$a}]')"
    [ "$status" -eq 0 ]
}

@test "already-covered: no attribution line present is not covered" {
    export REVIEWER_LADDER_POSTER=ladder-bot
    run ladder_already_covered '[{"user":{"login":"ladder-bot"},"body":"a normal comment, no marker"}]'
    [ "$status" -eq 1 ]
}

@test "already-covered: a forged marker from another commenter does NOT skip the review" {
    export REVIEWER_LADDER_POSTER=ladder-bot
    run ladder_already_covered "$(jq -cn --arg a "$ATTRIBUTION" \
        '[{user:{login:"drive-by"},body:$a}]')"
    [ "$status" -eq 1 ]
}

@test "already-covered: joined text (the old contract) is not an array — not covered" {
    export REVIEWER_LADDER_POSTER=ladder-bot
    run ladder_already_covered "$ATTRIBUTION"
    [ "$status" -eq 1 ]
}

@test "already-covered: an unresolvable poster login fails closed into not covered" {
    export REVIEWER_LADDER_POSTER=""
    gh() { return 1; }
    export -f gh
    run ladder_already_covered "$(jq -cn --arg a "$ATTRIBUTION" '[{user:{login:"x"},body:$a}]')"
    [ "$status" -eq 1 ]
}

@test "candidate gate: a DIRTY PR is never a candidate" {
    run ladder_candidate_ok "DIRTY" "" 1000
    [ "$status" -eq 1 ]
}

@test "candidate gate: pushed 2 minutes ago is skipped (inside the ~10 minute window)" {
    run ladder_candidate_ok "BLOCKED" 1000 1120
    [ "$status" -eq 1 ]
}

@test "candidate gate: pushed 20 minutes ago, not DIRTY, is a valid candidate" {
    run ladder_candidate_ok "BLOCKED" 1000 2200
    [ "$status" -eq 0 ]
}

# --- run_fallback_review orchestration + dry-run ----------------------------

@test "dry-run resolves and reports, but posts nothing and runs no review" {
    export REVIEWER_LADDER_QWEN_SETTINGS="$FIXTURES/qwen_settings.json"
    fake_probe() { return 0; }
    export REVIEWER_LADDER_QWEN_PROBE=fake_probe
    _run_runtime_review() { echo "SHOULD NOT BE CALLED" >&2; return 1; }
    _post_pr_comment() { echo "SHOULD NOT BE CALLED" >&2; return 1; }
    export -f _run_runtime_review _post_pr_comment

    run run_fallback_review o r 42 BLOCKED "" 5000 "[]" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY RUN"* ]]
    [[ "$output" != *"SHOULD NOT BE CALLED"* ]]
}

@test "dry-run never reaches a live probe: no override set, real binaries shadowed" {
    export REVIEWER_LADDER_QWEN_SETTINGS="$FIXTURES/qwen_settings.json"
    export REVIEWER_LADDER_CODEX_CACHE="$FIXTURES/codex_full.json"
    unset REVIEWER_LADDER_QWEN_PROBE REVIEWER_LADDER_CODEX_PROBE
    qwen() { echo "LIVE PROBE" >&2; return 1; }
    codex() { echo "LIVE PROBE" >&2; return 1; }
    export -f qwen codex

    run run_fallback_review o r 42 BLOCKED "" 5000 "[]" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY RUN"* ]]
    [[ "$output" == *"unprobed"* ]]
    [[ "$output" != *"LIVE PROBE"* ]]
}

@test "already-covered PR is skipped before the resolver ever runs" {
    export REVIEWER_LADDER_POSTER=ladder-bot
    resolve_fallback_reviewer() { echo "SHOULD NOT RESOLVE" >&2; return 1; }
    export -f resolve_fallback_reviewer

    run run_fallback_review o r 42 BLOCKED "" 5000 \
        "$(jq -cn --arg a "$ATTRIBUTION" '[{user:{login:"ladder-bot"},body:$a}]')"
    [ "$status" -eq 0 ]
    [[ "$output" != *"SHOULD NOT RESOLVE"* ]]
}

@test "a DIRTY PR is refused before the resolver ever runs" {
    resolve_fallback_reviewer() { echo "SHOULD NOT RESOLVE" >&2; return 1; }
    export -f resolve_fallback_reviewer

    run run_fallback_review o r 42 DIRTY "" 5000 ""
    [ "$status" -eq 1 ]
    [[ "$output" != *"SHOULD NOT RESOLVE"* ]]
}

@test "no rung resolves — run_fallback_review fails closed, posts nothing" {
    export REVIEWER_LADDER_QWEN_SETTINGS="$FIXTURES/qwen_malformed.json"
    export REVIEWER_LADDER_CODEX_CACHE="$FIXTURES/codex_malformed.json"
    _post_pr_comment() { echo "SHOULD NOT BE CALLED" >&2; return 1; }
    export -f _post_pr_comment

    run run_fallback_review o r 42 BLOCKED "" 5000 ""
    [ "$status" -eq 1 ]
    [[ "$output" != *"SHOULD NOT BE CALLED"* ]]
}

# --- codex runtime invocation (measured live on #447, 2026-09-21) ------------

@test "codex review: passes --base and never --skip-git-repo-check" {
    codex() { printf 'codex %s\n' "$*"; }
    git() { [ "$1" = rev-parse ] && return 0; command git "$@"; }
    export -f codex git
    export REVIEWER_LADDER_BASE=origin/master
    run _run_runtime_review codex codex-auto-review "" 447
    [ "$status" -eq 0 ]
    [[ "$output" == "codex -m codex-auto-review review --base origin/master --title PR #447" ]]
    [[ "$output" != *"review --base origin/master PR"* ]]
    [[ "$output" != *"skip-git-repo-check"* ]]
}

@test "codex review: fails closed when no base ref resolves, calling no runtime" {
    codex() { echo "RUNTIME CALLED" >&2; return 0; }
    git() { return 1; }
    export -f codex git
    unset REVIEWER_LADDER_BASE
    run _run_runtime_review codex codex-auto-review "" 447
    [ "$status" -eq 1 ]
    [[ "$output" != *"RUNTIME CALLED"* ]]
}

@test "print_status falls back to stderr, never to silence, when common.sh is absent" {
    run bash -c "unset -f print_status; LIB_DIR=/nonexistent; source '$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/reviewer_ladder.sh'; declare -F print_status >/dev/null && print_status warning hello"
    [ "$status" -eq 0 ]
    [ "$output" = "warning: hello" ]
}

@test "codex review: a base that is not a git ref fails closed, calling no runtime" {
    codex() { echo "RUNTIME CALLED" >&2; return 0; }
    export -f codex
    export REVIEWER_LADDER_BASE=origin/no-such-branch-xyz
    run _run_runtime_review codex codex-auto-review "" 447
    [ "$status" -eq 1 ]
    [[ "$output" != *"RUNTIME CALLED"* ]]
}

# --- PR-head resolution & assertion (dotfiles-dev#487) ----------------------
#
# codex review diffs the AMBIENT WORKING TREE, never a PR by number. Measured
# live 2026-09-23: invoked for PR #474 from the repo root on master, it
# posted "No changes are present relative to the specified merge base" as a
# forged clean review — re-run from a detached worktree at #474's real head,
# same function, same args, 3 findings (two P1). These tests prove both
# halves the fix must hold: a checkout AT the PR's head is accepted, and a
# checkout AT the base (the exact measured bug) is refused with nothing
# posted.

_make_two_commit_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init --quiet
    git -C "$dir" config user.email t@example.com
    git -C "$dir" config user.name t
    echo base >"$dir/f.txt"
    git -C "$dir" add f.txt
    git -C "$dir" commit --quiet -m base
    BASE_SHA="$(git -C "$dir" rev-parse HEAD)"
    echo pr-change >"$dir/f.txt"
    git -C "$dir" add f.txt
    git -C "$dir" commit --quiet -m "pr change"
    HEAD_SHA="$(git -C "$dir" rev-parse HEAD)"
}

@test "assert_worktree_matches_pr: a checkout AT the PR's head passes" {
    local repo="$BATS_TEST_TMPDIR/repo-match"
    _make_two_commit_repo "$repo"
    fake_head_sha() { printf '%s\n' "$HEAD_SHA"; }
    export -f fake_head_sha
    export REVIEWER_LADDER_HEAD_SHA_CMD=fake_head_sha

    run assert_worktree_matches_pr "$repo" o r 487
    [ "$status" -eq 0 ]
}

@test "assert_worktree_matches_pr: a checkout AT the base — the measured #487 bug — is refused" {
    local repo="$BATS_TEST_TMPDIR/repo-base"
    _make_two_commit_repo "$repo"
    git -C "$repo" checkout --quiet "$BASE_SHA"
    fake_head_sha() { printf '%s\n' "$HEAD_SHA"; }
    export -f fake_head_sha
    export REVIEWER_LADDER_HEAD_SHA_CMD=fake_head_sha

    run assert_worktree_matches_pr "$repo" o r 487
    [ "$status" -eq 1 ]
}

@test "assert_worktree_matches_pr: fails closed when the forge reports no head at all" {
    local repo="$BATS_TEST_TMPDIR/repo-noanswer"
    _make_two_commit_repo "$repo"
    fake_head_sha() { :; }
    export -f fake_head_sha
    export REVIEWER_LADDER_HEAD_SHA_CMD=fake_head_sha

    run assert_worktree_matches_pr "$repo" o r 487
    [ "$status" -eq 1 ]
}

# --- ABSENT vs CONTRADICTED forge answer (dotfiles-dev#543) -----------------
#
# assert_worktree_matches_pr is called directly (not via `run`) in these
# three so ASSERT_WORKTREE_STATUS — a plain global, same pattern as
# CODEX_MODEL/QWEN_MODEL above — survives past the call; `run` forks a
# subshell and would discard it.

@test "assert_worktree_matches_pr: status is unanswerable when the forge gives no head" {
    local repo="$BATS_TEST_TMPDIR/repo-status-unanswerable"
    _make_two_commit_repo "$repo"
    fake_head_sha() { :; }
    export -f fake_head_sha
    export REVIEWER_LADDER_HEAD_SHA_CMD=fake_head_sha

    local rc=0
    assert_worktree_matches_pr "$repo" o r 487 || rc=$?
    [ "$rc" -eq 1 ]
    [ "$ASSERT_WORKTREE_STATUS" = "unanswerable" ]
}

@test "assert_worktree_matches_pr: status is mismatched when the forge answers but differs" {
    local repo="$BATS_TEST_TMPDIR/repo-status-mismatched"
    _make_two_commit_repo "$repo"
    git -C "$repo" checkout --quiet "$BASE_SHA"
    fake_head_sha() { printf '%s\n' "$HEAD_SHA"; }
    export -f fake_head_sha
    export REVIEWER_LADDER_HEAD_SHA_CMD=fake_head_sha

    local rc=0
    assert_worktree_matches_pr "$repo" o r 487 || rc=$?
    [ "$rc" -eq 1 ]
    [ "$ASSERT_WORKTREE_STATUS" = "mismatched" ]
}

@test "assert_worktree_matches_pr: status is matched when HEAD equals the forge's answer" {
    local repo="$BATS_TEST_TMPDIR/repo-status-matched"
    _make_two_commit_repo "$repo"
    fake_head_sha() { printf '%s\n' "$HEAD_SHA"; }
    export -f fake_head_sha
    export REVIEWER_LADDER_HEAD_SHA_CMD=fake_head_sha

    local rc=0
    assert_worktree_matches_pr "$repo" o r 487 || rc=$?
    [ "$rc" -eq 0 ]
    [ "$ASSERT_WORKTREE_STATUS" = "matched" ]
}

@test "assert_worktree_matches_pr: fails closed on an unreadable dir" {
    fake_head_sha() { echo deadbeef; }
    export -f fake_head_sha
    export REVIEWER_LADDER_HEAD_SHA_CMD=fake_head_sha

    run assert_worktree_matches_pr "$BATS_TEST_TMPDIR/does-not-exist" o r 487
    [ "$status" -eq 1 ]
}

@test "_pr_head_sha: override receives owner, repo, and PR number" {
    fake() { printf '%s/%s#%s\n' "$1" "$2" "$3"; }
    export -f fake
    export REVIEWER_LADDER_HEAD_SHA_CMD=fake
    run _pr_head_sha o r 487
    [ "$output" = "o/r#487" ]
}

# --- REST over GraphQL for both injectable seams (dotfiles-dev#543) ---------
#
# Both defaults used to shell out to GraphQL (`gh pr view --json`, `gh pr
# comment`), which is the surface that stays refused during exactly the
# outage the fallback rung exists for. A dry run never invokes either
# default (see the "dry-run never reaches a live probe" test above), so it
# is not evidence here — these stub `gh` itself and assert on its argv.

@test "_pr_head_sha: default command is REST (pulls/{n}.head.sha), never gh pr view --json" {
    unset REVIEWER_LADDER_HEAD_SHA_CMD
    GH_LOG="$BATS_TEST_TMPDIR/gh-head-sha.log"
    : >"$GH_LOG"
    gh() { printf '%s\n' "$*" >>"$GH_LOG"; echo deadbeef; }
    export -f gh
    export GH_LOG

    run _pr_head_sha o r 487
    [ "$status" -eq 0 ]
    [ "$output" = "deadbeef" ]
    run grep -F -- '--json' "$GH_LOG"
    [ "$status" -ne 0 ]
    run grep -F -- 'api repos/o/r/pulls/487' "$GH_LOG"
    [ "$status" -eq 0 ]
}

@test "_post_pr_comment: default command is REST (issues/{n}/comments), never gh pr comment" {
    unset REVIEWER_LADDER_POST_CMD
    GH_LOG="$BATS_TEST_TMPDIR/gh-post.log"
    : >"$GH_LOG"
    gh() {
        printf '%s\n' "$*" >>"$GH_LOG"
        cat >/dev/null
    }
    export -f gh
    export GH_LOG

    run _post_pr_comment o r 487 "hello world"
    [ "$status" -eq 0 ]
    run grep -F -- 'pr comment' "$GH_LOG"
    [ "$status" -ne 0 ]
    run grep -F -- 'api --method POST repos/o/r/issues/487/comments' "$GH_LOG"
    [ "$status" -eq 0 ]
}

@test "_pr_remote_url: default fetches from the forge's owner/repo, never a local remote name" {
    unset REVIEWER_LADDER_REMOTE_URL_CMD
    run _pr_remote_url someowner somerepo
    [ "$output" = "https://github.com/someowner/somerepo.git" ]
}

@test "_pr_remote_url: override receives owner and repo" {
    fake() { printf '%s@%s\n' "$1" "$2"; }
    export -f fake
    export REVIEWER_LADDER_REMOTE_URL_CMD=fake
    run _pr_remote_url o r
    [ "$output" = "o@r" ]
}

# --- _checkout_pr_worktree: the real (non-overridden) fetch+worktree path ---
#
# CodeRabbit's review of this PR flagged that only the override contract was
# exercised — the real `git fetch`/`worktree add` path could have its
# assertion call deleted and no test would notice. These fetch from a LOCAL
# bare repo (via REVIEWER_LADDER_REMOTE_URL_CMD pointed at a `file://` path,
# never the network) so the real code path runs end to end, deterministically.

_make_bare_remote_with_pr() {
    local bare="$1" pr_number="$2"
    git init --quiet --bare "$bare"
    local work="$BATS_TEST_TMPDIR/seed-$pr_number"
    git clone --quiet "$bare" "$work"
    git -C "$work" config user.email t@example.com
    git -C "$work" config user.name t
    echo base >"$work/f.txt"
    git -C "$work" add f.txt
    git -C "$work" commit --quiet -m base
    git -C "$work" push --quiet origin HEAD:refs/heads/main
    BASE_SHA="$(git -C "$work" rev-parse HEAD)"
    echo change >"$work/f.txt"
    git -C "$work" add f.txt
    git -C "$work" commit --quiet -m "pr change"
    git -C "$work" push --quiet origin "HEAD:refs/pull/$pr_number/head"
    PR_HEAD_SHA="$(git -C "$work" rev-parse HEAD)"
}

@test "_checkout_pr_worktree: real path fetches by explicit URL, verifies, and tears down clean" {
    export TMPDIR="$BATS_TEST_TMPDIR"
    local bare="$BATS_TEST_TMPDIR/remote-555.git"
    _make_bare_remote_with_pr "$bare" 555
    fake_url() { printf 'file://%s\n' "$bare"; }
    export -f fake_url
    export REVIEWER_LADDER_REMOTE_URL_CMD=fake_url
    fake_head_sha() { printf '%s\n' "$PR_HEAD_SHA"; }
    export -f fake_head_sha
    export REVIEWER_LADDER_HEAD_SHA_CMD=fake_head_sha
    unset REVIEWER_LADDER_CHECKOUT_CMD

    local rc=0
    _checkout_pr_worktree o r 555 || rc=$?
    [ "$rc" -eq 0 ]
    [ -d "$PR_WORKTREE_DIR" ]
    [ "$(git -C "$PR_WORKTREE_DIR" rev-parse HEAD)" = "$PR_HEAD_SHA" ]

    local wt="$PR_WORKTREE_DIR"
    _teardown_pr_worktree "$wt"
    [ ! -d "$wt" ]
}

@test "_checkout_pr_worktree: real path refuses and leaks nothing when the fetched ref isn't the forge's head" {
    export TMPDIR="$BATS_TEST_TMPDIR"
    local bare="$BATS_TEST_TMPDIR/remote-556.git"
    _make_bare_remote_with_pr "$bare" 556
    fake_url() { printf 'file://%s\n' "$bare"; }
    export -f fake_url
    export REVIEWER_LADDER_REMOTE_URL_CMD=fake_url
    # the forge claims the BASE commit is the PR's head — the exact #487
    # mismatch shape, now hit through the real fetch/worktree-add code path.
    fake_head_sha() { printf '%s\n' "$BASE_SHA"; }
    export -f fake_head_sha
    export REVIEWER_LADDER_HEAD_SHA_CMD=fake_head_sha
    unset REVIEWER_LADDER_CHECKOUT_CMD

    local rc=0
    _checkout_pr_worktree o r 556 || rc=$?
    [ "$rc" -eq 1 ]
    [ -z "$PR_WORKTREE_DIR" ]
    run bash -c "compgen -G \"$TMPDIR/reviewer-ladder-pr556-*\""
    [ "$status" -ne 0 ]
}

@test "_checkout_pr_worktree: real path — a mismatch reports 'does not match', never 'cannot reach the forge'" {
    export TMPDIR="$BATS_TEST_TMPDIR"
    local bare="$BATS_TEST_TMPDIR/remote-556b.git"
    _make_bare_remote_with_pr "$bare" 5561
    fake_url() { printf 'file://%s\n' "$bare"; }
    export -f fake_url
    export REVIEWER_LADDER_REMOTE_URL_CMD=fake_url
    fake_head_sha() { printf '%s\n' "$BASE_SHA"; }
    export -f fake_head_sha
    export REVIEWER_LADDER_HEAD_SHA_CMD=fake_head_sha
    unset REVIEWER_LADDER_CHECKOUT_CMD

    run _checkout_pr_worktree o r 5561
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not match the forge's head"* ]]
    [[ "$output" != *"cannot reach the forge"* ]]
}

@test "_checkout_pr_worktree: real path — an ABSENT forge answer reports 'cannot reach the forge', never 'does not match' (dotfiles-dev#543)" {
    export TMPDIR="$BATS_TEST_TMPDIR"
    local bare="$BATS_TEST_TMPDIR/remote-557.git"
    _make_bare_remote_with_pr "$bare" 557
    fake_url() { printf 'file://%s\n' "$bare"; }
    export -f fake_url
    export REVIEWER_LADDER_REMOTE_URL_CMD=fake_url
    # the forge does not answer at all — e.g. a GraphQL outage — never a
    # real, differing sha. This is the exact #543 bug: it used to be
    # reported identically to the mismatch case above.
    fake_head_sha() { :; }
    export -f fake_head_sha
    export REVIEWER_LADDER_HEAD_SHA_CMD=fake_head_sha
    unset REVIEWER_LADDER_CHECKOUT_CMD

    run _checkout_pr_worktree o r 557
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot reach the forge to verify the head"* ]]
    [[ "$output" != *"does not match the forge's head"* ]]
}

# --- _run_runtime_review: an empty diff is an error, never a finding --------

@test "codex review: an empty diff is an ERROR that posts nothing — never a finding" {
    git() { [ "$1" = rev-parse ] && return 0; command git "$@"; }
    codex() {
        printf 'No changes are present relative to the specified merge base; HEAD is exactly the merge base commit.\n'
    }
    export -f git codex
    export REVIEWER_LADDER_BASE=origin/master
    run _run_runtime_review codex codex-auto-review "" 474
    [ "$status" -eq 1 ]
}

@test "codex review: a literally empty stdout is also an ERROR, never a finding" {
    git() { [ "$1" = rev-parse ] && return 0; command git "$@"; }
    codex() { :; }
    export -f git codex
    export REVIEWER_LADDER_BASE=origin/master
    run _run_runtime_review codex codex-auto-review "" 474
    [ "$status" -eq 1 ]
}

@test "codex review: runs in WORKDIR and strips its absolute path from findings" {
    git() { [ "$1" = rev-parse ] && return 0; command git "$@"; }
    codex() { printf 'issue at %s/ai_clients/claude/hooks/lib/x.sh:12\n' "$PWD"; }
    export -f git codex
    export REVIEWER_LADDER_BASE=origin/master
    local workdir="$BATS_TEST_TMPDIR/wt-474"
    mkdir -p "$workdir"

    run _run_runtime_review codex codex-auto-review "" 474 "$workdir"
    [ "$status" -eq 0 ]
    [ "$output" = "issue at ai_clients/claude/hooks/lib/x.sh:12" ]
}

@test "codex review: strips the CANONICAL worktree path too, not just the logical one given" {
    # CodeRabbit finding: \${TMPDIR:-/tmp} can differ from its realpath (e.g.
    # macOS /tmp -> /private/tmp) — a symlinked workdir reproduces that shape
    # locally: codex resolves its cwd's realpath itself, so the string it
    # emits is the CANONICAL path, never the logical \$workdir handed in.
    local real_dir="$BATS_TEST_TMPDIR/real-475"
    local workdir="$BATS_TEST_TMPDIR/link-475"
    mkdir -p "$real_dir"
    ln -s "$real_dir" "$workdir"
    git() { [ "$1" = rev-parse ] && return 0; command git "$@"; }
    codex() { printf 'issue at %s/x.sh:1\n' "$(pwd -P)"; }
    export -f git codex
    export REVIEWER_LADDER_BASE=origin/master

    run _run_runtime_review codex codex-auto-review "" 475 "$workdir"
    [ "$status" -eq 0 ]
    [ "$output" = "issue at x.sh:1" ]
}

# --- run_fallback_review: end to end, the PR's own worked example -----------

@test "run_fallback_review: codex posts when the resolved checkout is verified" {
    export REVIEWER_LADDER_QWEN_SETTINGS="$FIXTURES/qwen_malformed.json"
    export REVIEWER_LADDER_CODEX_CACHE="$FIXTURES/codex_full.json"
    fake_codex_probe() { [ "$1" = "codex-auto-review" ]; }
    export REVIEWER_LADDER_CODEX_PROBE=fake_codex_probe
    fake_checkout() { echo "$BATS_TEST_TMPDIR"; }
    export -f fake_checkout
    export REVIEWER_LADDER_CHECKOUT_CMD=fake_checkout
    fake_run() { echo "3 findings, two P1"; }
    export -f fake_run
    export REVIEWER_LADDER_RUN_CMD=fake_run
    fake_post() { printf 'POSTED:%s\n' "$4"; }
    export -f fake_post
    export REVIEWER_LADDER_POST_CMD=fake_post

    run run_fallback_review o r 474 BLOCKED "" 5000 "[]"
    [ "$status" -eq 0 ]
    [[ "$output" == *"POSTED:"* ]]
    [[ "$output" == *"3 findings, two P1"* ]]
}

@test "run_fallback_review: refuses and posts nothing when the checkout can't be verified (the base-checkout case)" {
    export REVIEWER_LADDER_QWEN_SETTINGS="$FIXTURES/qwen_malformed.json"
    export REVIEWER_LADDER_CODEX_CACHE="$FIXTURES/codex_full.json"
    fake_codex_probe() { [ "$1" = "codex-auto-review" ]; }
    export REVIEWER_LADDER_CODEX_PROBE=fake_codex_probe
    fake_checkout() { :; } # empty output == assert_worktree_matches_pr failed
    export -f fake_checkout
    export REVIEWER_LADDER_CHECKOUT_CMD=fake_checkout
    fake_run() { echo "SHOULD NOT RUN" >&2; }
    export -f fake_run
    export REVIEWER_LADDER_RUN_CMD=fake_run
    fake_post() { echo "SHOULD NOT POST" >&2; }
    export -f fake_post
    export REVIEWER_LADDER_POST_CMD=fake_post

    run run_fallback_review o r 474 BLOCKED "" 5000 "[]"
    [ "$status" -eq 1 ]
    [[ "$output" != *"SHOULD NOT RUN"* ]]
    [[ "$output" != *"SHOULD NOT POST"* ]]
}
