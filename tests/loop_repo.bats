#!/usr/bin/env bats
#
# Unit tests for loop_round_invoked in ai_clients/claude/hooks/lib/loop_repo.sh
#
# The one recogniser every dev-loop Stop guard shares (dotfiles-linux-dev#1135): four invocation
# shapes count, a user turn that merely MENTIONS /dev-loop does not.
#
# Run locally: bats tests/loop_repo.bats

setup() {
    LIB="${LOOP_REPO_LIB:-$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/lib/loop_repo.sh}"
    TEST_TMP="$(mktemp -d)"
    # shellcheck source=/dev/null
    source "$LIB"
}

teardown() { rm -rf "$TEST_TMP"; }

skill_record() {
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill": "%s"}}]}}\n' "$1"
}

command_record() {
    printf '{"type":"user","message":{"content":"<command-name>%s</command-name>"}}\n' "$1"
}

@test "loop_round_invoked: each of the four shapes counts" {
    local i=0 line
    while IFS= read -r line; do
        i=$((i + 1))
        eval "$line" >"$TEST_TMP/t$i.jsonl"
        if loop_round_invoked "$TEST_TMP/t$i.jsonl"; then :; else
            echo "shape not recognised: $line" >&2
            return 1
        fi
    done <<'EOF'
skill_record dev-loop
skill_record s:dev-loop
command_record /dev-loop
command_record /s:dev-loop
EOF
}

@test "loop_round_invoked: a user turn merely mentioning /dev-loop does not count" {
    printf '{"type":"user","message":{"content":"please run /dev-loop soon"}}\n' >"$TEST_TMP/t.jsonl"
    run loop_round_invoked "$TEST_TMP/t.jsonl"
    [ "$status" -eq 1 ]
}

@test "loop_round_invoked: other skills and a missing transcript do not count" {
    skill_record other-skill >"$TEST_TMP/t.jsonl"
    run loop_round_invoked "$TEST_TMP/t.jsonl"
    [ "$status" -eq 1 ]
    run loop_round_invoked "$TEST_TMP/absent.jsonl"
    [ "$status" -eq 1 ]
}

@test "loop_round_invoked: a later non-matching record does not flip a match" {
    { skill_record dev-loop; printf '{"type":"user","message":{"content":"ok"}}\n'; } >"$TEST_TMP/t.jsonl"
    run loop_round_invoked "$TEST_TMP/t.jsonl"
    [ "$status" -eq 0 ]
}
