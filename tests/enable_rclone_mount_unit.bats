#!/usr/bin/env bats
#
# Unit tests for enable_rclone_mount_unit (issue #647).
#
# Throwaway $HOME; rclone, systemctl, mountpoint and journalctl are stubs on
# PATH, so the real user systemd and the real rclone remote are never touched.
# State files under $TMP drive the stubs:
#   auth_fail      rclone lsd fails (unauthenticated)
#   enabled/active systemctl is-enabled / is-active succeed
#   mounted        mountpoint -q succeeds
#   no_mount       `systemctl enable` does NOT create the mounted marker

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP="$(mktemp -d)"
    HOME="$TMP/home"
    mkdir -p "$HOME/.config/systemd/user" "$HOME/OneDrive" "$TMP/bin"
    export HOME
    export LOG_FILE="$TMP/log"
    export CALLS="$TMP/calls.log"
    export TMP
    export RCLONE_MOUNT_WAIT=1
    export PATH="$TMP/bin:$PATH"
    : > "$HOME/.config/systemd/user/rclone-onedrive.service"

    cat > "$TMP/bin/rclone" <<'STUB'
#!/bin/bash
echo "rclone $*" >> "$CALLS"
[ "$1" = lsd ] && [ -e "$TMP/auth_fail" ] && exit 1
exit 0
STUB
    cat > "$TMP/bin/systemctl" <<'STUB'
#!/bin/bash
echo "systemctl $*" >> "$CALLS"
case "$2" in
    is-enabled) [ -e "$TMP/enabled" ] ;;
    is-active) [ -e "$TMP/active" ] ;;
    enable) [ -e "$TMP/no_mount" ] || touch "$TMP/mounted" ;;
    *) exit 0 ;;
esac
STUB
    cat > "$TMP/bin/mountpoint" <<'STUB'
#!/bin/bash
[ -e "$TMP/mounted" ]
STUB
    cat > "$TMP/bin/journalctl" <<'STUB'
#!/bin/bash
echo "journalctl $*" >> "$CALLS"
echo "JOURNAL-LINE rclone exploded"
STUB
    chmod +x "$TMP"/bin/*

    # shellcheck source=../distro_config/install_lib/_common.sh
    source "$REPO_ROOT/distro_config/install_lib/_common.sh"
    # shellcheck source=../distro_config/install_lib/sharing.sh
    source "$REPO_ROOT/distro_config/install_lib/sharing.sh"
}

teardown() {
    rm -rf "$TMP"
}

refute_call() {
    run grep -q -- "$1" "$CALLS"
    [ "$status" -ne 0 ]
}

@test "refuses when the unit file is missing" {
    rm "$HOME/.config/systemd/user/rclone-onedrive.service"
    run enable_rclone_mount_unit
    [ "$status" -ne 0 ]
    [[ "$output" == *"install_rclone_mount_unit first"* ]]
}

@test "refuses when the remote is not authenticated" {
    touch "$TMP/auth_fail"
    run enable_rclone_mount_unit
    [ "$status" -ne 0 ]
    [[ "$output" == *"not authenticated"* ]]
    refute_call "daemon-reload"
    refute_call "enable --now"
}

@test "refuses on a non-empty mount point" {
    touch "$HOME/OneDrive/precious.txt"
    run enable_rclone_mount_unit
    [ "$status" -ne 0 ]
    [[ "$output" == *"not empty"* ]]
    refute_call "enable --now"
}

@test "refuses to mount over ~/Insync" {
    mkdir "$HOME/Insync"
    run enable_rclone_mount_unit onedrive "$HOME/Insync"
    [ "$status" -ne 0 ]
    refute_call "enable --now"
}

@test "idempotent when already enabled, active and mounted" {
    touch "$TMP/enabled" "$TMP/active" "$TMP/mounted"
    run enable_rclone_mount_unit
    [ "$status" -eq 0 ]
    [[ "$output" == *"already enabled"* ]]
    refute_call "daemon-reload"
    refute_call "enable --now"
}

@test "happy path runs daemon-reload then enable --now and verifies the mount" {
    run enable_rclone_mount_unit
    [ "$status" -eq 0 ]
    reload_line=$(grep -n "systemctl --user daemon-reload" "$CALLS" | cut -d: -f1)
    enable_line=$(grep -n "systemctl --user enable --now rclone-onedrive.service" "$CALLS" | cut -d: -f1)
    [ -n "$reload_line" ] && [ -n "$enable_line" ]
    [ "$reload_line" -lt "$enable_line" ]
}

@test "fails loudly with journal lines when the mount never appears" {
    touch "$TMP/no_mount"
    run enable_rclone_mount_unit
    [ "$status" -ne 0 ]
    [[ "$output" == *"JOURNAL-LINE"* ]]
    grep -q "journalctl --user -u rclone-onedrive.service" "$CALLS"
}
