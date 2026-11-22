#!/usr/bin/env bats
# merge_green_pr.sh (dotfiles-linux-dev#868): REST-only squash merge of green PRs.
# `gh` and `git` are stubbed on PATH; no network. Per-PR behaviour is driven by env:
# STATE_<n>, DRAFT_<n>, CHECK_<n>, AUTHOR_<n>, FILES_<n>, CHANGED_<n>, MERGED_<n>;
# global: ME, USER_FAIL, FILES_FAIL, PROT_FAIL, PROT_404, PUT_FAIL, STATUS_<n>, RULE_CTX,
# FILES_FLAKY (first /files call prints a row, then fails with HTTP 502).
# Provenance (#1064): check-runs carry a check_suite id (SUITE, default 1); EXTRA_CHECKS adds
# raw check-run rows; RUN_PATH_<suite> is that suite's workflow path (default ci.yml,
# "none" = unresolvable); REFS_<suite> = its referenced (reusable) workflows; JOBS_<suite> =
# the run's job names (default build + the review gate); WF_CONTENT = a changed workflow's
# content at the head (default: safe permissions); RUN_FAIL makes the actions/runs read fail.
# Dependabot provenance (#1076): HEAD_REF_<n> (default dependabot/pip/x), HEAD_REPO_<n>
# (default acme/widgets), COMMITS_<n> = raw "author<TAB>committer<TAB>verified" rows (default
# one verified dependabot[bot] commit via web-flow), COMMITS_FAIL makes the commits read fail.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/merge_green_pr.sh"
    BIN="$BATS_TEST_TMPDIR/bin"
    GH_LOG="$BATS_TEST_TMPDIR/gh.log"
    mkdir -p "$BIN"
    : > "$GH_LOG"
    printf '#!/bin/bash\necho "git@github.com:acme/widgets.git"\n' > "$BIN/git"
    cat > "$BIN/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "$GH_LOG"
args="$*"
pr_of() { local n="${args#*pulls/}"; echo "${n%%[/ ?]*}"; }
if [[ "$args" == "api user"* ]]; then
    [ -n "${USER_FAIL:-}" ] && exit 1
    echo "${ME:-acme}"; exit 0
fi
if [[ "$args" == *"-X PUT"* ]]; then
    [ -n "${PUT_FAIL:-}" ] && { echo "gh: timeout" >&2; exit 1; }
    exit 0
fi
if [[ "$args" == *"--jq .merged"* ]]; then
    m="MERGED_$(pr_of)"; echo "${!m:-false}"; exit 0
fi
if [[ "$args" == *"/files"* ]]; then
    [ -n "${FILES_FAIL:-}" ] && exit 1
    n="$(pr_of)"
    if [ -n "${FILES_FLAKY:-}" ] && [ ! -e "$BATS_TEST_TMPDIR/flaked" ]; then
        touch "$BATS_TEST_TMPDIR/flaked"
        printf 'src/app.sh\t\n'; echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1
    fi
    f="FILES_$n"; printf '%s\n' "${!f:-src/app.sh$(printf '\t')}"; exit 0
fi
if [[ "$args" == *"/protection"* ]]; then
    [ -n "${PROT_FAIL:-}" ] && { echo "gh: Forbidden (HTTP 403)" >&2; exit 1; }
    [ -n "${PROT_404:-}" ] && { echo "gh: Branch not protected (HTTP 404)" >&2; exit 1; }
    if [ -n "${PROT_JSON:-}" ]; then
        # Run the script's own --jq filter for real, so a broken filter fails here (#898).
        prev=""; for a in "$@"; do [ "$prev" = --jq ] && f="$a"; prev="$a"; done
        printf '%s' "$PROT_JSON" | jq -r "$f"; exit
    fi
    printf 'build\t%s\n' "${PROT_APP:--1}"; exit 0
fi
if [[ "$args" == *"/rules/branches/"* ]]; then
    [ -n "${RULE_CTX:-}" ] && echo "$RULE_CTX"
    exit 0
fi
if [[ "$args" == *"actions/runs?check_suite_id="* ]]; then
    [ -n "${RUN_FAIL:-}" ] && exit 1
    id="${args#*check_suite_id=}"; id="${id%% *}"
    p="RUN_PATH_$id"; p="${!p:-.github/workflows/ci.yml}"
    r="REFS_$id"
    [ "$p" = none ] || printf '%s\t%s\t%s\n' "$id" "$p" "${!r:-}"
    exit 0
fi
if [[ "$args" == *"actions/runs/"*"/jobs"* ]]; then
    id="${args#*actions/runs/}"; id="${id%%/*}"
    j="JOBS_$id"; printf '%b\n' "${!j:-build\nReview threads answered}"
    exit 0
fi
if [[ "$args" == *"contents/.github/workflows?ref=master"* ]]; then
    [ "${GATE_WF:-}" = fail ] && { echo "gh: Server Error (HTTP 500)" >&2; exit 1; }
    [ "${GATE_WF:-}" = none ] && { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    [ "${GATE_WF:-}" = other ] && { echo ".github/workflows/parity.yml"; exit 0; }
    echo ".github/workflows/review_gate.yml"; exit 0
fi
if [[ "$args" == *"/contents/"*"ref=master"* ]]; then
    if [ "${GATE_WF:-}" = other ]; then printf 'name: README parity\n' | base64; exit 0; fi
    printf 'name: Review threads answered\n' | base64; exit 0
fi
if [[ "$args" == *"/contents/"* ]]; then
    printf '%b' "${WF_CONTENT:-permissions:\n  contents: read\n}" | base64
    exit 0
fi
if [[ "$args" == *"/check-runs"* ]]; then
    n="${args#*commits/sha}"; n="${n%%/*}"
    c="CHECK_$n"; c="${!c:-success}"
    [ "$c" = missing ] && exit 0
    printf 'build\t%s\t::check::\t%s\t%s\n' "$c" "${APP_ID:-15368}" "${SUITE:-1}"
    [ -n "${GATE_WF:-}" ] || printf 'Review threads answered\t%s\t::check::\t%s\t%s\n' "$c" "${APP_ID:-15368}" "${SUITE:-1}"
    [ -n "${EXTRA_CHECKS:-}" ] && printf '%s\n' "$EXTRA_CHECKS"
    exit 0
fi
if [[ "$args" == *"/status"* ]]; then
    n="${args#*commits/sha}"; n="${n%%/*}"
    s="STATUS_$n"; [ -n "${!s:-}" ] && printf '%s\n' "${!s}"
    exit 0
fi
if [[ "$args" == *"/pulls/"*"/commits"* ]]; then
    [ -n "${COMMITS_FAIL:-}" ] && exit 1
    c="COMMITS_$(pr_of)"
    printf '%b\n' "${!c:-dependabot[bot]\tweb-flow\ttrue}"; exit 0
fi
if [[ "$args" == *"/pulls/"* ]]; then
    n="$(pr_of)"
    s="STATE_$n"; s="${!s:-clean}"
    a="AUTHOR_$n"; a="${!a:-acme}"
    d="DRAFT_$n"; d="${!d:-false}"
    f="FILES_$n"; cf="$(printf '%s\n' "${!f:-x}" | grep -c .)"
    c="CHANGED_$n"; c="${!c:-$cf}"
    hr="HEAD_REF_$n"; hp="HEAD_REPO_$n"
    printf 'sha%s\t%s\t%s\tmaster\t%s\t%s\t%s\t%s\tacme/widgets\n' "$n" "$s" "$d" "$a" "$c" \
        "${!hr:-dependabot/pip/x}" "${!hp:-acme/widgets}"
    exit 0
fi
exit 1
STUB
    chmod +x "$BIN/git" "$BIN/gh"
    export GH_LOG BATS_TEST_TMPDIR MERGE_GREEN_RETRY_SLEEP=0
    export PATH="$BIN:$PATH"
}

refute_log() {
    run grep -q -- "$1" "$GH_LOG"
    [ "$status" -ne 0 ]
}

@test "refuses a non-integer argument and any flag" {
    for bad in abc 0 -5 --admin 1.5 "" "7;ls"; do
        run bash "$SCRIPT" "$bad"
        [ "$status" -eq 2 ]
    done
    run bash "$SCRIPT" 7 --admin
    [ "$status" -eq 2 ]
    run bash "$SCRIPT"
    [ "$status" -eq 2 ]
    refute_log "PUT"
}

@test "merges a green clean PR with squash and the pinned head sha" {
    run bash "$SCRIPT" 7
    [ "$status" -eq 0 ]
    [[ "$output" == *"#7 MERGED"* ]]
    grep -q -- "-X PUT repos/acme/widgets/pulls/7/merge -f merge_method=squash -f sha=sha7" "$GH_LOG"
}

@test "refuses a red required check" {
    CHECK_7=failure run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSED"* ]]
    refute_log "PUT"
}

@test "a skipped review gate is not green (the gate is strict success)" {
    CHECK_7=skipped run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"Review threads answered"* ]]
    refute_log "PUT"
}

@test "a non-gate status from another creator counts" {
    STATUS_7=$'ci/extra\tsuccess\tci-bot' RULE_CTX="ci/extra" run bash "$SCRIPT" 7
    [ "$status" -eq 0 ]
    [[ "$output" == *"#7 MERGED"* ]]
}

@test "a non-gate status created by the authenticated user is refused (case-insensitive)" {
    STATUS_7=$'ci/extra\tsuccess\tACME' RULE_CTX="ci/extra" run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"ci/extra"* ]]
    refute_log "PUT"
}

@test "a forged review-gate status by the user cannot replace the check-run" {
    CHECK_7=missing STATUS_7=$'Review threads answered\tsuccess\tacme' run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"Review threads answered"* ]]
    refute_log "PUT"
}

@test "a review-gate status from any creator is never enough" {
    CHECK_7=missing STATUS_7=$'Review threads answered\tsuccess\tci-bot' run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    refute_log "PUT"
}

@test "a required context from rulesets that is not green is refused" {
    RULE_CTX="ci/missing" run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"ci/missing"* ]]
    refute_log "PUT"
}

@test "a required check pinned to an app is refused when the check-run is from another app" {
    PROT_APP=999 run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"[build]"* ]]
    refute_log "PUT"
}

@test "a required check pinned to an app passes when the check-run is from that app" {
    PROT_APP=15368 run bash "$SCRIPT" 7
    [ "$status" -eq 0 ]
    [[ "$output" == *"#7 MERGED"* ]]
}

@test "a ruleset integration_id is compared too" {
    RULE_CTX=$'ci/extra\t999' run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"ci/extra"* ]]
    refute_log "PUT"
}

@test "a commit status never satisfies an app-pinned requirement" {
    STATUS_7=$'ci/extra\tsuccess\tci-bot\t-' RULE_CTX=$'ci/extra\t15368' run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    refute_log "PUT"
}

@test "an unpinned required check (-1 or no app_id) matches by name from any app" {
    APP_ID=424242 PROT_APP=-1 RULE_CTX=$'build\t-1' run bash "$SCRIPT" 7
    [ "$status" -eq 0 ]
    [[ "$output" == *"#7 MERGED"* ]]
}

@test "protection listing contexts AND checks (GitHub's real shape) parses (#898)" {
    PROT_JSON='{"required_status_checks":{"contexts":["build","Review threads answered"],"checks":[{"context":"build","app_id":15368},{"context":"Review threads answered","app_id":null}]}}' \
        run bash "$SCRIPT" 7
    [ "$status" -eq 0 ]
    [[ "$output" == *"#7 MERGED"* ]]
}

@test "real protection filter still pins app_id from checks[] (#898)" {
    APP_ID=424242 PROT_JSON='{"required_status_checks":{"contexts":["build"],"checks":[{"context":"build","app_id":15368}]}}' \
        run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"required check not green"* ]]
    refute_log "PUT"
}

@test "empty contexts with checks[] still enforces the pin (old fail-open, #898)" {
    APP_ID=424242 PROT_JSON='{"required_status_checks":{"contexts":[],"checks":[{"context":"build","app_id":15368}]}}' \
        run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"required check not green"* ]]
    refute_log "PUT"
}

@test "legacy contexts with no checks key matches by name (#898)" {
    PROT_JSON='{"required_status_checks":{"contexts":["build"]}}' run bash "$SCRIPT" 7
    [ "$status" -eq 0 ]
    [[ "$output" == *"#7 MERGED"* ]]
}

@test "refuses a missing required check" {
    CHECK_7=missing run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"Review threads answered"* ]]
    refute_log "PUT"
}

@test "refuses a dirty PR" {
    STATE_7=dirty run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"not clean"* ]]
    refute_log "PUT"
}

@test "refuses a draft PR" {
    DRAFT_7=true run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"draft"* ]]
    refute_log "PUT"
}

@test "a permission error on protection is UNKNOWN" {
    PROT_FAIL=1 run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"UNKNOWN"* ]]
    refute_log "PUT"
}

@test "an unprotected branch (404) is an empty list, the review gate still applies" {
    PROT_404=1 run bash "$SCRIPT" 7
    [ "$status" -eq 0 ]
    [[ "$output" == *"#7 MERGED"* ]]
    PROT_404=1 CHECK_8=failure run bash "$SCRIPT" 8
    [ "$status" -ne 0 ]
}

@test "no gate workflow, no protection: all green check-runs merge (#1113)" {
    GATE_WF=other PROT_404=1 run bash "$SCRIPT" 7
    [ "$status" -eq 0 ]
    [[ "$output" == *"#7 MERGED"* ]]
}

@test "no gate workflow, no protection: a red check-run still refuses (#1113)" {
    GATE_WF=none PROT_404=1 CHECK_7=failure run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSED"* ]]
    refute_log "PUT"
}

@test "no gate workflow: protection contexts are still required (#1113)" {
    GATE_WF=other PROT_404=1 RULE_CTX=$'lint\t-1' run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"[lint]"* ]]
    refute_log "PUT"
}

@test "no gate workflow and no check-run at all is refused (#1113)" {
    GATE_WF=other PROT_404=1 CHECK_7=missing run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    refute_log "PUT"
}

@test "an unreadable workflow listing is UNKNOWN, not 'no gate' (#1113)" {
    GATE_WF=fail PROT_404=1 run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"UNKNOWN"* ]]
    refute_log "PUT"
}

@test "batch: one bad PR is refused, the others merge, exit non-zero" {
    STATE_8=dirty run bash "$SCRIPT" 7 8 9
    [ "$status" -ne 0 ]
    [[ "$output" == *"#7 MERGED"* ]]
    [[ "$output" == *"#8 REFUSED"* ]]
    [[ "$output" == *"#9 MERGED"* ]]
    refute_log "pulls/8/merge"
}

@test "refuses a PR touching .github/actions" {
    FILES_7=".github/actions/x/action.yml"$'\t' run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *".github/actions"* ]]
    refute_log "PUT"
}

@test "merges when an unrelated workflow is edited and required checks come from unchanged ones" {
    FILES_7=$'src/a.sh\t\n.github/workflows/other.yml\t' run bash "$SCRIPT" 7
    [ "$status" -eq 0 ]
    [[ "$output" == *"#7 MERGED"* ]]
}

@test "refuses when the workflow producing a required check is edited" {
    FILES_7=$'.github/workflows/ci.yml\t' run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"required check ["* ]]  # which name is checked first depends on the sort locale
    [[ "$output" == *".github/workflows/ci.yml"* ]]
    refute_log "PUT"
}

@test "refuses a new workflow posting a duplicate required check name" {
    FILES_7=$'.github/workflows/new.yml\t' EXTRA_CHECKS=$'build\tsuccess\t::check::\t15368\t2' \
        RUN_PATH_2=.github/workflows/new.yml run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"[build]"* ]]
    [[ "$output" == *".github/workflows/new.yml"* ]]
    refute_log "PUT"
}

@test "an unresolvable run path is UNKNOWN and fails closed" {
    FILES_7=$'.github/workflows/other.yml\t' RUN_PATH_1=none run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"UNKNOWN"* ]]
    refute_log "PUT"
}

@test "an actions/runs read failure is UNKNOWN and fails closed" {
    FILES_7=$'.github/workflows/other.yml\t' RUN_FAIL=1 run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"UNKNOWN"* ]]
    refute_log "PUT"
}

@test "refuses an unchanged caller of a changed reusable workflow" {
    FILES_7=$'.github/workflows/reusable.yml\t' REFS_1=".github/workflows/reusable.yml" run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *".github/workflows/reusable.yml"* ]]
    refute_log "PUT"
}

@test "refuses a changed workflow granting checks: write" {
    FILES_7=$'.github/workflows/other.yml\t' WF_CONTENT=$'permissions:\n  checks: write\n' run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"other.yml"* ]]
    refute_log "PUT"
}

@test "refuses a changed workflow with no permissions key" {
    FILES_7=$'.github/workflows/other.yml\t' WF_CONTENT=$'on: push\n' run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    refute_log "PUT"
}

@test "refuses checks: write hidden behind a YAML alias" {
    FILES_7=$'.github/workflows/other.yml\t' \
        WF_CONTENT=$'x: &p write\npermissions:\n  checks: *p\n' run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"other.yml"* ]]
    refute_log "PUT"
}

@test "refuses a job-level checks: write under safe top-level permissions" {
    FILES_7=$'.github/workflows/other.yml\t' \
        WF_CONTENT=$'permissions: read-all\njobs:\n  j:\n    permissions: {checks: write}\n' run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    refute_log "PUT"
}

@test "refuses permissions: write-all" {
    FILES_7=$'.github/workflows/other.yml\t' WF_CONTENT=$'permissions: write-all\n' run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    refute_log "PUT"
}

@test "accepts read-all and an empty-mapping permissions" {
    FILES_7=$'.github/workflows/other.yml\t' WF_CONTENT=$'permissions: read-all\n' run bash "$SCRIPT" 7
    [ "$status" -eq 0 ]
    FILES_8=$'.github/workflows/other.yml\t' WF_CONTENT=$'permissions: {}\njobs:\n  j:\n    runs-on: x\n' run bash "$SCRIPT" 8
    [ "$status" -eq 0 ]
}

@test "no usable YAML parser is UNKNOWN and fails closed" {
    mkdir -p "$BATS_TEST_TMPDIR/nopar"
    printf '#!/bin/bash\nexit 1\n' > "$BATS_TEST_TMPDIR/nopar/python3"
    cp "$BATS_TEST_TMPDIR/nopar/python3" "$BATS_TEST_TMPDIR/nopar/yq"
    chmod +x "$BATS_TEST_TMPDIR/nopar/python3" "$BATS_TEST_TMPDIR/nopar/yq"
    FILES_7=$'.github/workflows/other.yml\t' PATH="$BATS_TEST_TMPDIR/nopar:$PATH" run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"UNKNOWN"* ]]
    refute_log "PUT"
}

@test "refuses statuses: write, top-level and job-level, aliases included" {
    FILES_7=$'.github/workflows/other.yml\t' WF_CONTENT=$'permissions:\n  statuses: write\n' run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    FILES_8=$'.github/workflows/other.yml\t' \
        WF_CONTENT=$'permissions: read-all\njobs:\n  j:\n    permissions: {statuses: write}\n' run bash "$SCRIPT" 8
    [ "$status" -ne 0 ]
    FILES_9=$'.github/workflows/other.yml\t' \
        WF_CONTENT=$'x: &p write\npermissions:\n  statuses: *p\n' run bash "$SCRIPT" 9
    [ "$status" -ne 0 ]
    refute_log "PUT"
}

@test "a required context met by a commit status refuses when the PR changes a workflow" {
    FILES_7=$'.github/workflows/other.yml\t' STATUS_7=$'ci/extra\tsuccess\tci-bot\t-' RULE_CTX="ci/extra" run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"commit status"* ]]
    refute_log "PUT"
}

@test "a required commit status still merges when no workflow changes" {
    STATUS_7=$'ci/extra\tsuccess\tci-bot\t-' RULE_CTX="ci/extra" run bash "$SCRIPT" 7
    [ "$status" -eq 0 ]
}

@test "permissions are an allowlist: Write, WRITE and bogus values are refused" {
    FILES_7=$'.github/workflows/other.yml\t' WF_CONTENT=$'permissions:\n  checks: Write\n' run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    FILES_8=$'.github/workflows/other.yml\t' WF_CONTENT=$'permissions:\n  statuses: WRITE\n' run bash "$SCRIPT" 8
    [ "$status" -ne 0 ]
    FILES_9=$'.github/workflows/other.yml\t' WF_CONTENT=$'permissions:\n  checks: bogus\n' run bash "$SCRIPT" 9
    [ "$status" -ne 0 ]
    FILES_7=$'.github/workflows/other.yml\t' \
        WF_CONTENT=$'permissions: read-all\njobs:\n  j:\n    permissions: {checks: Write}\n' run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    refute_log "PUT"
}

@test "checks: none and read are accepted" {
    FILES_7=$'.github/workflows/other.yml\t' WF_CONTENT=$'permissions:\n  checks: none\n  contents: read\n' run bash "$SCRIPT" 7
    [ "$status" -eq 0 ]
    FILES_8=$'.github/workflows/other.yml\t' \
        WF_CONTENT=$'permissions: read-all\njobs:\n  j:\n    permissions: {checks: read, statuses: none}\n' run bash "$SCRIPT" 8
    [ "$status" -eq 0 ]
}

@test "refuses a required check-run with no matching job in its run" {
    FILES_7=$'.github/workflows/other.yml\t' JOBS_1="lint" run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"no backing job"* ]]
    refute_log "PUT"
}

@test "a required check-run from a non-Actions app refuses when the PR changes a workflow" {
    FILES_7=$'.github/workflows/other.yml\t' APP_ID=424242 run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"non-Actions check-run"* ]]
    refute_log "PUT"
}

@test "a non-Actions required check-run still merges when no workflow changes" {
    APP_ID=424242 run bash "$SCRIPT" 7
    [ "$status" -eq 0 ]
    refute_log "actions/runs"
}

@test "a changed workflow filename outside [A-Za-z0-9._/-] is refused before any contents read" {
    FILES_7=$'.github/workflows/x?ref=sha7&a=.yml\t' run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"outside [A-Za-z0-9._/-]"* ]]
    refute_log "/contents/.*ref=sha7"
    refute_log "PUT"
}

@test "refuses when the file list is shorter than changed_files" {
    CHANGED_7=3001 run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"file list incomplete"* ]]
    refute_log "PUT"
}

@test "refuses a rename out of .github/workflows" {
    FILES_7="docs/ci.yml"$'\t'".github/workflows/ci.yml" run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *".github/workflows/ci.yml"* ]]
    refute_log "PUT"
}

@test "files read failure is UNKNOWN and does not merge" {
    FILES_FAIL=1 run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"UNKNOWN"* ]]
    refute_log "PUT"
}

@test "a transient files error is retried without duplicating partial rows" {
    FILES_FLAKY=1 run bash "$SCRIPT" 7
    [ "$status" -eq 0 ]
    [[ "$output" == *"#7 MERGED"* ]]
}

@test "a failed PUT is not retried, and a PR that did merge is reported merged" {
    PUT_FAIL=1 MERGED_7=true run bash "$SCRIPT" 7
    [ "$status" -eq 0 ]
    [[ "$output" == *"PR is merged"* ]]
    [ "$(grep -c -- '-X PUT' "$GH_LOG")" -eq 1 ]
}

@test "a failed PUT on an unmerged PR is REFUSED" {
    PUT_FAIL=1 run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSED: merge PUT failed"* ]]
    [ "$(grep -c -- '-X PUT' "$GH_LOG")" -eq 1 ]
}

@test "refuses a repo whose owner is not the authenticated user" {
    ME=someone-else run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"repo owner"* ]]
    refute_log "PUT"
}

@test "login comparison is case-insensitive" {
    ME=ACME AUTHOR_7=Acme run bash "$SCRIPT" 7
    [ "$status" -eq 0 ]
    [[ "$output" == *"#7 MERGED"* ]]
}

@test "refuses a PR authored by someone else" {
    AUTHOR_8="renovate[bot]" run bash "$SCRIPT" 7 8
    [ "$status" -ne 0 ]
    [[ "$output" == *"#7 MERGED"* ]]
    [[ "$output" == *"#8 REFUSED: author"* ]]
    refute_log "pulls/8/merge"
}

@test "merges a green Dependabot PR touching only pyproject.toml and poetry.lock (#1076)" {
    AUTHOR_7="dependabot[bot]" FILES_7=$'pyproject.toml\t\npoetry.lock\t' run bash "$SCRIPT" 7
    [ "$status" -eq 0 ]
    [[ "$output" == *"#7 MERGED"* ]]
}

@test "a Dependabot PR editing a required check's workflow is still refused by rule (2) (#1076)" {
    AUTHOR_7="dependabot[bot]" FILES_7=$'.github/workflows/ci.yml\t' run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"required check ["* ]]
    refute_log "PUT"
}

@test "a plain 'dependabot' login is refused, and the message names both accepted authors (#1076)" {
    AUTHOR_7=dependabot run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"#7 REFUSED: author 'dependabot' is not 'acme' or dependabot[bot]"* ]]
    refute_log "PUT"
}

@test "the Dependabot login match is case-insensitive (#1076)" {
    AUTHOR_7="Dependabot[bot]" run bash "$SCRIPT" 7
    [ "$status" -eq 0 ]
    [[ "$output" == *"#7 MERGED"* ]]
}

@test "a dependabot PR carrying a human-authored commit is refused (#1076)" {
    COMMITS_7=$'dependabot[bot]\tweb-flow\ttrue\nmallory\tmallory\ttrue' AUTHOR_7="dependabot[bot]" run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"#7 REFUSED: dependabot PR carries a commit"* ]]
    refute_log "PUT"
}

@test "a dependabot PR with an unverified commit is refused (#1076)" {
    COMMITS_7=$'dependabot[bot]\tmallory\tfalse' AUTHOR_7="dependabot[bot]" run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"#7 REFUSED: dependabot PR carries a commit"* ]]
    refute_log "PUT"
}

@test "a dependabot PR whose head ref is not dependabot/* is refused (#1076)" {
    HEAD_REF_7="feature/x" AUTHOR_7="dependabot[bot]" run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"#7 REFUSED: dependabot PR head ref"* ]]
    refute_log "PUT"
}

@test "a dependabot PR from another repo is refused (#1076)" {
    HEAD_REPO_7="mallory/widgets" AUTHOR_7="dependabot[bot]" run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"#7 REFUSED: dependabot PR head repo"* ]]
    refute_log "PUT"
}

@test "an unreadable commit list is UNKNOWN for a dependabot PR (#1076)" {
    COMMITS_FAIL=1 AUTHOR_7="dependabot[bot]" run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"#7 UNKNOWN: cannot read the PR's commits"* ]]
    refute_log "PUT"
}

@test "an owner PR never reads commits or needs a dependabot head ref (#1076)" {
    HEAD_REF_7="feature/x" COMMITS_FAIL=1 run bash "$SCRIPT" 7
    [ "$status" -eq 0 ]
    [[ "$output" == *"#7 MERGED"* ]]
    refute_log "pulls/7/commits"
}

@test "fails closed when the authenticated user cannot be read" {
    USER_FAIL=1 run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"UNKNOWN"* ]]
    refute_log "PUT"
}

@test "uses only REST api calls (never gh pr or graphql)" {
    run bash "$SCRIPT" 7
    [ "$status" -eq 0 ]
    [ "$(grep -c -v '^api ' "$GH_LOG")" -eq 0 ]
    refute_log "graphql"
}
