#!/usr/bin/env bats
#
# Unit tests for install_rclone / install_rclone_mount_unit (issue #360:
# replace Insync with an on-demand rclone mount).
#
# Strategy: throwaway $HOME, rclone/systemctl stubbed on PATH, no network,
# no root, no real ~/.config/rclone/ ever touched. install_rclone must never
# invoke `rclone config` (interactive, account-bound — operator work), and
# install_rclone_mount_unit must never invoke systemctl enable/start.
#
# Run locally: bats tests/

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP="$(mktemp -d)"
    HOME="$TMP/home"
    mkdir -p "$HOME"
    export HOME
    export LOG_FILE="$TMP/log"
    export RCLONE_LOG="$TMP/rclone_invocations.log"
    mkdir -p "$TMP/bin"
    export PATH="$TMP/bin:$PATH"

    # shellcheck source=../distro_config/install_lib/_common.sh
    source "$REPO_ROOT/distro_config/install_lib/_common.sh"
    PACKAGE_MANAGER="apt"

    # shellcheck source=../distro_config/install_lib/sharing.sh
    source "$REPO_ROOT/distro_config/install_lib/sharing.sh"
}

# rclone is on PATH on a machine that already has it installed (/usr/bin/rclone), so a test
# that needs "not installed" cannot rely on the stub directory being absent. Hide it
# explicitly, delegating every other name to the real check.
_hide_rclone() {
    command_exists() { [ "$1" = rclone ] && return 1; command -v "$1" &>/dev/null; }
}

teardown() {
    rm -rf "$TMP"
}

# refute_rclone_log PATTERN
# Asserts PATTERN never appears in the fake rclone's invocation log. NOT
# `! grep -q …`: bash exempts a `!`-inverted command from `set -e`, so such
# a line is not a real assertion unless it happens to be the test's last
# statement (issue #380).
refute_rclone_log() {
    run grep -q -- "$1" "$RCLONE_LOG"
    [ "$status" -ne 0 ]
}

# _write_rclone_stub [VERSION] — fake rclone reporting VERSION (default: new enough).
_write_rclone_stub() {
    local ver="${1:-1.75.2}"
    cat > "$TMP/bin/rclone" <<STUB
#!/bin/bash
echo "\$*" >> "$RCLONE_LOG"
case "\$1" in
    version) echo "rclone v$ver" ;;
    *) exit 0 ;;
esac
STUB
    chmod +x "$TMP/bin/rclone"
}

# --- install failure returns non-zero (#343 shape) ---------------------------

@test "install_rclone returns 1 when the package manager install fails" {
    _hide_rclone
    PACKAGE_MANAGER="dnf"
    INSTALL_CMD="false"
    run install_rclone
    [ "$status" -eq 1 ]
}

@test "install_rclone returns 1 when rclone is still not on PATH after a reported install" {
    _hide_rclone
    PACKAGE_MANAGER="dnf"
    INSTALL_CMD="true"
    run install_rclone
    [ "$status" -eq 1 ]
}

# --- install success path, and it never touches rclone config ---------------

@test "install_rclone succeeds and never invokes 'rclone config'" {
    _write_rclone_stub
    INSTALL_CMD="true"
    run install_rclone
    [ "$status" -eq 0 ]
    if [ -f "$RCLONE_LOG" ]; then
        refute_rclone_log '^config'
    fi
}

@test "install_rclone never writes anything under ~/.config/rclone" {
    _write_rclone_stub
    INSTALL_CMD="true"
    install_rclone
    [ ! -d "$HOME/.config/rclone" ]
}

@test "install_rclone is a no-op re-install when rclone already exists" {
    _write_rclone_stub
    INSTALL_CMD="false"
    run install_rclone
    [ "$status" -eq 0 ]
}

# --- issue #769: vendor .deb upgrade, checksum fail-closed -------------------

# _stub_vendor_env — fake dpkg/curl/sudo/apt-get; no network, no root. curl
# serves version.txt, SHA256SUMS ($SUMS_MODE: good|bad|missing|absent) and a
# fixed .deb body. sudo/apt-get only log their argv to $APT_LOG.
_stub_vendor_env() {
    export APT_LOG="$TMP/apt.log"
    export SUMS_MODE="${1:-good}"
    export DEB_BODY="fake-deb-body"
    local good
    good="$(printf '%s' "$DEB_BODY" | sha256sum | awk '{print $1}')"
    export GOOD_SHA="$good"
    printf '#!/bin/bash\necho amd64\n' > "$TMP/bin/dpkg"
    cat > "$TMP/bin/sudo" <<'STUB'
#!/bin/bash
echo "sudo $*" >> "$APT_LOG"
exec "$@"
STUB
    cat > "$TMP/bin/apt-get" <<'STUB'
#!/bin/bash
echo "apt-get $*" >> "$APT_LOG"
[ -n "$APT_POST" ] && eval "$APT_POST"
exit "${APT_RC:-0}"
STUB
    cat > "$TMP/bin/curl" <<'STUB'
#!/bin/bash
out=""; url=""
while [ $# -gt 0 ]; do
    case "$1" in -o) out="$2"; shift ;; -*) ;; *) url="$1" ;; esac
    shift
done
emit() { if [ -n "$out" ]; then printf '%s\n' "$1" > "$out"; else printf '%s\n' "$1"; fi; }
case "$url" in
    */version.txt) emit "rclone v9.9.9" ;;
    */SHA256SUMS)
        case "$SUMS_MODE" in
            good) emit "$GOOD_SHA  rclone-v9.9.9-linux-amd64.deb" ;;
            bad) emit "0000000000000000000000000000000000000000000000000000000000000000  rclone-v9.9.9-linux-amd64.deb" ;;
            missing) emit "$GOOD_SHA  rclone-v9.9.9-linux-arm64.deb" ;;
            absent) exit 22 ;;
        esac ;;
    *.deb) printf '%s' "$DEB_BODY" > "$out" ;;
    *) exit 22 ;;
esac
STUB
    chmod +x "$TMP/bin/dpkg" "$TMP/bin/sudo" "$TMP/bin/apt-get" "$TMP/bin/curl"
}

# _arm_upgrade — after the stubbed apt-get "installs", swap in a new rclone.
_arm_upgrade() {
    _write_rclone_stub "1.75.2"
    mv "$TMP/bin/rclone" "$TMP/rclone_new"
    _write_rclone_stub "1.60.1"
    export TMP APT_POST='cp "$TMP/rclone_new" "$TMP/bin/rclone"'
}

@test "install_rclone upgrades an old rclone from the vendor .deb and prints the reconnect hint" {
    _stub_vendor_env good
    _arm_upgrade
    run install_rclone
    [ "$status" -eq 0 ]
    grep -q 'apt-get install -y .*rclone-v9.9.9-linux-amd64.deb' "$APT_LOG"
    [[ "$output" == *"rclone config reconnect <remote>:"* ]]
    if [ -f "$RCLONE_LOG" ]; then
        refute_rclone_log '^config'
    fi
}

@test "install_rclone fails when an older rclone still shadows the upgrade" {
    _write_rclone_stub "1.60.1"
    _stub_vendor_env good
    run install_rclone
    [ "$status" -ne 0 ]
    [[ "$output" == *"shadows"* ]]
    [[ "$output" != *"rclone upgraded"* ]]
}

@test "install_rclone treats a non-zero apt-get as success when the new rclone landed" {
    _stub_vendor_env good
    _arm_upgrade
    export APT_RC=100
    run install_rclone
    [ "$status" -eq 0 ]
    [[ "$output" == *"unrelated package"* ]]
}

@test "install_rclone installs curl first when it is missing" {
    _write_rclone_stub "1.60.1"
    _stub_vendor_env good
    command_exists() { [ "$1" = curl ] && return 1; command -v "$1" &>/dev/null; }
    install_package() { echo "install_package $1" >> "$APT_LOG"; }
    run install_rclone
    grep -q '^install_package curl' "$APT_LOG"
}

@test "install_rclone skips the upgrade when rclone is new enough" {
    _write_rclone_stub "1.75.2"
    _stub_vendor_env good
    run install_rclone
    [ "$status" -eq 0 ]
    [ ! -f "$APT_LOG" ]
}

@test "install_rclone refuses on a checksum mismatch and never runs apt-get install" {
    _write_rclone_stub "1.60.1"
    _stub_vendor_env bad
    run install_rclone
    [ "$status" -ne 0 ]
    [[ "$output" == *"Checksum mismatch"* ]]
    [ ! -f "$APT_LOG" ]
}

@test "install_rclone refuses when the asset has no entry in SHA256SUMS" {
    _write_rclone_stub "1.60.1"
    _stub_vendor_env missing
    run install_rclone
    [ "$status" -ne 0 ]
    [ ! -f "$APT_LOG" ]
}

@test "install_rclone refuses when SHA256SUMS cannot be fetched" {
    _write_rclone_stub "1.60.1"
    _stub_vendor_env absent
    run install_rclone
    [ "$status" -ne 0 ]
    [ ! -f "$APT_LOG" ]
}

@test "install_rclone on a non-apt distro warns about an old rclone but keeps it" {
    _write_rclone_stub "1.60.1"
    PACKAGE_MANAGER="dnf"
    INSTALL_CMD="false"
    run install_rclone
    [ "$status" -eq 0 ]
    [[ "$output" == *"older than $RCLONE_MIN_VERSION"* ]]
}

# --- registry entry shape (#357: CLI tool, empty gnome_folder/desktop_file) --

@test "INSTALL_REGISTRY has an install_rclone entry with empty folder and desktop fields" {
    local entry fn label folder desktop found=0
    for entry in "${INSTALL_REGISTRY[@]}"; do
        if [[ "$entry" == install_rclone:* ]]; then
            found=1
            IFS=':' read -r fn label folder desktop <<< "$entry"
            [ -z "$folder" ]
            [ -z "$desktop" ]
        fi
    done
    [ "$found" -eq 1 ]
}

@test "validate_registry passes with install_rclone registered" {
    run validate_registry
    [ "$status" -eq 0 ]
}

# --- install_rclone_mount_unit: writes but never enables/starts -------------

@test "install_rclone_mount_unit refuses without remote or mountpoint" {
    _write_rclone_stub
    run install_rclone_mount_unit "" ""
    [ "$status" -ne 0 ]
}

@test "install_rclone_mount_unit refuses when rclone is not installed" {
    _hide_rclone
    run install_rclone_mount_unit "gdrive" "$HOME/GoogleDrive"
    [ "$status" -ne 0 ]
}

@test "install_rclone_mount_unit refuses to target ~/Insync as the mountpoint" {
    _write_rclone_stub
    run install_rclone_mount_unit "gdrive" "$HOME/Insync"
    [ "$status" -ne 0 ]
}

@test "install_rclone_mount_unit writes the unit with remote and mountpoint substituted" {
    _write_rclone_stub
    mkdir -p "$HOME/GoogleDrive"
    install_rclone_mount_unit "gdrive" "$HOME/GoogleDrive"

    local unit="$HOME/.config/systemd/user/rclone-gdrive.service"
    [ -f "$unit" ]
    grep -qF "rclone mount gdrive: $HOME/GoogleDrive" "$unit"
    # The directives (from [Unit] onward) are fully substituted; the header
    # comments above them deliberately keep the literal placeholders (#365
    # — asserted separately below).
    local directives
    directives="$(sed -n '/^\[Unit\]/,$p' "$unit")"
    [[ "$directives" != *'{{'* ]]
}

@test "install_rclone_mount_unit never enables or starts the unit" {
    cat > "$TMP/bin/systemctl" <<STUB
#!/bin/bash
echo "\$*" >> "$TMP/systemctl_invocations.log"
STUB
    chmod +x "$TMP/bin/systemctl"
    _write_rclone_stub
    mkdir -p "$HOME/GoogleDrive"

    install_rclone_mount_unit "gdrive" "$HOME/GoogleDrive"

    [ ! -f "$TMP/systemctl_invocations.log" ]
}

# --- issue #365: default mount point, folder creation, non-empty refusal ---

@test "install_rclone_mount_unit creates the mount point folder when absent" {
    _write_rclone_stub
    [ ! -d "$HOME/OneDrive" ]

    run install_rclone_mount_unit "onedrive" "$HOME/OneDrive"

    [ "$status" -eq 0 ]
    [ -d "$HOME/OneDrive" ]
    [ -f "$HOME/.config/systemd/user/rclone-onedrive.service" ]
}

@test "install_rclone_mount_unit refuses when the mount point exists and is non-empty" {
    _write_rclone_stub
    mkdir -p "$HOME/OneDrive"
    echo "keep me" > "$HOME/OneDrive/existing-file.txt"

    run install_rclone_mount_unit "onedrive" "$HOME/OneDrive"

    [ "$status" -ne 0 ]
    [[ "$output" == *"not empty"* ]]
    [ -f "$HOME/OneDrive/existing-file.txt" ]
    [ ! -f "$HOME/.config/systemd/user/rclone-onedrive.service" ]
}

@test "install_rclone_mount_unit falls back to RCLONE_REMOTE and RCLONE_MOUNT_POINT env vars" {
    _write_rclone_stub
    export RCLONE_REMOTE="workdrive"
    export RCLONE_MOUNT_POINT="$HOME/WorkDrive"

    run install_rclone_mount_unit

    [ "$status" -eq 0 ]
    [ -d "$HOME/WorkDrive" ]
    local unit="$HOME/.config/systemd/user/rclone-workdrive.service"
    [ -f "$unit" ]
    grep -qF "rclone mount workdrive: $HOME/WorkDrive" "$unit"
}

@test "install_rclone_mount_unit default with no args and no env vars uses onedrive / ~/OneDrive" {
    _write_rclone_stub

    run install_rclone_mount_unit

    [ "$status" -eq 0 ]
    [ -d "$HOME/OneDrive" ]
    [ -f "$HOME/.config/systemd/user/rclone-onedrive.service" ]
}

@test "install_rclone_mount_unit keeps the header placeholders literal after substitution" {
    _write_rclone_stub

    install_rclone_mount_unit "onedrive" "$HOME/OneDrive"

    local unit="$HOME/.config/systemd/user/rclone-onedrive.service"
    local header
    header="$(sed -n '1,/^\[Unit\]/p' "$unit")"
    [[ "$header" == *"{{REMOTE}}"* ]]
    [[ "$header" == *"{{MOUNTPOINT}}"* ]]
    grep -qF "AssertPathIsDirectory=$HOME/OneDrive" "$unit"
    grep -qF "Description=rclone on-demand mount: onedrive" "$unit"
}

# --- issue #365: rclone.conf skeleton, mode 600, no overwrite, reconnect ----

@test "install_rclone_config writes the skeleton with mode 600" {
    _write_rclone_stub

    run install_rclone_config "onedrive" "onedrive" "global" < /dev/null

    [ "$status" -eq 0 ]
    local conf="$HOME/.config/rclone/rclone.conf"
    [ -f "$conf" ]
    grep -qF "[onedrive]" "$conf"
    grep -qF "type = onedrive" "$conf"
    grep -qF "region = global" "$conf"
    [ "$(stat -c '%a' "$conf")" = "600" ]
}

@test "install_rclone_config refuses to overwrite an existing rclone.conf" {
    _write_rclone_stub
    mkdir -p "$HOME/.config/rclone"
    printf '[onedrive]\ntype = onedrive\ntoken = {"already":"configured"}\n' \
        > "$HOME/.config/rclone/rclone.conf"

    run install_rclone_config "onedrive" < /dev/null

    [ "$status" -ne 0 ]
    grep -qF 'token' "$HOME/.config/rclone/rclone.conf"
}

@test "install_rclone_config skips the browser reconnect and prints the command when not interactive" {
    _write_rclone_stub

    run install_rclone_config "onedrive" < /dev/null

    [ "$status" -eq 0 ]
    [[ "$output" == *"rclone config reconnect onedrive:"* ]]
    if [ -f "$RCLONE_LOG" ]; then
        refute_rclone_log '^config reconnect'
    fi
}

@test "install_rclone_config invokes only 'rclone config reconnect', never the bare wizard" {
    # The bare 'rclone config' wizard is what offers "set configuration
    # password", which the systemd mount cannot unlock at boot (#365).
    local fn
    fn="$(sed -n '/^install_rclone_config()/,/^}/p' "$REPO_ROOT/distro_config/install_lib/sharing.sh")"
    [[ "$fn" == *'rclone config reconnect'* ]]
    [[ "$fn" != *'run_or_echo rclone config"'* ]]
}
