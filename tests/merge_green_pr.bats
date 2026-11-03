#!/usr/bin/env bats
# merge_green_pr.sh (dotfiles-linux-dev#868): REST-only squash merge of green PRs.
# `gh` and `git` are stubbed on PATH; no network.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/merge_green_pr.sh"
    BIN="$BATS_TEST_TMPDIR/bin"
    GH_LOG="$BATS_TEST_TMPDIR/gh.log"
    mkdir -p "$BIN"
    : > "$GH_LOG"
    printf '#!/bin/bash\necho "git@github.com:acme/widgets.git"\n' > "$BIN/git"
    # Behaviour per PR is driven by env: STATE_<n>, CHECK_<n>, PROT_FAIL.
    cat > "$BIN/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "$GH_LOG"
args="$*"
if [[ "$args" == "api user"* ]]; then
    [ -n "${USER_FAIL:-}" ] && exit 1
    echo "${ME:-acme}"; exit 0
fi
if [[ "$args" == *"-X PUT"* ]]; then exit 0; fi
if [[ "$args" == *"/files"* ]]; then
    [ -n "${FILES_FAIL:-}" ] && exit 1
    n="${args#*pulls/}"; n="${n%%/*}"
    f="FILES_$n"; printf '%s\n' "${!f:-src/app.sh$(printf '\t')}"; exit 0
fi
if [[ "$args" == *"/protection"* ]]; then
    [ -n "${PROT_FAIL:-}" ] && exit 1
    echo "build"; exit 0
fi
if [[ "$args" == *"/check-runs"* ]]; then
    n="${args#*commits/sha}"; n="${n%%/*}"
    c="CHECK_$n"; c="${!c:-success}"
    printf 'build\t%s\n' "$c"
    [ "$c" = missing ] && exit 0
    printf 'Review threads answered\t%s\n' "$c"
    exit 0
fi
if [[ "$args" == *"/pulls/"* ]]; then
    n="${args#*pulls/}"; n="${n%% *}"
    s="STATE_$n"; s="${!s:-clean}"
    a="AUTHOR_$n"; a="${!a:-acme}"
    f="FILES_$n"; cf="$(printf '%s\n' "${!f:-x}" | grep -c .)"
    c="CHANGED_$n"; c="${!c:-$cf}"
    printf 'sha%s\t%s\tfalse\tmaster\t%s\t%s\n' "$n" "$s" "$a" "$c"
    exit 0
fi
exit 1
STUB
    chmod +x "$BIN/git" "$BIN/gh"
    export GH_LOG MERGE_GREEN_RETRY_SLEEP=0
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

@test "fails closed UNKNOWN when the protection read fails" {
    PROT_FAIL=1 run bash "$SCRIPT" 7
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

@test "refuses a PR touching .github/workflows or .github/actions" {
    FILES_7=$'src/a.sh\t\n.github/workflows/ci.yml\t' run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"touches CI definitions"* ]]
    FILES_8=".github/actions/x/action.yml"$'\t' run bash "$SCRIPT" 8
    [ "$status" -ne 0 ]
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
    [[ "$output" == *"touches CI definitions"* ]]
    refute_log "PUT"
}

@test "files read failure is UNKNOWN and does not merge" {
    FILES_FAIL=1 run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"UNKNOWN"* ]]
    refute_log "PUT"
}

@test "refuses a repo whose owner is not the authenticated user" {
    ME=someone-else run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"repo owner"* ]]
    refute_log "PUT"
}

@test "refuses a PR authored by someone else" {
    AUTHOR_8=dependabot run bash "$SCRIPT" 7 8
    [ "$status" -ne 0 ]
    [[ "$output" == *"#7 MERGED"* ]]
    [[ "$output" == *"#8 REFUSED: author"* ]]
    refute_log "pulls/8/merge"
}

@test "fails closed when the authenticated user cannot be read" {
    USER_FAIL=1 run bash "$SCRIPT" 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"UNKNOWN"* ]]
    refute_log "PUT"
}

@test "makes no GraphQL call" {
    run bash "$SCRIPT" 7
    refute_log "graphql"
}
