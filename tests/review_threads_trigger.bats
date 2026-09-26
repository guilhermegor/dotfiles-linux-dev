#!/usr/bin/env bats
#
# Contract tests for .github/workflows/review_threads.yml's "Check review-thread
# state" step (dotfiles-dev#431). CodeRabbit posts no pull_request_review and no
# pull_request_review_comment when it finds nothing, so those two triggers alone
# never fire for a clean review and the required check never posts (measured on
# #412: `pulls/412/reviews` length 0, mergeStateStatus BLOCKED forever). The fix
# adds an issue_comment trigger guarded to CodeRabbit's own completion marker,
# but the step itself is the real unit under test here, not the `on:` block —
# actionlint/yamllint already prove the YAML parses; this proves the step's
# bash decides correctly for every event shape it can now receive.
#
# The step's script lives inline in the workflow (`run: |`), not in a sourced
# lib, per dotfiles-dev#431's file scope (workflow + test only — the shared
# ai_clients/claude/hooks/lib/review_thread_gate.sh gate stays untouched). It is
# extracted here with PyYAML instead of parsed with a fragile sed/awk slice, so
# a reformat of the surrounding YAML can't silently desync the test from the
# step it's meant to cover.
#
# dotfiles-dev#490: gate_pr_thread_state now retries until the GraphQL body carries a non-null
# `comments` key (the COMMENT-channel read added for #490), fail-closed on an incomplete page.
# Every THREADS_JSON fixture below must include `"comments":{"totalCount":0,"nodes":[]}` (or a
# populated one) or the gate exhausts its 3 retries and reports GATE_STATUS=unreadable instead of
# clean/problems -- the exact fixture-format break this file hit when #490 landed.
#
# Run locally: bats tests/          (install with: sudo apt-get install -y bats)

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    WORKFLOW="$REPO_ROOT/.github/workflows/review_threads.yml"
    TRIGGER_WORKFLOW="$REPO_ROOT/.github/workflows/coderabbit_trigger.yml"
    SCRIPT="$(mktemp)"
    python3 -c "
import yaml
with open('$WORKFLOW') as f:
    doc = yaml.safe_load(f)
steps = doc['jobs']['gate']['steps']
step = next(s for s in steps if s.get('name') == 'Check review-thread state')
print(step['run'], end='')
" > "$SCRIPT"
}

teardown() {
    rm -f "$SCRIPT"
}

# run_step EVENT_NAME COMMENT_AUTHOR COMMENT_BODY REVIEW_COUNT THREADS_JSON
# Stubs `gh` for both calls the step makes (`pr view --json files`,
# `pr view --json reviews`) plus the GraphQL call review_thread_gate.sh makes,
# then runs the extracted script from the repo root so its relative `source`
# resolves.
# The step publishes its verdict as a check-run POST instead of encoding it in its own exit
# status (dotfiles-dev#481) — Actions attaches THIS job's check-run to the default branch for
# an issue_comment event, so the exit status never reaches the PR. The stub therefore captures
# the POSTed body, and the assertions below read the published `conclusion`. Exit status alone
# would now pass for both verdicts, which is exactly the false pass these tests exist to catch.
published_conclusion() {
    jq -r '.conclusion' < "$CHECK_RUN_OUT"
}

run_step() {
    local event="$1" author="$2" body="$3" review_count="$4" threads_json="$5"
    local association="${6:-}"
    CHECK_RUN_OUT="$BATS_TEST_TMPDIR/check-run.json"
    : > "$CHECK_RUN_OUT"
    HISTORY_COMMENTS="${HISTORY_COMMENTS:-[]}"
    run env \
        GH_TOKEN=x OWNER=o REPO=r PR_NUMBER=5 \
        EVENT_NAME="$event" COMMENT_AUTHOR="$author" COMMENT_BODY="$body" \
        COMMENT_AUTHOR_ASSOCIATION="$association" \
        REVIEW_COUNT="$review_count" THREADS_JSON="$threads_json" \
        REPO_ROOT="$REPO_ROOT" SCRIPT="$SCRIPT" CHECK_RUN_OUT="$CHECK_RUN_OUT" \
        HISTORY_COMMENTS="$HISTORY_COMMENTS" NO_CHECK_SUITES="${NO_CHECK_SUITES:-}" \
        bash -c '
            cd "$REPO_ROOT" || exit 1
            gh() {
                case "$*" in
                    *check-runs*)       cat > "$CHECK_RUN_OUT" ;;
                    *"/pulls/"*)        echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ;;
                    *"--json files"*)    echo "ai_clients/claude/hooks/lib/foo.sh" ;;
                    *"--json reviews"*)  printf "%s\n" "$REVIEW_COUNT" ;;
                    *check-suites*)      [ -n "${NO_CHECK_SUITES:-}" ] || printf "2026-01-01T00:00:00Z\n" ;;
                    *issues/*/comments*) printf "%s" "${HISTORY_COMMENTS:-[]}" ;;
                    *"--json commits"*)  printf "2026-01-01T00:00:00Z\n" ;;
                    "api graphql"*)      printf "%s" "$THREADS_JSON" ;;
                    *) return 1 ;;
                esac
            }
            export -f gh
            bash "$SCRIPT"
        '
}

# --- the currently-unrepresented case (dotfiles-dev#431's own test ask) -----
# zero submitted reviews, zero review comments, and this run was NOT fired by
# CodeRabbit's completion marker: must reach a DECIDED (failing) state, never
# an absent one — the gate step must itself exit non-zero with a diagnostic.

@test "zero reviews, zero comments, non-marker trigger: fails decided, not absent" {
    run_step "pull_request_review" "" "" 0 '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":0,"nodes":[]},"comments":{"totalCount":0,"nodes":[]},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"totalCount":0,"nodes":[]}}}}]}}}}}'
    [ "$status" -eq 0 ]
    [ "$(published_conclusion)" = "failure" ]
    [[ "$output" == *"no reviewer has reported"* ]]
}

# --- blueprintx#213: a rate-limit refusal must not count as a review --------

@test "issue_comment rate-limit refusal: still fails, never a false pass" {
    run_step "issue_comment" "coderabbitai[bot]" \
        "your next included review will be available in 34 minutes" \
        0 '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":0,"nodes":[]},"comments":{"totalCount":0,"nodes":[]},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"totalCount":0,"nodes":[]}}}}]}}}}}'
    [ "$status" -eq 0 ]
    [ "$(published_conclusion)" = "failure" ]
    [[ "$output" == *"no reviewer has reported"* ]]
}

# --- blueprintx#213: a random human comment must not count as a review ------

@test "issue_comment from a human, unrelated text: still fails" {
    run_step "issue_comment" "guilhermegor" "LGTM, nice work" \
        0 '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":0,"nodes":[]},"comments":{"totalCount":0,"nodes":[]},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"totalCount":0,"nodes":[]}}}}]}}}}}'
    [ "$status" -eq 0 ]
    [ "$(published_conclusion)" = "failure" ]
    [[ "$output" == *"no reviewer has reported"* ]]
}

# --- the bug's own shape: #412 — CodeRabbit reviewed, found nothing ---------
# reviews API length 0 (no formal review object), zero threads, but the
# triggering comment IS CodeRabbit's completion marker: must reach a DECIDED
# (passing) state now, where before #431 the workflow never ran at all.

@test "issue_comment with CodeRabbit's completion marker: clean review passes" {
    run_step "issue_comment" "coderabbitai[bot]" \
        "✅ Action performed — Full review finished." \
        0 '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":0,"nodes":[]},"comments":{"totalCount":0,"nodes":[]},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"totalCount":0,"nodes":[]}}}}]}}}}}'
    [ "$status" -eq 0 ]
    [ "$(published_conclusion)" = "success" ]
    [[ "$output" != *"no reviewer has reported"* ]]
}

# --- the marker must not paper over a real open thread -----------------------
# Guards against a version of the fix that treats "CodeRabbit commented" as
# "everything is fine" instead of "a reviewer has reported, now check threads".

@test "completion marker present but a thread is still unanswered: fails" {
    run_step "issue_comment" "coderabbitai[bot]" \
        "✅ Action performed — Full review finished." \
        0 '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"nodes":[{"isResolved":false,"path":"a.sh","comments":{"totalCount":0,"nodes":[]}}]},"comments":{"totalCount":0,"nodes":[]},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"totalCount":0,"nodes":[]}}}}]}}}}}'
    [ "$status" -eq 0 ]
    [ "$(published_conclusion)" = "failure" ]
    [[ "$output" == *"review gate status=problems"* ]]
}

# --- an ordinary review still works unchanged --------------------------------

@test "a real submitted review (review_count > 0): proceeds past the reported check" {
    run_step "pull_request_review" "" "" 1 '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":0,"nodes":[]},"comments":{"totalCount":0,"nodes":[]},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"totalCount":0,"nodes":[]}}}}]}}}}}'
    [ "$status" -eq 0 ]
    [ "$(published_conclusion)" = "success" ]
    [[ "$output" != *"no reviewer has reported"* ]]
}

# --- #481: the verdict must land on the PR HEAD, not on whatever SHA fired the run ----------

@test "the published check-run targets the PR head commit" {
    run_step "issue_comment" "coderabbitai[bot]" \
        "✅ Action performed — Full review finished." \
        0 '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":0,"nodes":[]},"comments":{"totalCount":0,"nodes":[]},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"totalCount":0,"nodes":[]}}}}]}}}}}'
    [ "$status" -eq 0 ]
    [ "$(jq -r '.head_sha' < "$CHECK_RUN_OUT")" = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ]
    [ "$(jq -r '.name' < "$CHECK_RUN_OUT")" = "Review threads answered" ]
}

@test "a PR outside the selective scope still publishes, or it stays blocked forever" {
    CHECK_RUN_OUT="$BATS_TEST_TMPDIR/check-run.json"
    : > "$CHECK_RUN_OUT"
    run env GH_TOKEN=x OWNER=o REPO=r PR_NUMBER=5 EVENT_NAME=issue_comment \
        COMMENT_AUTHOR=x COMMENT_BODY=x REPO_ROOT="$REPO_ROOT" SCRIPT="$SCRIPT" \
        CHECK_RUN_OUT="$CHECK_RUN_OUT" \
        bash -c '
            cd "$REPO_ROOT" || exit 1
            gh() {
                case "$*" in
                    *check-runs*)     cat > "$CHECK_RUN_OUT" ;;
                    *"/pulls/"*)      echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ;;
                    *"--json files"*) echo "README.md" ;;
                    *) return 1 ;;
                esac
            }
            export -f gh
            bash "$SCRIPT"
        '
    [ "$status" -eq 0 ]
    [ "$(jq -r '.conclusion' < "$CHECK_RUN_OUT")" = "success" ]
    [[ "$output" == *"gate not required"* ]]
}


# --- dotfiles-dev#451: the reviewer ladder's fallback review is a report ----
# The ladder (#444/#446/#449) posts its fallback review as an issue_comment
# from the operator's own account — never a review object — so review_count
# stays 0 and only the marker + author_association can tell "reviewed via
# the ladder" apart from "nobody has reported yet".

LADDER_BODY="Fallback review — runtime: codex, model: codex-auto-review (selected by: review-specialized-slug)

No findings."
ZERO_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":0,"nodes":[]},"comments":{"totalCount":0,"nodes":[]},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"totalCount":0,"nodes":[]}}}}]}}}}}'
ONE_OPEN_THREAD='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"nodes":[{"isResolved":false,"path":"a.sh","comments":{"totalCount":0,"nodes":[]}}]},"comments":{"totalCount":0,"nodes":[]},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"totalCount":0,"nodes":[]}}}}]}}}}}'

# --- #482 review: a clean verdict must survive a later unrelated comment -------------------
# A clean CodeRabbit review submits no review object, so review_count stays 0 and the only
# evidence is its completion COMMENT. Reading that from this run's trigger alone meant any
# later comment republished `failure` over the passing verdict already on the head — latent
# while the check landed on master, live the moment publishing became authoritative.

@test "a later human comment does not overwrite an earlier clean review" {
    export HISTORY_COMMENTS='[{"user":{"login":"coderabbitai[bot]","type":"Bot"},"created_at":"2026-06-01T00:00:00Z","body":"✅ Action performed\n\nFull review finished."}]'
    run_step "issue_comment" "guilhermegor" "thanks, merging tomorrow" \
        0 '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":0,"nodes":[]},"comments":{"totalCount":0,"nodes":[]},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"totalCount":0,"nodes":[]}}}}]}}}}}'
    [ "$status" -eq 0 ]
    [ "$(published_conclusion)" = "success" ]
}

@test "a completion marker OLDER than the head push does not count" {
    # The stub reports the head pushed at 2026-01-01; this marker predates it, so the review
    # it records was of different code. A push must invalidate a clean verdict.
    export HISTORY_COMMENTS='[{"user":{"login":"coderabbitai[bot]","type":"Bot"},"created_at":"2025-12-01T00:00:00Z","body":"Full review finished."}]'
    run_step "issue_comment" "guilhermegor" "ping" \
        0 '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":0,"nodes":[]},"comments":{"totalCount":0,"nodes":[]},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"totalCount":0,"nodes":[]}}}}]}}}}}'
    [ "$status" -eq 0 ]
    [ "$(published_conclusion)" = "failure" ]
    [[ "$output" == *"no reviewer has reported"* ]]
}

@test "ladder marker from OWNER, zero reviews, zero threads: passes" {
    run_step "issue_comment" "guilhermegor" "$LADDER_BODY" 0 "$ZERO_THREADS" "OWNER"
    [ "$status" -eq 0 ]
    [ "$(published_conclusion)" = "success" ]
    [[ "$output" != *"no reviewer has reported"* ]]
}

@test "ladder marker from author_association=NONE: fails" {
    run_step "issue_comment" "guilhermegor" "$LADDER_BODY" 0 "$ZERO_THREADS" "NONE"
    [ "$status" -eq 0 ]
    [ "$(published_conclusion)" = "failure" ]
    [[ "$output" == *"no reviewer has reported"* ]]
}

@test "ladder marker from author_association=CONTRIBUTOR: fails" {
    run_step "issue_comment" "guilhermegor" "$LADDER_BODY" 0 "$ZERO_THREADS" "CONTRIBUTOR"
    [ "$status" -eq 0 ]
    [ "$(published_conclusion)" = "failure" ]
    [[ "$output" == *"no reviewer has reported"* ]]
}

@test "ladder marker quoted on a non-first line: fails" {
    local quoted="Re-posting for visibility:

$LADDER_BODY"
    run_step "issue_comment" "guilhermegor" "$quoted" 0 "$ZERO_THREADS" "OWNER"
    [ "$status" -eq 0 ]
    [ "$(published_conclusion)" = "failure" ]
    [[ "$output" == *"no reviewer has reported"* ]]
}

@test "ladder marker present but a thread is still open: fails" {
    run_step "issue_comment" "guilhermegor" "$LADDER_BODY" 0 "$ONE_OPEN_THREAD" "OWNER"
    [ "$status" -eq 0 ]
    [ "$(published_conclusion)" = "failure" ]
    [[ "$output" == *"review gate status=problems"* ]]
}

# --- #455 review: the verdict must not depend on how long the review was ------------------
# `printf "%s\n" "$COMMENT_BODY" | head -n1` under `set -euo pipefail` takes SIGPIPE once the
# body no longer fits the pipe buffer: head exits after line 1, printf dies, the assignment
# returns 141 and the step is killed BEFORE the marker check runs. Measured on this machine:
# rc=0 at 2 KB, rc=141 from ~50 KB up — and GitHub accepts comment bodies to 65536 chars, so a
# verbose fallback review reaches it. Parameter expansion has no pipe and no length ceiling.

@test "ladder marker is honoured in a 60 KB body (no broken-pipe kill)" {
    long_body="Fallback review — runtime: codex, model: codex-auto-review (selected by: review-specialized-slug)"$'\n'"$(printf '%*s' 60000 '')"
    run_step "issue_comment" "guilhermegor" "$long_body" \
        0 '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":0,"nodes":[]},"comments":{"totalCount":0,"nodes":[]},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"totalCount":0,"nodes":[]}}}}]}}}}}' \
        "OWNER"
    [ "$status" -eq 0 ]
    [ "$(published_conclusion)" = "success" ]
    [[ "$output" != *"no reviewer has reported"* ]]
}

# --- #455 local review (coderabbit CLI): the marker must not be forgeable ------------------
# The old filter was `select(.author.login | ascii_downcase | test("coderabbit"))` over the
# GraphQL comment shape, which reports login "coderabbitai" and carries NO account type at
# all. Any login CONTAINING "coderabbit" satisfied it, and a human could not be told from a
# Bot — a forgeable reviewer report on a deny-by-default gate (CWE-345). REST carries the
# exact login and the type; both are now required.

@test "a look-alike login cannot forge the completion marker" {
    export HISTORY_COMMENTS='[{"user":{"login":"coderabbitai-fan","type":"User"},"created_at":"2026-06-01T00:00:00Z","body":"Full review finished."}]'
    run_step "issue_comment" "guilhermegor" "ping" \
        0 "$ZERO_THREADS"
    [ "$status" -eq 0 ]
    [ "$(published_conclusion)" = "failure" ]
    [[ "$output" == *"no reviewer has reported"* ]]
}

@test "a human posting the exact marker text cannot forge it either" {
    export HISTORY_COMMENTS='[{"user":{"login":"guilhermegor","type":"User"},"created_at":"2026-06-01T00:00:00Z","body":"Full review finished."}]'
    run_step "issue_comment" "guilhermegor" "ping" \
        0 "$ZERO_THREADS"
    [ "$status" -eq 0 ]
    [ "$(published_conclusion)" = "failure" ]
}

# --- dotfiles-dev#502: the gate's scope filter must never diverge from the ---
# --- trigger's, or a PR becomes REQUIRED to pass a check the trigger never --
# --- asks a reviewer to produce (measured on #493: asks=0 for 8h05m). ------
#
# Rather than duplicate the two hand-kept path lists a third time here (a
# third copy that could itself drift), both sides are read from their own
# workflow file: the trigger's real `on.pull_request.paths` glob list, and
# the gate's real runtime regex, pulled out of the extracted step script
# with a plain grep (no re-parsing of the shell). A shared set of candidate
# paths is then run through both, and any path where they disagree fails
# the test.

trigger_would_fire() {
    local path="$1"
    python3 -c "
import fnmatch, sys, yaml
with open('$TRIGGER_WORKFLOW') as f:
    doc = yaml.safe_load(f)
# PyYAML 1.1 parses the bare 'on:' key as the boolean True, not the string
# 'on' — a well-known GitHub Actions/PyYAML gotcha, not a fixture bug.
trigger_block = doc.get('on', doc.get(True))
patterns = trigger_block['pull_request']['paths']
path = '$path'
hit = any(fnmatch.fnmatchcase(path, p.replace('**', '*')) for p in patterns)
sys.exit(0 if hit else 1)
"
}

gate_requires() {
    local path="$1"
    local gate_regex
    gate_regex="$(grep -oE "grep -qE '[^']+'" "$SCRIPT" | head -n1 | sed -E "s/^grep -qE '//; s/'\$//")"
    printf '%s\n' "$path" | grep -qE "$gate_regex"
}

@test "the gate's scope regex agrees with the trigger's paths: filter on every candidate path" {
    # One entry per interesting case: inside/outside each declared pattern,
    # plus the exact shape of the bug (a same-named file OUTSIDE the scoped
    # directory, which must select neither filter after the #502 fix).
    candidates=(
        "ai_clients/claude/hooks/foo.sh"
        "ai_clients/claude/hooks/lib/bar.sh"
        "ai_clients/claude/settings.json"
        ".vscode/settings.json"
        "some/nested/dir/settings.json"
        "settings.json"
        "README.md"
        "ai_clients/claude/hooks_lookalike/settings.json"
    )
    for path in "${candidates[@]}"; do
        if trigger_would_fire "$path"; then trig=1; else trig=0; fi
        if gate_requires "$path"; then gate=1; else gate=0; fi
        [ "$trig" -eq "$gate" ] || {
            echo "divergence on '$path': trigger=$trig gate=$gate"
            return 1
        }
    done
}

@test "a PR touching only .vscode/settings.json is no longer required (the #502 bug)" {
    CHECK_RUN_OUT="$BATS_TEST_TMPDIR/check-run.json"
    : > "$CHECK_RUN_OUT"
    run env GH_TOKEN=x OWNER=o REPO=r PR_NUMBER=5 EVENT_NAME=issue_comment \
        COMMENT_AUTHOR=x COMMENT_BODY=x REPO_ROOT="$REPO_ROOT" SCRIPT="$SCRIPT" \
        CHECK_RUN_OUT="$CHECK_RUN_OUT" \
        bash -c '
            cd "$REPO_ROOT" || exit 1
            gh() {
                case "$*" in
                    *check-runs*)     cat > "$CHECK_RUN_OUT" ;;
                    *"/pulls/"*)      echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ;;
                    *"--json files"*) printf ".vscode/extensions.txt\n.vscode/settings.json\ntests/x.bats\n" ;;
                    *) return 1 ;;
                esac
            }
            export -f gh
            bash "$SCRIPT"
        '
    [ "$status" -eq 0 ]
    [ "$(jq -r '.conclusion' < "$CHECK_RUN_OUT")" = "success" ]
    [[ "$output" == *"gate not required"* ]]
}

@test "no check suite on the head means no trusted clock, so no marker credit" {
    # CWE-367: committedDate is author-controlled, so the head's arrival time comes from the
    # earliest check-suite instead. With none, the gate must fail closed rather than fall
    # back to the forgeable timestamp.
    export HISTORY_COMMENTS='[{"user":{"login":"coderabbitai[bot]","type":"Bot"},"created_at":"2026-06-01T00:00:00Z","body":"Full review finished."}]'
    export NO_CHECK_SUITES=1
    run_step "issue_comment" "guilhermegor" "ping" \
        0 "$ZERO_THREADS"
    [ "$status" -eq 0 ]
    [ "$(published_conclusion)" = "failure" ]
}
