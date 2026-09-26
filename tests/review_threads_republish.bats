#!/usr/bin/env bats
#
# Contract tests for .github/workflows/review_threads_republish.yml
# (dotfiles-dev#492). review_threads.yml never triggers on `pull_request` —
# see its own header — because a verdict computed at push time can go stale
# the instant a review lands (blueprintx#180). This sibling workflow is the
# push-triggered half: it may publish `failure` (or the non-review "not
# required" scope skip) but must NEVER publish a review-based `success`,
# because doing so at push time would recreate #180 in the opposite
# direction — a stale approval from an OLDER head surviving the very push
# that invalidated it. These tests pin that permissive half shut.
#
# Run locally: bats tests/          (install with: sudo apt-get install -y bats)

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    WORKFLOW="$REPO_ROOT/.github/workflows/review_threads_republish.yml"
    SCRIPT="$(mktemp)"
    python3 -c "
import yaml
with open('$WORKFLOW') as f:
    doc = yaml.safe_load(f)
steps = doc['jobs']['republish']['steps']
step = next(s for s in steps if s.get('name') == 'Republish onto the new head')
print(step['run'], end='')
" > "$SCRIPT"
}

teardown() {
    rm -f "$SCRIPT"
}

published_conclusion() {
    jq -r '.conclusion' < "$CHECK_RUN_OUT"
}

# run_step CHANGED_FILES
# Stubs `gh` for every call the script makes: pulls/<n> (head sha), pr view
# --json files (scope check), and check-runs (publish). A stub call to `pr
# view --json reviews` fails loudly — the script must never make it at all;
# see the "never consults review state" test below.
run_step() {
    local changed="$1"
    CHECK_RUN_OUT="$BATS_TEST_TMPDIR/check-run.json"
    : > "$CHECK_RUN_OUT"
    run env GH_TOKEN=x OWNER=o REPO=r PR_NUMBER=5 \
        REPO_ROOT="$REPO_ROOT" SCRIPT="$SCRIPT" CHECK_RUN_OUT="$CHECK_RUN_OUT" \
        CHANGED="$changed" \
        bash -c '
            cd "$REPO_ROOT" || exit 1
            gh() {
                case "$*" in
                    *check-runs*)       cat > "$CHECK_RUN_OUT" ;;
                    *"/pulls/"*)        echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ;;
                    *"--json files"*)   printf "%s\n" "$CHANGED" ;;
                    *"--json reviews"*) echo "SCRIPT-MUST-NOT-QUERY-REVIEWS" >&2; return 1 ;;
                    *) return 1 ;;
                esac
            }
            export -f gh
            bash "$SCRIPT"
        '
}

# --- the permissive half the issue asks to pin shut --------------------------

@test "in-scope push publishes failure, never success" {
    run_step "ai_clients/claude/hooks/lib/foo.sh"
    [ "$status" -eq 0 ]
    [ "$(published_conclusion)" = "failure" ]
    [[ "$output" == *"no reviewer has reported"* ]]
}

@test "the script never consults review state at all — a push cannot inherit a stale pass" {
    run grep -Ec 'json reviews|REVIEW_COUNT|reviewer_reported' "$SCRIPT"
    [ "$output" -eq 0 ]
}

# --- scope parity with review_threads.yml's own selective policy (#157) -----

@test "out-of-scope push publishes the non-review 'not required' success" {
    run_step "README.md"
    [ "$status" -eq 0 ]
    [ "$(published_conclusion)" = "success" ]
    [[ "$output" == *"gate not required"* ]]
}

@test "settings.json anywhere in the tree is still in-scope" {
    run_step "some/nested/settings.json"
    [ "$status" -eq 0 ]
    [ "$(published_conclusion)" = "failure" ]
}

# --- the verdict must land where branch protection can see it --------------

@test "the published check-run targets the PR head and the shared check name" {
    run_step "ai_clients/claude/hooks/lib/foo.sh"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.head_sha' < "$CHECK_RUN_OUT")" = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ]
    [ "$(jq -r '.name' < "$CHECK_RUN_OUT")" = "Review threads answered" ]
}

@test "job name matches the required check context exactly" {
    run python3 -c "
import yaml
d = yaml.safe_load(open('$WORKFLOW'))
print(d['jobs']['republish']['name'])
"
    [ "$status" -eq 0 ]
    [ "$output" = "Review threads answered" ]
}

# --- structural: this is the push-triggered half, and only that ------------

@test "trigger is pull_request/synchronize only — no review or comment events" {
    run python3 -c "
import yaml
d = yaml.safe_load(open('$WORKFLOW'))
on = d.get(True) or d.get('on') or {}
print(sorted(on.keys()))
print(on.get('pull_request', {}).get('types'))
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"['pull_request']"* ]]
    [[ "$output" == *"['synchronize']"* ]]
}

@test "job may write checks — without it every publish 403s" {
    run python3 -c "
import yaml
d = yaml.safe_load(open('$WORKFLOW'))
print((d.get('permissions') or {}).get('checks',''))
"
    [ "$status" -eq 0 ]
    [ "$output" = "write" ]
}
