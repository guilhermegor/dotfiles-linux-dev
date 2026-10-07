#!/usr/bin/env bats
#
# Unit tests for tests/check_specs_structure.sh
#
# Strategy: the gate is a plain CLI filter that takes an optional SPECS_DIR
# argument and reports exit 0 = aligned, exit 1 = findings on stdout/stderr.
# Every test builds a throwaway .specs/-shaped tree under a temp dir (never
# the real repo tree) and asserts on exit status + output.
#
# Run locally: bats tests/check_specs_structure.bats

setup() {
    GATE="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/tests/check_specs_structure.sh"
    TEST_TMP="$(mktemp -d)"
    SPECS_DIR="$TEST_TMP/specs"
    mkdir -p "$SPECS_DIR"
}

teardown() {
    rm -rf "$TEST_TMP"
}

write_claude_md() {
    printf 'x' > "$SPECS_DIR/CLAUDE.md"
}

write_feature() {
    local name="$1" file="${2:-design.md}"
    mkdir -p "$SPECS_DIR/features/$name"
    printf 'x' > "$SPECS_DIR/features/$name/$file"
}

run_gate() {
    run bash "$GATE" "$SPECS_DIR"
}

# --- missing tree / empty tree ----------------------------------------------

@test "no SPECS_DIR at all -> exit 0 silently" {
    run bash "$GATE" "$TEST_TMP/does-not-exist"
    [ "$status" -eq 0 ]
}

@test "CLAUDE.md alone -> aligned" {
    write_claude_md
    run_gate
    [ "$status" -eq 0 ]
    [[ "$output" == *"aligned"* ]]
}

# --- MISSING_CLAUDE_MD -------------------------------------------------------

@test "MISSING_CLAUDE_MD: fires when .specs/CLAUDE.md is absent" {
    mkdir -p "$SPECS_DIR/features"
    run_gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"MISSING_CLAUDE_MD"* ]]
}

# --- DISALLOWED_TOP_LEVEL (covers the type-folder rejection) ----------------

@test "DISALLOWED_TOP_LEVEL: a type-folder like bugfix/ fails, naming it and why" {
    write_claude_md
    mkdir -p "$SPECS_DIR/bugfix"
    run_gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"DISALLOWED_TOP_LEVEL 'bugfix'"* ]]
    [[ "$output" == *"$SPECS_DIR/bugfix"* ]]
}

@test "DISALLOWED_TOP_LEVEL: a DANGLING symlink is still judged, not skipped" {
    write_claude_md
    ln -s "$TEST_TMP/nowhere" "$SPECS_DIR/bugfix"
    [ ! -e "$SPECS_DIR/bugfix" ]  # the condition that used to skip it
    run_gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"DISALLOWED_TOP_LEVEL 'bugfix'"* ]]
}

@test "DISALLOWED_TOP_LEVEL: does not fire for the four allowed entries" {
    write_claude_md
    mkdir -p "$SPECS_DIR/features" "$SPECS_DIR/backlog" "$SPECS_DIR/_lessons"
    run_gate
    [[ "$output" != *"DISALLOWED_TOP_LEVEL"* ]]
}

# --- backlog/ accepted -------------------------------------------------------

@test "backlog/: a kebab-case-slug.md file is accepted" {
    write_claude_md
    mkdir -p "$SPECS_DIR/backlog"
    printf 'x' > "$SPECS_DIR/backlog/cross-feature-note.md"
    run_gate
    [ "$status" -eq 0 ]
    [[ "$output" != *"BAD_BACKLOG_NAME"* ]]
}

@test "BAD_BACKLOG_NAME: fires for a non-kebab-case backlog file" {
    write_claude_md
    mkdir -p "$SPECS_DIR/backlog"
    printf 'x' > "$SPECS_DIR/backlog/Some_Note_20260101.md"
    run_gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"BAD_BACKLOG_NAME"* ]]
}

# --- features/ naming --------------------------------------------------------

@test "BAD_FEATURE_NAME: does not fire for a well-formed kebab-case feature" {
    write_claude_md
    write_feature "some-feature"
    run_gate
    [ "$status" -eq 0 ]
    [[ "$output" != *"BAD_FEATURE_NAME"* ]]
}

@test "BAD_FEATURE_NAME: does not fire when the leading segment is alnum, not pure digits" {
    write_claude_md
    write_feature "4k-downloader-media-folder"
    run_gate
    [ "$status" -eq 0 ]
    [[ "$output" != *"BAD_FEATURE_NAME"* ]]
}

@test "BAD_FEATURE_NAME: fires for a non-kebab-case directory name" {
    write_claude_md
    write_feature "Some_Feature"
    run_gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"BAD_FEATURE_NAME 'Some_Feature' is not kebab-case"* ]]
}

@test "BAD_FEATURE_NAME: fires when the name leads with a bare issue number" {
    write_claude_md
    write_feature "442-fix-thing"
    run_gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"BAD_FEATURE_NAME '442-fix-thing' leads with a bare issue number"* ]]
}

# --- MISSING_FEATURE_FILES ---------------------------------------------------

@test "MISSING_FEATURE_FILES: fires when none of spec.md/design.md/plan.md exist" {
    write_claude_md
    mkdir -p "$SPECS_DIR/features/empty-feature"
    run_gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"MISSING_FEATURE_FILES"* ]]
}

@test "MISSING_FEATURE_FILES: does not fire when spec.md is present" {
    write_claude_md
    write_feature "has-spec" "spec.md"
    run_gate
    [[ "$output" != *"MISSING_FEATURE_FILES"* ]]
}

@test "MISSING_FEATURE_FILES: does not fire for a plan.md-only legacy feature" {
    write_claude_md
    write_feature "has-plan" "plan.md"
    run_gate
    [[ "$output" != *"MISSING_FEATURE_FILES"* ]]
}

# --- _lessons/ exemption ------------------------------------------------------

@test "_lessons/: any filename inside is exempt from naming rules" {
    write_claude_md
    mkdir -p "$SPECS_DIR/_lessons"
    printf 'x' > "$SPECS_DIR/_lessons/Weird_Name-not_kebab.md"
    run_gate
    [ "$status" -eq 0 ]
    [[ "$output" != *"BAD_"* ]]
}

# --- a fully legitimate tree passes end to end -------------------------------

@test "a legitimate full tree (CLAUDE.md, features/, backlog/, _lessons/) passes" {
    write_claude_md
    write_feature "good-feature" "design.md"
    mkdir -p "$SPECS_DIR/backlog" "$SPECS_DIR/_lessons"
    printf 'x' > "$SPECS_DIR/backlog/cross-feature-note.md"
    printf 'x' > "$SPECS_DIR/_lessons/blueprintx-lessons.md"
    run_gate
    [ "$status" -eq 0 ]
    [[ "$output" == *"aligned"* ]]
}

# --- the two holes the ladder review found (dotfiles-linux-dev#453) ----------------
#
# Both are the same shape as the top-level DANGLING-symlink case above, in
# places the earlier fix did not reach: an entry the gate cannot SEE is an
# entry it admits.

@test "a DANGLING symlink inside features/ is judged, not skipped" {
    write_claude_md
    mkdir -p "$SPECS_DIR/features"
    ln -s "$TEST_TMP/nowhere" "$SPECS_DIR/features/Bad_Name"
    [ ! -e "$SPECS_DIR/features/Bad_Name" ]  # the condition that used to skip it
    run_gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"features/Bad_Name"* ]]
}

@test "a DANGLING symlink inside backlog/ is judged, not skipped" {
    write_claude_md
    mkdir -p "$SPECS_DIR/backlog"
    ln -s "$TEST_TMP/nowhere" "$SPECS_DIR/backlog/Bad_Name.md"
    [ ! -e "$SPECS_DIR/backlog/Bad_Name.md" ]
    run_gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"backlog/Bad_Name.md"* ]]
}

@test "DISALLOWED_TOP_LEVEL: a HIDDEN top-level entry is judged, not skipped" {
    write_claude_md
    printf 'x' > "$SPECS_DIR/.gitignore"
    run_gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"DISALLOWED_TOP_LEVEL '.gitignore'"* ]]
}

@test "an empty features/ dir still short-circuits (nullglob is NOT set)" {
    write_claude_md
    mkdir -p "$SPECS_DIR/features" "$SPECS_DIR/backlog"
    run_gate
    [ "$status" -eq 0 ]
}
