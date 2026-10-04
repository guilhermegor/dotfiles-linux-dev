#!/usr/bin/env bats
#
# Invariants for .github/workflows/review_threads.yml (dotfiles-linux-dev#481).
#
# The defect this pins down is not a logic bug inside the gate — the gate was correct. It is
# that the verdict was published to the WRONG COMMIT: for an issue_comment event GitHub runs
# the workflow in the default branch's context, so Actions attached the check-run to master's
# SHA and the required context was absent from every PR head. Nothing went red; 22 PRs simply
# could not merge.
#
# These are structural assertions over the YAML rather than a live run, because the failure is
# a property of WHERE the job reports, which no local execution can exercise.

setup() {
    WORKFLOW="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/.github/workflows/review_threads.yml"
    RUN_SCRIPT="$BATS_TEST_TMPDIR/run.sh"
    python3 - "$WORKFLOW" "$RUN_SCRIPT" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
step = next(s for s in doc["jobs"]["gate"]["steps"] if "run" in s)
open(sys.argv[2], "w").write(step["run"])
PY
}

@test "the job may write checks — without it every publish 403s" {
    run python3 -c "
import yaml,sys
d = yaml.safe_load(open(sys.argv[1]))
print((d.get('permissions') or {}).get('checks',''))
" "$WORKFLOW"
    [ "$status" -eq 0 ]
    [ "$output" = "write" ]
}

@test "the check-run targets the PR head, never the event's own SHA" {
    grep -q 'HEAD_SHA=.*pulls/\$PR_NUMBER' "$RUN_SCRIPT"
    grep -q 'head_sha:\$s' "$RUN_SCRIPT"
    # github.sha is master for issue_comment — the whole defect. It must not be the source.
    run grep -c 'github\.sha' "$RUN_SCRIPT"
    [ "$output" -eq 0 ]
}

@test "no success path terminates without publishing a verdict" {
    # Strip the report() helper, whose own `exit 0` is the single legitimate one. Anything
    # left that exits 0 is a path that ends with no check-run on the PR head — which is the
    # selective-skip regression: "not required" still leaves the PR blocked.
    python3 - "$RUN_SCRIPT" "$BATS_TEST_TMPDIR/stripped.sh" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
stripped = re.sub(r"\n\s*report\(\) \{.*?\n\s*\}\n", "\n", src, flags=re.S)
assert "report() {" not in stripped, "report() helper was not stripped"
open(sys.argv[2], "w").write(stripped)
PY
    run grep -c 'exit 0' "$BATS_TEST_TMPDIR/stripped.sh"
    [ "$output" -eq 0 ]
}

@test "the only non-zero exit is an unpublishable verdict, not a failing one" {
    # A failing gate must still report `failure` and exit 0: the check-run carries the verdict.
    # Exiting non-zero to mirror it would leave the run red with nothing on the PR.
    grep -q 'could not publish the check-run' "$RUN_SCRIPT"
    run grep -c 'exit 1' "$RUN_SCRIPT"
    [ "$output" -eq 1 ]
}

@test "all four outcomes publish: two success, two failure" {
    run grep -c 'report success' "$RUN_SCRIPT"
    [ "$output" -eq 2 ]
    run grep -c 'report failure' "$RUN_SCRIPT"
    [ "$output" -eq 2 ]
}

@test "issue_comment is still a trigger — #431's fix is not undone by this one" {
    run python3 -c "
import yaml,sys
print(sorted((yaml.safe_load(open(sys.argv[1])).get(True) or {}).keys()))
" "$WORKFLOW"
    [[ "$output" == *"issue_comment"* ]]
    [[ "$output" == *"pull_request_review"* ]]
    [[ "$output" == *"pull_request_review_comment"* ]]
}

@test "checkout is pinned to the default branch, never the event's ref" {
    # The privileged half of #481: `checks: write` makes the sourced gate library worth
    # attacking. For pull_request_review/pull_request_review_comment GITHUB_REF is the PR
    # MERGE REF, so a bare checkout would run PR-controlled code with a token that can
    # publish a passing required check without consulting gate_pr_thread_state at all.
    run python3 -c "
import yaml,sys
d = yaml.safe_load(open(sys.argv[1]))
step = next(s for s in d['jobs']['gate']['steps'] if 'checkout' in str(s.get('uses','')))
print((step.get('with') or {}).get('ref',''))
" "$WORKFLOW"
    [ "$status" -eq 0 ]
    [[ "$output" == *"default_branch"* ]]
}

# --- dotfiles-linux-dev#550: the ladder marker's history path -------------------------------------------
#
# CodeRabbit's marker was already re-resolved from PR HISTORY (comments after head_seen_at), so a
# later ordinary comment re-running this job could never revoke it. The ladder marker (#444/#446)
# had no such path: it was credited ONLY from the triggering event's own COMMENT_BODY. The reply
# that ANSWERS a ladder finding is itself an issue_comment, so it re-ran this job with a
# non-matching body and revoked the credit -- the whole defect in one sentence. This test proves
# the fix: an earlier ladder marker, now resolved from history, survives a later non-marker reply
# triggering the run.

# The head the gh stub below reports for /pulls/N, and the one a creditable marker must name.
STUB_HEAD=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef

# run_ladder_step COMMENT_BODY COMMENTS_JSON
# Stubs every `gh` call the script makes and a minimal gate_pr_thread_state() (this test is scoped
# to the reviewer_reported logic in review_threads.yml, not a review_thread_gate.sh integration --
# that file has its own suite). Runs from a scratch WORKDIR carrying a stub
# ai_clients/claude/hooks/lib/review_thread_gate.sh so the script's own `source` line resolves.
run_ladder_step() {
    local triggering_body="$1" comments_json="$2"
    mkdir -p "$BATS_TEST_TMPDIR/ai_clients/claude/hooks/lib"
    cat > "$BATS_TEST_TMPDIR/ai_clients/claude/hooks/lib/review_thread_gate.sh" <<'GATE'
gate_pr_thread_state() { GATE_STATUS=clean; GATE_DETAIL="stub-clean"; }
GATE

    CHECK_RUN_OUT="$BATS_TEST_TMPDIR/check-run.json"
    : > "$CHECK_RUN_OUT"

    run env OWNER=o REPO=r PR_NUMBER=9 EVENT_NAME=issue_comment \
        COMMENT_AUTHOR=guilhermegor COMMENT_AUTHOR_ASSOCIATION=OWNER \
        COMMENT_BODY="$triggering_body" \
        RUN_SCRIPT="$RUN_SCRIPT" WORKDIR="$BATS_TEST_TMPDIR" \
        COMMENTS_JSON="$comments_json" HEAD_SEEN="2026-09-27T12:00:00Z" \
        CHECK_RUN_OUT="$CHECK_RUN_OUT" \
        bash -c '
            cd "$WORKDIR" || exit 1
            gh() {
                case "$*" in
                    *"/pulls/"*)        echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ;;
                    *"--json files"*)   printf "%s\n" "ai_clients/claude/hooks/lib/foo.sh" ;;
                    *"--json reviews"*) echo "0" ;;
                    *check-suites*)     echo "$HEAD_SEEN" ;;
                    *"/comments"*)      printf "%s\n" "$COMMENTS_JSON" ;;
                    *check-runs*)       cat > "$CHECK_RUN_OUT" ;;
                    *) return 1 ;;
                esac
            }
            export -f gh
            bash "$RUN_SCRIPT"
        '
}

@test "#550: a marker earned in HISTORY is not revoked by a later non-marker reply" {
    marker_body=$'Fallback review — runtime: qwen, model: gpt-x (selected by: probe)\nReviewed head: '"$STUB_HEAD"$'\n\nNo issues found.'
    second_body='Thanks, fixed in abc123.'
    comments_json="$(jq -nc --arg m "$marker_body" --arg s "$second_body" '[
      {user:{login:"guilhermegor",type:"User"}, author_association:"OWNER",
       body:$m, created_at:"2026-09-27T12:38:40Z"},
      {user:{login:"guilhermegor",type:"User"}, author_association:"OWNER",
       body:$s, created_at:"2026-09-27T12:39:49Z"}
    ]')"

    run_ladder_step "$second_body" "$comments_json"

    [ "$status" -eq 0 ]
    [ "$(jq -r '.conclusion' "$CHECK_RUN_OUT")" = "success" ]
}

@test "#550: no marker anywhere in history still fails, the gate is not disabled" {
    comments_json='[{"user":{"login":"guilhermegor","type":"User"},"author_association":"OWNER","body":"just chatting","created_at":"2026-09-27T12:39:49Z"}]'

    run_ladder_step "just chatting" "$comments_json"

    [ "$status" -eq 0 ]
    [ "$(jq -r '.conclusion' "$CHECK_RUN_OUT")" = "failure" ]
}

@test "#550: a forged marker from a NONE-association commenter is ignored (CWE-345 survives history)" {
    marker_body=$'Fallback review — runtime: qwen, model: gpt-x (selected by: probe)\nReviewed head: '"$STUB_HEAD"$'\n\nNo issues found.'
    comments_json="$(jq -nc --arg m "$marker_body" '[
      {user:{login:"randomuser",type:"User"}, author_association:"NONE",
       body:$m, created_at:"2026-09-27T12:38:40Z"}
    ]')"

    run_ladder_step "unrelated reply" "$comments_json"

    [ "$status" -eq 0 ]
    [ "$(jq -r '.conclusion' "$CHECK_RUN_OUT")" = "failure" ]
}

@test "#550: a marker posted BEFORE the current head does not validate it" {
    marker_body=$'Fallback review — runtime: qwen, model: gpt-x (selected by: probe)\nReviewed head: '"$STUB_HEAD"$'\n\nNo issues found.'
    comments_json="$(jq -nc --arg m "$marker_body" '[
      {user:{login:"guilhermegor",type:"User"}, author_association:"OWNER",
       body:$m, created_at:"2026-09-27T11:00:00Z"}
    ]')"

    run_ladder_step "unrelated reply" "$comments_json"

    [ "$status" -eq 0 ]
    [ "$(jq -r '.conclusion' "$CHECK_RUN_OUT")" = "failure" ]
}

@test "#564: a fresh marker naming a DIFFERENT head is not credited from history" {
    marker_body=$'Fallback review — runtime: qwen, model: gpt-x (selected by: probe)\nReviewed head: 0123456789abcdef\n\nNo issues found.'
    comments_json="$(jq -nc --arg m "$marker_body" '[
      {user:{login:"guilhermegor",type:"User"}, author_association:"OWNER",
       body:$m, created_at:"2026-09-27T12:38:40Z"}
    ]')"

    run_ladder_step "unrelated reply" "$comments_json"

    [ "$status" -eq 0 ]
    [ "$(jq -r '.conclusion' "$CHECK_RUN_OUT")" = "failure" ]
}

@test "#564: a legacy marker with no Reviewed head line is not credited from history" {
    marker_body=$'Fallback review — runtime: qwen, model: gpt-x (selected by: probe)\n\nNo issues found.'
    comments_json="$(jq -nc --arg m "$marker_body" '[
      {user:{login:"guilhermegor",type:"User"}, author_association:"OWNER",
       body:$m, created_at:"2026-09-27T12:38:40Z"}
    ]')"

    run_ladder_step "unrelated reply" "$comments_json"

    [ "$status" -eq 0 ]
    [ "$(jq -r '.conclusion' "$CHECK_RUN_OUT")" = "failure" ]
}

@test "#564: the triggering comment is credited only when it names the current head" {
    good=$'Fallback review — runtime: qwen, model: gpt-x (selected by: probe)\nReviewed head: '"$STUB_HEAD"$'\n\nOK.'
    stale=$'Fallback review — runtime: qwen, model: gpt-x (selected by: probe)\nReviewed head: 0123456789abcdef\n\nOK.'
    legacy=$'Fallback review — runtime: qwen, model: gpt-x (selected by: probe)\n\nOK.'
    oneline='Fallback review — runtime: qwen, model: gpt-x (selected by: probe)'

    run_ladder_step "$good" '[]'
    [ "$(jq -r '.conclusion' "$CHECK_RUN_OUT")" = "success" ]
    local body
    for body in "$stale" "$legacy" "$oneline"; do
        run_ladder_step "$body" '[]'
        [ "$(jq -r '.conclusion' "$CHECK_RUN_OUT")" = "failure" ]
    done
}
