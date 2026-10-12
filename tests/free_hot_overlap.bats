#!/usr/bin/env bats
#
# free_hot_overlap in ai_clients/claude/hooks/lib/free_surface.sh (dotfiles-linux-dev#714, owner option
# (c)): the bash twin of dispatch_plan.py's hot-file rule. Pure set math over FREE_HELD_PATHS plus
# a per-repo list file (DISPATCH_HOT_FILES_FILE here; in real use
# `<git-common-dir>/dispatch-hot-files.txt`). Hot overlap blocks; every other open-PR overlap is
# still only free_classify_files' annotation.

setup() {
    source "$BATS_TEST_DIRNAME/../ai_clients/claude/hooks/lib/free_surface.sh"
    BIN="$(mktemp -d)"
    PATH="$BIN:$PATH"
    # Open PR 7 changes ci.yml, shared/x.sh and mkdocs.yml. A pushed branch with no PR (old.yml)
    # is NOT served: it must never count as open-PR overlap.
    cat >"$BIN/gh" <<'STUB'
#!/bin/bash
echo "$*" >>"$(dirname "$0")/calls"
case "$*" in
*"pulls?state=open"*) [ "${GH_FAIL:-0}" = 1 ] && exit 1; echo 7 ;;
*"pulls/7/files"*) printf '.github/workflows/ci.yml\nshared/x.sh\nmkdocs.yml\n'; [ -n "${PR_EXTRA:-}" ] && echo "$PR_EXTRA"; exit 0 ;;
*) exit 1 ;;
esac
STUB
    chmod +x "$BIN/gh"
    HOT="$(mktemp)"
    export DISPATCH_HOT_FILES_FILE="$HOT"
    printf '# append points\n.github/workflows/ci.yml\nmkdocs.*\n' >"$HOT"
}

teardown() {
    rm -rf "$HOT" "$BIN"
}

@test "a hot file held by an open PR is reported as hot:<path>" {
    run free_hot_overlap o r .github/workflows/ci.yml new/a.sh
    [ "$status" -eq 0 ]
    [ "$output" = "hot:.github/workflows/ci.yml" ]
}

@test "a NON-hot file held by an open PR is not a hot overlap (annotation only)" {
    run free_hot_overlap o r shared/x.sh
    [ "$output" = "none" ]
    FREE_STATUS=ok
    FREE_HELD_PATHS='shared/x.sh'
    run free_classify_files shared/x.sh
    [ "$output" = "held:shared/x.sh" ]
}

@test "a hot file that no open PR holds is none" {
    printf 'unheld.yml\n' >>"$HOT"
    run free_hot_overlap o r unheld.yml
    [ "$output" = "none" ]
}

@test "hot patterns are globs" {
    run free_hot_overlap o r mkdocs.yml
    [ "$output" = "hot:mkdocs.yml" ]
}

@test "a missing list declares nothing: none, status 0" {
    export DISPATCH_HOT_FILES_FILE="$HOT.absent"
    run free_hot_overlap o r .github/workflows/ci.yml
    [ "$status" -eq 0 ]
    [ "$output" = "none" ]
}

@test "an unreadable list (a directory) declares nothing: none, status 0" {
    export DISPATCH_HOT_FILES_FILE="$BATS_TEST_DIRNAME"
    run free_hot_overlap o r .github/workflows/ci.yml
    [ "$status" -eq 0 ]
    [ "$output" = "none" ]
}

@test "a branch-only hot file (no open PR) is not open-PR overlap" {
    printf '.github/workflows/old.yml\n' >>"$HOT"
    run free_hot_overlap o r .github/workflows/old.yml
    [ "$output" = "none" ]
}

# --- glob vs glob: pattern-against-pattern matching cannot prove two globs disjoint ----------

@test "candidate glob and hot glob that meet only on an open-PR file overlap" {
    printf 'docs/*b.md\n' >>"$HOT"
    PR_EXTRA='docs/ab.md' run free_hot_overlap o r 'docs/a*.md'
    [ "$status" -eq 0 ]
    [ "$output" = "hot:docs/ab.md" ]
}

@test "same globs, open PR touches only a file outside the intersection: none" {
    printf 'docs/*b.md\n' >>"$HOT"
    PR_EXTRA='docs/zz.md' run free_hot_overlap o r 'docs/a*.md'
    [ "$output" = "none" ]
}

@test "glob candidate with a failing open-PR read fails closed" {
    printf 'docs/*b.md\n' >>"$HOT"
    GH_FAIL=1 run free_hot_overlap o r 'docs/a*.md'
    [ "$status" -eq 1 ]
    [ "$output" = "UNKNOWN" ]
}

@test "all-literal, non-hot candidate keeps the no-read shortcut" {
    run free_hot_overlap o r new/a.sh
    [ "$output" = "none" ]
    [ ! -e "$BIN/calls" ]
}

@test "a failing open-PR read fails closed: UNKNOWN, never none" {
    export GH_FAIL=1
    run free_hot_overlap o r .github/workflows/ci.yml
    [ "$status" -eq 1 ]
    [ "$output" = "UNKNOWN" ]
}
