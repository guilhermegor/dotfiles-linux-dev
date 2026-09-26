#!/usr/bin/env bats
#
# Unit tests for ai_clients/claude/hooks/lib/tasks_tracker_gate.sh (dotfiles-dev#485).
# Both halves of the gate contract (ai_clients/CLAUDE.md, "A gate's contract"): success returns
# a usable, non-empty answer on a fixture that provably has content, and the fail-closed path
# leaves every global empty. All `gh` calls are stubbed -- never a live token.

setup() {
    source "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/tasks_tracker_gate.sh"
}

# --- _tracker_feature_dirs: the filesystem half -------------------------------------------------

@test "_tracker_feature_dirs: a plan.md with no tasks.md is a candidate" {
    mkdir -p "$BATS_TEST_TMPDIR/.specs/features/widget-export"
    : > "$BATS_TEST_TMPDIR/.specs/features/widget-export/plan.md"

    run _tracker_feature_dirs "$BATS_TEST_TMPDIR"
    [ "$status" -eq 0 ]
    [ "$output" = "widget-export" ]
}

@test "_tracker_feature_dirs: a feature that already has tasks.md is not a candidate" {
    mkdir -p "$BATS_TEST_TMPDIR/.specs/features/widget-export"
    : > "$BATS_TEST_TMPDIR/.specs/features/widget-export/plan.md"
    : > "$BATS_TEST_TMPDIR/.specs/features/widget-export/tasks.md"

    run _tracker_feature_dirs "$BATS_TEST_TMPDIR"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "_tracker_feature_dirs: a directory with none of spec/design/plan.md is not a candidate" {
    mkdir -p "$BATS_TEST_TMPDIR/.specs/features/empty-shell"

    run _tracker_feature_dirs "$BATS_TEST_TMPDIR"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "_tracker_feature_dirs: no .specs/features at all prints nothing, does not fail" {
    run _tracker_feature_dirs "$BATS_TEST_TMPDIR"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- gate_missing_tracker: the forge half + the quiet case ---------------------------------------

@test "gate_missing_tracker: an in-flight feature referenced by an open issue is reported" {
    mkdir -p "$BATS_TEST_TMPDIR/.specs/features/widget-export"
    : > "$BATS_TEST_TMPDIR/.specs/features/widget-export/plan.md"

    gh() {
        case "$*" in
            "search issues --repo o/r --state open --include-prs --match title,body widget-export"*)
                echo '#512 (https://github.com/o/r/issues/512)'
                ;;
            *) return 1 ;;
        esac
    }

    gate_missing_tracker o r "$BATS_TEST_TMPDIR"
    local rc=$?

    [ "$rc" -eq 0 ]
    [ "$TRACKER_STATUS" = "ok" ]
    [[ "$TRACKER_REPORT" == ".specs/features/widget-export has no tasks.md -- referenced by open #512 (https://github.com/o/r/issues/512)" ]]
}

@test "gate_missing_tracker: a finished feature with no open issue/PR reference is quiet" {
    mkdir -p "$BATS_TEST_TMPDIR/.specs/features/shipped-thing"
    : > "$BATS_TEST_TMPDIR/.specs/features/shipped-thing/plan.md"

    gh() {
        case "$*" in
            "search issues --repo o/r --state open --include-prs --match title,body shipped-thing"*)
                echo ""
                ;;
            *) return 1 ;;
        esac
    }

    gate_missing_tracker o r "$BATS_TEST_TMPDIR"
    local rc=$?

    [ "$rc" -eq 0 ]
    [ "$TRACKER_STATUS" = "ok" ]
    [ -z "$TRACKER_REPORT" ]
}

@test "gate_missing_tracker: a gh read failure fails the whole gate closed, no partial answer" {
    mkdir -p "$BATS_TEST_TMPDIR/.specs/features/widget-export"
    : > "$BATS_TEST_TMPDIR/.specs/features/widget-export/plan.md"

    gh() { return 1; }

    local rc=0
    gate_missing_tracker o r "$BATS_TEST_TMPDIR" || rc=$?

    [ "$rc" -eq 1 ]
    [ "$TRACKER_STATUS" = "unknown" ]
    [ -z "$TRACKER_REPORT" ]
}

@test "gate_missing_tracker: no candidate directories at all reports ok with empty report" {
    gate_missing_tracker o r "$BATS_TEST_TMPDIR"
    local rc=$?

    [ "$rc" -eq 0 ]
    [ "$TRACKER_STATUS" = "ok" ]
    [ -z "$TRACKER_REPORT" ]
}

@test "gate_missing_tracker: more candidates than the search cap fails closed, never partial" {
    for i in 1 2 3; do
        mkdir -p "$BATS_TEST_TMPDIR/.specs/features/feat-$i"
        : > "$BATS_TEST_TMPDIR/.specs/features/feat-$i/plan.md"
    done

    # Any search call here would be a bug: the cap must be checked BEFORE spending one.
    gh() { return 1; }

    local rc=0
    TRACKER_MAX_SEARCHES=2 gate_missing_tracker o r "$BATS_TEST_TMPDIR" || rc=$?

    [ "$rc" -eq 1 ]
    [ "$TRACKER_STATUS" = "unknown" ]
    [ -z "$TRACKER_REPORT" ]
}
