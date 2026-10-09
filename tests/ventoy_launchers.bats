#!/usr/bin/env bats
#
# Unit tests for distro_config/ventoy/ventoy-launcher.sh (issue #691): the disk
# resolvers and the command line each wrapper builds.
#
# Strategy: lsblk/findmnt are stubbed on PATH, DRY_RUN=1 for the wrappers, so no
# real disk is read, sudo is never run, and Plugson never starts.
#
# Run locally: bats tests/

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    LAUNCHER="$REPO_ROOT/distro_config/ventoy/ventoy-launcher.sh"
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/bin"
    export PATH="$TMP/bin:$PATH"
    export HOME="$TMP/home"
    export DRY_RUN=1

    # lsblk stub: `-rno LABEL,PKNAME` lists every partition ($LSBLK_ALL);
    # `-rno LABEL,PKNAME <dev>` answers for one device ($LSBLK_DEV).
    cat > "$TMP/bin/lsblk" <<'STUB'
#!/bin/bash
case "${*: -1}" in
    /dev/*) printf '%b' "$LSBLK_DEV" ;;
    *) printf '%b' "$LSBLK_ALL" ;;
esac
STUB
    cat > "$TMP/bin/findmnt" <<'STUB'
#!/bin/bash
echo "${FINDMNT_SRC:-/dev/sde1}"
STUB
    # stat stub: ownership/mode of every path checked before sudo ("uid mode").
    # $STAT_OUT answers for the script, $STAT_DIR_OUT (default: same) for its directory.
    cat > "$TMP/bin/stat" <<'STUB'
#!/bin/bash
case "${*: -1}" in
    *.sh) echo "${STAT_OUT:-0 755}" ;;
    *) echo "${STAT_DIR_OUT:-${STAT_OUT:-0 755}}" ;;
esac
STUB
    chmod +x "$TMP/bin/lsblk" "$TMP/bin/findmnt" "$TMP/bin/stat"
    ln -s "$LAUNCHER" "$TMP/bin/ventoy-web"
    ln -s "$LAUNCHER" "$TMP/bin/ventoy-plugson"

    # shellcheck source=../distro_config/ventoy/ventoy-launcher.sh
    source "$LAUNCHER"
}

teardown() {
    rm -rf "$TMP"
}

@test "ventoy_find_disk returns the parent disk of the one Ventoy partition" {
    LSBLK_ALL='VTOYEFI sde\nVentoy sde\n boot sda\n'
    export LSBLK_ALL
    run ventoy_find_disk
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/sde" ]
}

@test "ventoy_find_disk refuses when no partition is labelled Ventoy" {
    export LSBLK_ALL='boot sda\nVTOYEFI sde\n'
    run ventoy_find_disk
    [ "$status" -ne 0 ]
    [[ "$output" == *"No partition labelled 'Ventoy'"* ]]
}

@test "ventoy_find_disk refuses when two disks carry a Ventoy partition" {
    export LSBLK_ALL='Ventoy sde\nVentoy sdf\n'
    run ventoy_find_disk
    [ "$status" -ne 0 ]
    [[ "$output" == *"Several Ventoy disks"* ]]
}

@test "ventoy_disk_of_mount resolves the disk of a Ventoy mount" {
    export LSBLK_DEV='Ventoy sde\n'
    run ventoy_disk_of_mount /media/user/Ventoy
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/sde" ]
}

@test "ventoy_disk_of_mount refuses a mount that is not a Ventoy partition" {
    export FINDMNT_SRC=/dev/sda2 LSBLK_DEV='rootfs sda\n'
    run ventoy_disk_of_mount /
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a Ventoy data partition"* ]]
}

@test "ventoy-web dry-run builds the VentoyWeb command and opens :24680" {
    run ventoy-web
    [ "$status" -eq 0 ]
    [[ "$output" == *"[dry-run] xdg-open http://127.0.0.1:24680"* ]]
    [[ "$output" == *"[dry-run] cd /opt/ventoy"* ]]
    [[ "$output" == *"[dry-run] sudo bash ./VentoyWeb.sh"* ]]
}

@test "ventoy-plugson dry-run resolves the disk and opens :24681" {
    export LSBLK_ALL='Ventoy sde\n'
    run ventoy-plugson
    [ "$status" -eq 0 ]
    [[ "$output" == *"[dry-run] xdg-open http://127.0.0.1:24681"* ]]
    [[ "$output" == *"[dry-run] sudo bash ./VentoyPlugson.sh /dev/sde"* ]]
}

@test "ventoy-plugson takes an explicit disk without calling lsblk" {
    run ventoy-plugson /dev/sdz
    [ "$status" -eq 0 ]
    [[ "$output" == *"sudo bash ./VentoyPlugson.sh /dev/sdz"* ]]
}

@test "ventoy-plugson refuses a disk argument outside /dev/" {
    run ventoy-plugson --help
    [ "$status" -ne 0 ]
    [[ "$output" == *"Pass the Ventoy disk as /dev/sdX."* ]]
    [[ "$output" != *"VentoyPlugson.sh"* ]]
}

@test "ventoy-plugson refuses a /dev/ path that is not a block device outside DRY_RUN" {
    run env DRY_RUN=0 "$TMP/bin/ventoy-plugson" /dev/null
    [ "$status" -ne 0 ]
    [[ "$output" == *"/dev/null is not a block device."* ]]
}

@test "ventoy-plugson --install-launcher copies the opener onto the stick" {
    export LSBLK_DEV='Ventoy sde\n'
    run ventoy-plugson --install-launcher "$TMP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[dry-run] install -m 755 "*"ventoy-pendrive-launcher.sh $TMP/ventoy-plugson.sh"* ]]
}

@test "ventoy-plugson --install-launcher refuses a non-Ventoy mount" {
    export FINDMNT_SRC=/dev/sda2 LSBLK_DEV='rootfs sda\n'
    run ventoy-plugson --install-launcher "$TMP"
    [ "$status" -ne 0 ]
}

@test "ventoy-web refuses a user-owned script before any sudo" {
    export STAT_OUT='1000 755'
    run ventoy-web
    [ "$status" -ne 0 ]
    [[ "$output" == *"Refusing to run /opt/ventoy/VentoyWeb.sh as root"* ]]
    [[ "$output" == *"sudo chown -R root:root /opt/ventoy"* ]]
    [[ "$output" != *"sudo bash"* ]]
}

@test "ventoy-plugson refuses a root-owned but group-writable script" {
    export LSBLK_ALL='Ventoy sde\n' STAT_OUT='0 775'
    run ventoy-plugson
    [ "$status" -ne 0 ]
    [[ "$output" == *"not group/world-writable"* ]]
    [[ "$output" != *"sudo bash"* ]]
}

@test "ventoy-web refuses a user-owned directory even when the script is root-owned" {
    export STAT_OUT='0 755' STAT_DIR_OUT='1000 755'
    run ventoy-web
    [ "$status" -ne 0 ]
    [[ "$output" == *"Refusing to run /opt/ventoy/VentoyWeb.sh as root: /opt/ventoy must be owned by root"* ]]
    [[ "$output" != *"sudo bash"* ]]
}

@test "ventoy-web authenticates sudo before opening the browser" {
    run ventoy-web
    [ "$status" -eq 0 ]
    [[ "$output" =~ sudo\ -v.*xdg-open ]]
}

@test "ventoy-web refuses a world-writable script with a 4-digit mode" {
    export STAT_OUT='0 1777'
    run ventoy-web
    [ "$status" -ne 0 ]
}

@test "VENTOY_DIR from the environment is ignored, even under DRY_RUN" {
    run env DRY_RUN=1 VENTOY_DIR=/tmp/evil "$TMP/bin/ventoy-web"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cd /opt/ventoy"* ]]
    [[ "$output" != *"/tmp/evil"* ]]
}

@test "VENTOY_TEST_DIR is ignored outside DRY_RUN" {
    run env DRY_RUN=0 VENTOY_TEST_DIR=/tmp/evil bash -c "source '$LAUNCHER'; echo \$VENTOY_DIR"
    [ "$output" = "/opt/ventoy" ]
}

@test "VENTOY_TEST_DIR is honoured under DRY_RUN" {
    export VENTOY_TEST_DIR=/tmp/fixture
    run ventoy-web
    [[ "$output" == *"[dry-run] cd /tmp/fixture"* ]]
}

# --- install_ventoy: verified download only, never a copy from $HOME --------

# Source vm.sh, stub curl: the API URL answers $RELEASE_JSON, any other URL is
# served from $FIX/<basename>. Fixture tarball + sha256.txt are built here.
_setup_install() {
    export LOG_FILE="$TMP/log" PACKAGE_MANAGER=apt
    FIX="$TMP/fix"
    mkdir -p "$FIX"
    echo payload > "$FIX/ventoy-1.0-linux.tar.gz"
    echo "$(sha256sum "$FIX/ventoy-1.0-linux.tar.gz" | cut -d' ' -f1)  ventoy-1.0-linux.tar.gz" > "$FIX/sha256.txt"
    export FIX
    cat > "$TMP/bin/curl" <<'STUB'
#!/bin/bash
out=; url=
while [ $# -gt 0 ]; do
    case "$1" in -o) out=$2; shift ;; http*) url=$1 ;; esac
    shift
done
if [ -z "$out" ]; then printf '%s\n' "$RELEASE_JSON"; exit 0; fi
cp "$FIX/${url##*/}" "$out"
STUB
    chmod +x "$TMP/bin/curl"
    export RELEASE_JSON='"browser_download_url": "https://x/ventoy-1.0-linux.tar.gz"
"browser_download_url": "https://x/sha256.txt"'
    # shellcheck source=../distro_config/install_lib/_common.sh
    source "$REPO_ROOT/distro_config/install_lib/_common.sh"
    # shellcheck source=../distro_config/install_lib/vm.sh
    source "$REPO_ROOT/distro_config/install_lib/vm.sh"
    VENTOY_DIR_ROOT="$TMP/opt-ventoy"
}

@test "install_ventoy extracts only after the checksum matches" {
    _setup_install
    run install_ventoy
    [ "$status" -eq 0 ]
    [[ "$output" == *"[dry-run] sudo tar -xzf $TMP/opt-ventoy.tar.gz -C $TMP/opt-ventoy --strip-components=2 --no-same-owner"* ]]
}

# Real (non-dry-run) path with a recording sudo stub: `install` is emulated as a
# copy (after which $SWAP_AFTER_INSTALL=1 overwrites the user-owned source, as an
# attacker racing the download would); everything else is only logged.
_stub_sudo() {
    export DRY_RUN=0 SUDO_LOG="$TMP/sudo.log"
    cat > "$TMP/bin/sudo" <<'STUB'
#!/bin/bash
echo "$*" >> "$SUDO_LOG"
if [ "$1" = install ]; then
    [ -z "${FAIL_INSTALL:-}" ] || { : > "$9"; exit 1; }
    cp "$8" "$9"
    [ -z "${SWAP_AFTER_INSTALL:-}" ] || echo evil > "$8"
fi
exit 0
STUB
    chmod +x "$TMP/bin/sudo"
}

@test "the tarball is staged root-owned, verified there, and extracted from there" {
    _setup_install
    _stub_sudo
    SWAP_AFTER_INSTALL=1 run install_ventoy
    [[ "$output" != *"Checksum mismatch"* ]]
    local stage="$TMP/opt-ventoy.tar.gz" log
    log=$(< "$SUDO_LOG")
    [[ "$log" == *"install -m 644 -o root -g root "*"/ventoy.tar.gz $stage"* ]]
    [[ "$log" == *"tar -xzf $stage -C $TMP/opt-ventoy --strip-components=2 --no-same-owner"* ]]
    # install, then tar, then the stage is removed -- in that order
    [[ "$log" =~ install.*tar\ -xzf.*rm\ -f\ $stage ]]
}

@test "a failed stage copy removes the stage file and never extracts" {
    _setup_install
    _stub_sudo
    FAIL_INSTALL=1 run install_ventoy
    [ "$status" -ne 0 ]
    [[ "$(< "$SUDO_LOG")" == *"rm -f $TMP/opt-ventoy.tar.gz"* ]]
    [[ "$(< "$SUDO_LOG")" != *"tar -xzf"* ]]
}

@test "a checksum mismatch removes the staged copy" {
    _setup_install
    _stub_sudo
    echo "$(printf 'bad' | sha256sum | cut -d' ' -f1)  ventoy-1.0-linux.tar.gz" > "$FIX/sha256.txt"
    run install_ventoy
    [ "$status" -ne 0 ]
    [[ "$(< "$SUDO_LOG")" == *"rm -f $TMP/opt-ventoy.tar.gz"* ]]
    [[ "$(< "$SUDO_LOG")" != *"tar -xzf"* ]]
}

@test "install_ventoy refuses to extract on a checksum mismatch" {
    _setup_install
    echo "$(printf 'bad' | sha256sum | cut -d' ' -f1)  ventoy-1.0-linux.tar.gz" > "$FIX/sha256.txt"
    run install_ventoy
    [ "$status" -ne 0 ]
    [[ "$output" == *"Checksum mismatch"* ]]
    [[ "$output" != *"sudo tar"* ]]
}

@test "install_ventoy refuses when the release has no sha256.txt asset" {
    _setup_install
    export RELEASE_JSON='"browser_download_url": "https://x/ventoy-1.0-linux.tar.gz"'
    run install_ventoy
    [ "$status" -ne 0 ]
    [[ "$output" == *"No sha256.txt"* ]]
    [[ "$output" != *"sudo tar"* ]]
}

@test "install_ventoy refuses when sha256.txt has no entry for the tarball" {
    _setup_install
    echo "abc  other.tar.gz" > "$FIX/sha256.txt"
    run install_ventoy
    [ "$status" -ne 0 ]
    [[ "$output" == *"has no entry for ventoy-1.0-linux.tar.gz"* ]]
    [[ "$output" != *"sudo tar"* ]]
}

@test "a legacy-only install triggers a fresh download, never a copy into /opt" {
    _setup_install
    mkdir -p "$HOME/.local/share/ventoy"
    touch "$HOME/.local/share/ventoy/VentoyGUI.x86_64"
    run install_ventoy
    [ "$status" -eq 0 ]
    [[ "$output" == *"no longer used"* ]]
    [[ "$output" == *"Downloading Ventoy"* ]]
    [[ "$output" == *"sudo tar -xzf"* ]]
    [[ "$output" != *"already installed"* ]]
    [[ "$output" != *" cp "* ]]
    [[ "$output" != *"$HOME/.local/share/ventoy/."* ]]
}

@test "a root-owned /opt install counts as installed; a user-owned one does not" {
    _setup_install
    mkdir -p "$VENTOY_DIR_ROOT"
    touch "$VENTOY_DIR_ROOT/VentoyGUI.x86_64"
    run install_ventoy
    [[ "$output" == *"already installed"* ]]
    STAT_OUT='1000 755' run install_ventoy
    [[ "$output" != *"already installed"* ]]
    [[ "$output" == *"Downloading Ventoy"* ]]
}

@test "vm.sh has no copy from the user tree into the root dir" {
    run grep -nE '_ventoy_migrate_legacy|cp -a' "$REPO_ROOT/distro_config/install_lib/vm.sh"
    [ "$status" -ne 0 ]
}

@test "the pendrive opener calls ventoy-plugson by absolute path only" {
    local opener="$REPO_ROOT/distro_config/ventoy/ventoy-pendrive-launcher.sh"
    grep -q '^VENTOY_PLUGSON=/usr/local/bin/ventoy-plugson$' "$opener"
    grep -q 'exec "\$VENTOY_PLUGSON"' "$opener"
    run grep -nE '(^|[^/A-Z_])ventoy-plugson "' "$opener"
    [ "$status" -ne 0 ]
}

@test "_check_tree refuses a group/world-writable file inside the Ventoy tree" {
    mkdir -p "$TMP/tree/tool"
    touch "$TMP/tree/tool/ventoy_lib.sh"
    chmod 666 "$TMP/tree/tool/ventoy_lib.sh"
    run _check_tree "$TMP/tree"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Refusing to run as root"* ]]
}

@test "--install-launcher decodes an lsblk-escaped space in the mountpoint" {
    export LSBLK_ALL='Ventoy sde\n' LSBLK_DEV='Ventoy /mnt/my\\x20stick\n'
    run ventoy-plugson --install-launcher
    [ "$status" -eq 0 ]
    [[ "$output" == *"/mnt/my stick/ventoy-plugson.sh"* ]]
}
