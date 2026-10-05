#!/usr/bin/env bats
#
# Unit tests for issue #649: install_rclone_mount_unit is idempotent on a live
# mount, and run_rclone_followups enables the mount without prompting.
#
# Throwaway $HOME; rclone, systemctl and mountpoint are stubs on PATH, so the
# real user systemd, the real remote and the real ~/OneDrive are never touched.
# State files under $TMP drive the stubs: `mounted` (mountpoint -q succeeds)
# and `active` (systemctl is-active succeeds).

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP="$(mktemp -d)"
    HOME="$TMP/home"
    mkdir -p "$HOME/.config/systemd/user" "$HOME/OneDrive" "$TMP/bin"
    export HOME TMP
    export LOG_FILE="$TMP/log"
    export CALLS="$TMP/calls.log"
    export PATH="$TMP/bin:$PATH"
    UNIT="$HOME/.config/systemd/user/rclone-onedrive.service"

    printf '#!/bin/bash\nexit 0\n' > "$TMP/bin/rclone"
    cat > "$TMP/bin/systemctl" <<'STUB'
#!/bin/bash
echo "systemctl $*" >> "$CALLS"
case "$2" in
    is-active) [ -e "$TMP/active" ] ;;
    *) exit 0 ;;
esac
STUB
    printf '#!/bin/bash\n[ -e "$TMP/mounted" ]\n' > "$TMP/bin/mountpoint"
    chmod +x "$TMP"/bin/*

    # shellcheck source=../distro_config/install_lib/_common.sh
    source "$REPO_ROOT/distro_config/install_lib/_common.sh"
    # shellcheck source=../distro_config/install_lib/sharing.sh
    source "$REPO_ROOT/distro_config/install_lib/sharing.sh"
}

teardown() {
    rm -rf "$TMP"
}

go_live() {
    touch "$TMP/mounted" "$TMP/active"
    touch "$HOME/OneDrive/Documents"
}

@test "install unit returns 0 and leaves the unit untouched when already mounted" {
    install_rclone_mount_unit
    go_live
    before="$(cat "$UNIT")"
    touch -d '2000-01-01' "$UNIT"
    run install_rclone_mount_unit
    [ "$status" -eq 0 ]
    [[ "$output" == *"already mounted"* ]]
    [ "$(cat "$UNIT")" = "$before" ]
    [ "$(date -r "$UNIT" +%Y)" = "2000" ]
}

@test "install unit rewrites a stale unit while mounted, still returning 0" {
    install_rclone_mount_unit
    go_live
    echo "# stale" > "$UNIT"
    run install_rclone_mount_unit
    [ "$status" -eq 0 ]
    grep -q "ExecStart" "$UNIT"
}

@test "comment-only change while mounted rewrites silently, no restart hint (#651)" {
    install_rclone_mount_unit
    go_live
    sed -i '1s/.*/# a different header comment/' "$UNIT"
    echo "# trailing comment" >> "$UNIT"
    run install_rclone_mount_unit
    [ "$status" -eq 0 ]
    [[ "$output" == *"updated comments only"* ]]
    [[ "$output" != *"restart"* ]]
    run grep -q "a different header comment" "$UNIT"
    [ "$status" -ne 0 ]
}

@test "changed ExecStart while mounted still prints the restart hint (#651)" {
    install_rclone_mount_unit
    go_live
    sed -i 's|^ExecStart=.*|ExecStart=/bin/false|' "$UNIT"
    run install_rclone_mount_unit
    [ "$status" -eq 0 ]
    [[ "$output" == *"systemctl --user restart rclone-onedrive.service"* ]]
    run grep -q "/bin/false" "$UNIT"
    [ "$status" -ne 0 ]
}

@test "identical unit while mounted reports already up to date (#651)" {
    install_rclone_mount_unit
    go_live
    run install_rclone_mount_unit
    [ "$status" -eq 0 ]
    [[ "$output" == *"already up to date"* ]]
}

@test "install unit still refuses a non-empty directory that is not a live mount" {
    touch "$HOME/OneDrive/precious.txt"
    run install_rclone_mount_unit
    [ "$status" -ne 0 ]
    [[ "$output" == *"not empty"* ]]
    [ ! -e "$UNIT" ]
}

@test "install unit refuses a non-empty directory when mounted but unit inactive" {
    touch "$TMP/mounted" "$HOME/OneDrive/Documents"
    run install_rclone_mount_unit
    [ "$status" -ne 0 ]
    [[ "$output" == *"not empty"* ]]
}

# --- run_rclone_followups (install_programs.sh is not sourceable: it runs a
# menu, so lift just the function out of it) --------------------------------

load_followups() {
    eval "$(sed -n '/^run_rclone_followups() {/,/^}/p' "$REPO_ROOT/distro_config/install_programs.sh")"
    install_rclone_config() { :; }
    install_rclone_mount_unit() { :; }
}

@test "followups call the enable step without reading stdin" {
    load_followups
    enable_rclone_mount_unit() { echo called >> "$CALLS"; }
    run run_rclone_followups < /dev/null
    [ "$status" -eq 0 ]
    grep -q called "$CALLS"
}

@test "followups survive a refused enable and keep going" {
    load_followups
    enable_rclone_mount_unit() { echo "refused"; return 1; }
    run run_rclone_followups < /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"make rclone_mount"* ]]
}
