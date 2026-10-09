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
    chmod +x "$TMP/bin/lsblk" "$TMP/bin/findmnt"
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
    [[ "$output" == *"[dry-run] cd $HOME/.local/share/ventoy"* ]]
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
