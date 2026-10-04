#!/usr/bin/env bats
#
# The Super+B backup screen lets the operator pick zip's own 0-9 compression
# level (a radiolist, never a slider/percentage) and remembers the choice as
# LAST_ZIP_LEVEL= beside LAST_DEST in ~/.config/backup-external-ssd.conf,
# falling back to 6 when unset or not a single digit (dotfiles-linux-dev#368).

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP="$(mktemp -d)"
    # Source the script for its helpers only: it defines functions, then calls main at the end.
    FUNCS="$TMP/funcs.sh"
    sed '/^main "\$@"/d; /^main$/d' "$REPO_ROOT/storage/backup_external_ssd.sh" > "$FUNCS"
    HOME="$TMP/home"; export HOME
    mkdir -p "$HOME"
    source "$FUNCS"

    STUBS="$TMP/stubs"
    mkdir -p "$STUBS"
    PATH="$STUBS:$PATH"
}

teardown() {
    rm -rf "$TMP"
}

@test "a saved zip level is read back" {
    save_last_zip_level "3"
    [ "$(load_last_zip_level)" = "3" ]
}

@test "an unset saved zip level falls back to 6" {
    run normalize_zip_level "$(load_last_zip_level)"
    [ "$status" -eq 0 ]
    [ "$output" = "6" ]
}

@test "a non-digit saved zip level falls back to 6" {
    save_last_zip_level "abc"
    run normalize_zip_level "$(load_last_zip_level)"
    [ "$output" = "6" ]
}

@test "a multi-digit saved zip level falls back to 6" {
    save_last_zip_level "10"
    run normalize_zip_level "$(load_last_zip_level)"
    [ "$output" = "6" ]
}

@test "a valid single-digit saved zip level is preserved" {
    save_last_zip_level "0"
    run normalize_zip_level "$(load_last_zip_level)"
    [ "$output" = "0" ]

    save_last_zip_level "9"
    run normalize_zip_level "$(load_last_zip_level)"
    [ "$output" = "9" ]
}

@test "saving the zip level does not clobber an existing LAST_DEST" {
    save_last_dest "/cloud/backup"
    save_last_zip_level "3"
    [ "$(load_last_dest)" = "/cloud/backup" ]
    [ "$(load_last_zip_level)" = "3" ]
}

@test "saving the destination does not clobber an existing LAST_ZIP_LEVEL" {
    save_last_zip_level "3"
    save_last_dest "/cloud/backup"
    [ "$(load_last_zip_level)" = "3" ]
    [ "$(load_last_dest)" = "/cloud/backup" ]
}

@test "the chosen level is what reaches zip's -N flag" {
    cat > "$STUBS/zip" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$ZIP_ARGS_FILE"
exit 0
EOF
    chmod +x "$STUBS/zip"

    local srcdir="$TMP/src"
    mkdir -p "$srcdir"
    ZIP_ARGS_FILE="$TMP/zip_args"
    export ZIP_ARGS_FILE

    zip_archive "$srcdir" "$TMP/out.zip" "3"

    grep -qx -- "-3" "$ZIP_ARGS_FILE"
}

@test "cancelling the compression list returns failure with no chosen level" {
    cat > "$STUBS/zenity" <<'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "$STUBS/zenity"

    run choose_zip_level 6
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "the main flow aborts before zipping when the level dialog is cancelled" {
    body="$(sed -n '/zip_level=\$(choose_zip_level/,/^    fi$/p' "$REPO_ROOT/storage/backup_external_ssd.sh")"
    [ -n "$body" ]
    [[ "$body" == *'|| exit 0'* ]]

    local choose_line zip_line
    choose_line=$(grep -n 'zip_level=\$(choose_zip_level' "$REPO_ROOT/storage/backup_external_ssd.sh" | cut -d: -f1)
    zip_line=$(grep -n 'zip_archive "\$src" "\$dest" "\$zip_level" &' "$REPO_ROOT/storage/backup_external_ssd.sh" | cut -d: -f1)
    [ -n "$choose_line" ]
    [ -n "$zip_line" ]
    [ "$choose_line" -lt "$zip_line" ]
}
