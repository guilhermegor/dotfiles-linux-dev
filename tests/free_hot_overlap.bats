#!/usr/bin/env bats
#
# free_hot_overlap in ai_clients/claude/hooks/lib/free_surface.sh (dotfiles-linux-dev#714, owner option
# (c)): the bash twin of dispatch_plan.py's hot-file rule. Pure set math over FREE_HELD_PATHS plus
# a per-repo list file (DISPATCH_HOT_FILES_FILE here; in real use
# `<git-common-dir>/dispatch-hot-files.txt`). Hot overlap blocks; every other open-PR overlap is
# still only free_classify_files' annotation.

setup() {
    source "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/free_surface.sh"
    FREE_STATUS="ok"
    FREE_HELD_PATHS='.github/workflows/ci.yml
shared/x.sh'
    HOT="$(mktemp)"
    export DISPATCH_HOT_FILES_FILE="$HOT"
    printf '# append points\n.github/workflows/ci.yml\nmkdocs.*\n' >"$HOT"
}

teardown() {
    rm -f "$HOT"
}

@test "a hot file held by an open PR is reported as hot:<path>" {
    run free_hot_overlap .github/workflows/ci.yml new/a.sh
    [ "$status" -eq 0 ]
    [ "$output" = "hot:.github/workflows/ci.yml" ]
}

@test "a NON-hot file held by an open PR is not a hot overlap (annotation only)" {
    run free_hot_overlap shared/x.sh
    [ "$output" = "none" ]
    run free_classify_files shared/x.sh
    [ "$output" = "held:shared/x.sh" ]
}

@test "a hot file that no open PR holds is none" {
    run free_hot_overlap mkdocs.yml
    [ "$output" = "none" ]
}

@test "hot patterns are globs" {
    FREE_HELD_PATHS='mkdocs.yml'
    run free_hot_overlap mkdocs.yml
    [ "$output" = "hot:mkdocs.yml" ]
}

@test "a missing list declares nothing: none, status 0" {
    export DISPATCH_HOT_FILES_FILE="$HOT.absent"
    run free_hot_overlap .github/workflows/ci.yml
    [ "$status" -eq 0 ]
    [ "$output" = "none" ]
}

@test "an unreadable list (a directory) declares nothing: none, status 0" {
    export DISPATCH_HOT_FILES_FILE="$BATS_TEST_DIRNAME"
    run free_hot_overlap .github/workflows/ci.yml
    [ "$status" -eq 0 ]
    [ "$output" = "none" ]
}

@test "an unprimed gate fails closed: UNKNOWN, never none" {
    FREE_STATUS=unknown
    run free_hot_overlap .github/workflows/ci.yml
    [ "$status" -eq 1 ]
    [ "$output" = "UNKNOWN" ]
}
