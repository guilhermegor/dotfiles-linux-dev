#!/bin/bash
#
# ventoy-launcher.sh
#
# One script, installed twice by install_ventoy (distro_config/install_lib/vm.sh)
# as `ventoy-web` and `ventoy-plugson`; behaviour follows the invoked name.
#
#   ventoy-web                           installer web UI   (:24680)
#   ventoy-plugson [/dev/sdX]            pendrive config UI (:24681); no arg =
#                                        the disk holding the "Ventoy" partition
#   ventoy-plugson --install-launcher [mountpoint]
#                                        drop the per-pendrive opener onto the
#                                        Ventoy data partition
#
# Ventoy's scripts expect cwd = their own directory, so each runs from VENTOY_DIR.
# They run under sudo, so VENTOY_DIR is fixed to the root-owned /opt/ventoy and the
# script plus its directory must be root-owned and not group/world-writable. The only
# override is VENTOY_TEST_DIR, honoured under DRY_RUN=1 (tests); the environment can
# never choose which script runs as root.
# DRY_RUN=1 prints the command lines instead of running them (the run_or_echo
# convention of lib/common.sh, inlined because this file is installed standalone).
#
# Sourced (not executed) it only defines the resolvers, which the bats tests use.

VENTOY_DIR=/opt/ventoy
[ "${DRY_RUN:-0}" = "1" ] && VENTOY_DIR="${VENTOY_TEST_DIR:-$VENTOY_DIR}"
VENTOY_OPENER="${VENTOY_OPENER:-$(dirname "${BASH_SOURCE[0]}")/ventoy-pendrive-launcher.sh}"

_run() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        echo "[dry-run] $*"
        return 0
    fi
    "$@"
}

# Print /dev/<parent disk> of the one partition labelled Ventoy; fail on 0 or >1.
ventoy_find_disk() {
    local disks
    mapfile -t disks < <(lsblk -rno LABEL,PKNAME | awk '$1=="Ventoy" && $2!=""{print "/dev/"$2}' | sort -u)
    if [ "${#disks[@]}" -eq 0 ]; then
        echo "No partition labelled 'Ventoy' found. Plug the pendrive in or pass /dev/sdX." >&2
        return 1
    fi
    if [ "${#disks[@]}" -gt 1 ]; then
        echo "Several Ventoy disks found (${disks[*]}). Pass the one you want: ventoy-plugson /dev/sdX" >&2
        return 1
    fi
    echo "${disks[0]}"
}

# Print /dev/<parent disk> of the Ventoy partition mounted at $1; fail otherwise.
ventoy_disk_of_mount() {
    local src label parent
    src=$(findmnt -no SOURCE --target "$1") || return 1
    read -r label parent < <(lsblk -rno LABEL,PKNAME "$src")
    if [ "$label" != "Ventoy" ] || [ -z "$parent" ]; then
        echo "$1 is not a Ventoy data partition." >&2
        return 1
    fi
    echo "/dev/$parent"
}

# Open the UI once the server has had a moment to bind its port.
_open_browser() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        echo "[dry-run] xdg-open $1"
    else
        (sleep 2; xdg-open "$1" >/dev/null 2>&1) &
    fi
}

# Refuse unless $1 and its directory are root-owned and not group/world-writable.
_check_trusted() {
    local path owner mode
    for path in "$1" "$(dirname "$1")"; do
        read -r owner mode < <(stat -c '%u %a' "$path") || owner=
        if [ "$owner" != "0" ] || (( 8#${mode:-777} & 8#022 )); then
            echo "Refusing to run $1 as root: $path must be owned by root and not group/world-writable." >&2
            echo "Fix: sudo chown -R root:root $VENTOY_DIR && sudo chmod -R go-w $VENTOY_DIR" >&2
            return 1
        fi
    done
}

_serve() { # <script> <port> [disk]
    local script=$1 port=$2 disk=${3:-}
    if [ "${DRY_RUN:-0}" != "1" ] && [ ! -f "$VENTOY_DIR/$script" ]; then
        echo "$VENTOY_DIR/$script missing. Install Ventoy: make install_programs" >&2
        return 1
    fi
    _check_trusted "$VENTOY_DIR/$script" || return 1
    # Authenticate first: the browser opens after 2s and must not beat the password prompt.
    _run sudo -v || return 1
    _open_browser "http://127.0.0.1:$port"
    _run cd "$VENTOY_DIR" || return 1
    _run sudo bash "./$script" ${disk:+"$disk"}
}

_install_launcher() { # [mountpoint]
    local mp=${1:-} disk
    if [ -z "$mp" ]; then
        disk=$(ventoy_find_disk) || return 1
        mp=$(lsblk -rno LABEL,MOUNTPOINT "${disk}"* | awk '$1=="Ventoy" && $2!=""{print $2; exit}')
        [ -n "$mp" ] || { echo "The Ventoy partition on $disk is not mounted." >&2; return 1; }
    fi
    ventoy_disk_of_mount "$mp" >/dev/null || return 1
    _run install -m 755 "$VENTOY_OPENER" "$mp/ventoy-plugson.sh"
}

main() {
    case "$(basename "$0")" in
        ventoy-web)
            _serve VentoyWeb.sh 24680
            ;;
        ventoy-plugson)
            if [ "${1:-}" = "--install-launcher" ]; then
                _install_launcher "${2:-}"
                return
            fi
            local disk=${1:-}
            [ -n "$disk" ] || disk=$(ventoy_find_disk) || return 1
            # The disk reaches a root-run script: only a /dev/ block device
            # (an option-like or relative argument is refused).
            case "$disk" in
                /dev/*) ;;
                *) echo "Pass the Ventoy disk as /dev/sdX." >&2; return 1 ;;
            esac
            if [ ! -b "$disk" ] && [ "${DRY_RUN:-0}" != "1" ]; then
                echo "$disk is not a block device." >&2
                return 1
            fi
            _serve VentoyPlugson.sh 24681 "$disk"
            ;;
        *)
            echo "Run via the ventoy-web or ventoy-plugson name." >&2
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
