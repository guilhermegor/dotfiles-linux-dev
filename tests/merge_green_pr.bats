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
if [[ "$args" == *"-X PUT"* ]]; then exit 0; fi
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
    printf 'sha%s\t%s\tfalse\tmaster\n' "$n" "$s"
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

@test "makes no GraphQL call" {
    run bash "$SCRIPT" 7
    refute_log "graphql"
}
