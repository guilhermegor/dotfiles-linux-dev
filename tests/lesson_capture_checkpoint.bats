#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lesson_capture_checkpoint.sh
#
# Strategy (same as protected_branch_guard.bats): the hook is a pure
# stdin->stdout JSON filter. `payload <cmd>` builds the PostToolUse payload;
# `run_hook <cmd>` pipes it through the hook so $output is its stdout.
#
# dotfiles-linux-dev#386: the mirror moved from a hand-appended `docs/*-lessons.md`
# entry (which needed an exact `- **Source:**` field for check_mirrors()'s
# literal-substring join) to a GENERATED `.specs/_lessons/*-lessons.md` file
# (`make lessons_mirror` / generate_lesson_mirrors.sh). The reminder's job is
# now "capture the lesson, then regenerate" — it no longer needs to coach the
# exact field shape, because the generator produces it deterministically.
# This supersedes the pre-#386 pins on the literal `- **Source:**` quote.
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    HOOK="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/ai_clients/claude/hooks/lesson_capture_checkpoint.sh"
}

payload() {
    jq -nc --arg cmd "$1" '{tool_name: "Bash", tool_input: {command: $cmd}}'
}

run_hook() {
    payload "$1" | "$HOOK"
}

@test "gh pr create reminder points at regenerating the mirror, not hand-appending" {
    run run_hook "gh pr create --title x --body y"
    [ "$status" -eq 0 ]
    ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    [[ "$ctx" == *"make lessons_mirror"* ]]
    [[ "$ctx" == *"GENERATED, never hand-appended"* ]]
}

@test "rtk gh issue create also fires and points at the generator" {
    run run_hook "rtk gh issue create --title x"
    [ "$status" -eq 0 ]
    ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    [[ "$ctx" == *"generate_lesson_mirrors.sh"* ]]
}

@test "unrelated command does not fire the checkpoint" {
    run run_hook "git status"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# dotfiles-linux-dev#386: the reminder must no longer point at the retired docs/ path — that
# location was forbidden by .specs/CLAUDE.md's own "What does NOT belong here" section
# even before the mirror was generated, and now the mirror lives under .specs/_lessons/.
@test "reminder no longer names the retired docs/*-lessons.md path" {
    run run_hook "gh pr create --title x --body y"
    [ "$status" -eq 0 ]
    ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    [[ "$ctx" != *"docs/blueprintx-lessons.md"* ]]
    [[ "$ctx" != *"docs/dotfiles-dev-lessons.md"* ]]
    [[ "$ctx" == *".specs/_lessons/"* ]]
}
