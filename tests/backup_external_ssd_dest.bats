#!/usr/bin/env bats
#
# A saved backup destination that no longer exists must not be pre-filled.
#
# Step 3 of the backup runs `mkdir -p "$dest_dir"`, so accepting a pre-filled dead path
# re-creates the tree on the LOCAL disk and writes the archive there — a backup that looks like
# it went to the cloud and did not. Measured while migrating off Insync (dotfiles-linux-dev#360): the
# saved path was ~/Insync/<account>/OneDrive/Workspace/!BACKUP/External Storage, and the whole
# ~/Insync tree is deleted by that migration.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP="$(mktemp -d)"
    # Source the script for its helpers only: it defines functions, then calls main at the end.
    FUNCS="$TMP/funcs.sh"
    sed '/^main "\$@"/d; /^main$/d' "$REPO_ROOT/storage/backup_external_ssd.sh" > "$FUNCS"
    HOME="$TMP/home"; export HOME
    mkdir -p "$HOME"
    source "$FUNCS"
}

teardown() {
    rm -rf "$TMP"
}

@test "a destination whose parent exists is not stale" {
    mkdir -p "$TMP/cloud/BACKUP"
    run last_dest_is_stale "$TMP/cloud/BACKUP/External Storage"
    [ "$status" -eq 1 ]
}

@test "a destination under a deleted tree is stale" {
    run last_dest_is_stale "$TMP/gone/Insync/account/OneDrive/BACKUP/External Storage"
    [ "$status" -eq 0 ]
}

@test "an empty saved destination is not treated as stale" {
    # Nothing was ever saved; the prompt falls back to $HOME on its own.
    run last_dest_is_stale ""
    [ "$status" -eq 1 ]
}

@test "the prompt drops the stale value instead of pre-filling it" {
    local body
    body="$(sed -n '/last_dest_is_stale "\$last_dest"/,/^    fi$/p' "$REPO_ROOT/storage/backup_external_ssd.sh")"
    [ -n "$body" ]
    [[ "$body" == *'last_dest=""'* ]]
    [[ "$body" == *"no longer exists"* ]]
}
