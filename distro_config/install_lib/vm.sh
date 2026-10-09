#!/bin/bash
#
# distro_config/install_lib/vm.sh
#
# Virtualization & USB-imaging tools. Sourced by install_programs.sh.
# Depends on: print_status, command_exists, $LOG_FILE

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "vm.sh is meant to be sourced, not executed." >&2
    exit 1
fi

# ============================================================================
# INSTALL FUNCTIONS
# ============================================================================

install_virtual_machine_manager() {
    print_status "section" "VIRTUAL MACHINE MANAGER"

    if command_exists virt-manager; then
        print_status "info" "Virtual Machine Manager already installed"
        return 0
    fi

    print_status "info" "Installing Virtual Machine Manager..."
    run_or_echo sudo apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virtinst virt-manager
    run_or_echo sudo systemctl enable --now libvirtd

    print_status "success" "Virtual Machine Manager installed"
}

install_balena_etcher() {
    print_status "section" "BALENA ETCHER"

    if command_exists balena-etcher; then
        print_status "info" "Balena Etcher already installed"
        return 0
    fi

    local arch
    arch=$(dpkg --print-architecture 2>/dev/null || echo "amd64")

    print_status "info" "Fetching latest Balena Etcher release..."
    local release_json
    release_json=$(curl -s "https://api.github.com/repos/balena-io/etcher/releases/latest")

    local deb_url
    deb_url=$(echo "$release_json" | grep "browser_download_url" | grep "${arch}\.deb" | head -n 1 | cut -d '"' -f 4)

    if [ -n "$deb_url" ] && [ "$deb_url" != "null" ]; then
        local tmp_dir
        tmp_dir=$(mktemp -d)
        print_status "info" "Downloading Balena Etcher .deb..."
        if wget -q -O "$tmp_dir/balena-etcher.deb" "$deb_url" 2>>"$LOG_FILE" || \
           curl -sL -o "$tmp_dir/balena-etcher.deb" "$deb_url" 2>>"$LOG_FILE"; then
            run_or_echo sudo apt-get install -y "$tmp_dir/balena-etcher.deb" 2>>"$LOG_FILE"
            print_status "success" "Balena Etcher installed from official .deb"
        else
            print_status "warning" "Download failed. Visit https://etcher.balena.io"
            rm -rf "$tmp_dir"
            return 1
        fi
        rm -rf "$tmp_dir"
    else
        print_status "warning" "Could not resolve .deb URL. Visit https://etcher.balena.io"
        return 1
    fi
}

# Install the ventoy-web / ventoy-plugson wrappers plus their .desktop entries.
# Runs on every install_ventoy call so an already-installed Ventoy gets them too.
install_ventoy_launchers() {
    local src_dir apps_dir
    src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../ventoy" && pwd)" || return 1
    apps_dir="$HOME/.local/share/applications"

    run_or_echo mkdir -p "$apps_dir"
    run_or_echo sudo install -m 755 "$src_dir/ventoy-launcher.sh" /usr/local/bin/ventoy-web
    run_or_echo sudo install -m 755 "$src_dir/ventoy-launcher.sh" /usr/local/bin/ventoy-plugson
    # The opener sits next to the wrapper so `ventoy-plugson --install-launcher` finds it.
    run_or_echo sudo install -m 755 "$src_dir/ventoy-pendrive-launcher.sh" \
        /usr/local/bin/ventoy-pendrive-launcher.sh

    local name exec_cmd comment
    for name in web plugson; do
        if [ "$name" = web ]; then
            comment="Ventoy installer web UI (localhost:24680)"
        else
            comment="Ventoy pendrive configuration UI (localhost:24681)"
        fi
        exec_cmd="ventoy-$name"
        [ "${DRY_RUN:-0}" = "1" ] && { echo "[dry-run] write $apps_dir/ventoy-$name.desktop"; continue; }
        cat > "$apps_dir/ventoy-$name.desktop" <<DESKTOP
[Desktop Entry]
Name=Ventoy ${name^}
Comment=$comment
Exec=$exec_cmd
Icon=drive-removable-media
Terminal=true
Type=Application
Categories=System;Utility;
DESKTOP
    done
}

# Ventoy's scripts run under sudo, so they live in a root-owned dir: a user-writable
# copy (e.g. ~/.local/share/ventoy) would hand root to any process running as the user.
VENTOY_DIR_ROOT="/opt/ventoy"

# Root-own the tree, link the GUI and write ventoy.desktop. Returns 1 if no GUI binary.
_ventoy_publish() {
    local ventoy_dir=$1 gui_bin
    run_or_echo sudo chown -R root:root "$ventoy_dir"
    run_or_echo sudo chmod -R go-w "$ventoy_dir"
    gui_bin=$(find "$ventoy_dir" -maxdepth 1 -name "VentoyGUI.*" 2>/dev/null | head -n 1)
    if [ -z "$gui_bin" ]; then
        [ "${DRY_RUN:-0}" = "1" ] && return 0
        print_status "warning" "Ventoy extracted but GUI binary not found. Check $ventoy_dir"
        return 1
    fi
    run_or_echo sudo chmod +x "$gui_bin"
    run_or_echo sudo ln -sf "$gui_bin" /usr/local/bin/ventoy

    run_or_echo mkdir -p "$HOME/.local/share/applications"
    [ "${DRY_RUN:-0}" = "1" ] && return 0
    cat > "$HOME/.local/share/applications/ventoy.desktop" <<DESKTOP
[Desktop Entry]
Name=Ventoy
Comment=Create bootable USB drives with multiple ISOs
Exec=$gui_bin
Icon=drive-removable-media
Terminal=false
Type=Application
Categories=System;Utility;
DESKTOP
}

# /opt/ventoy counts as installed only when it holds the GUI AND is root-owned and not
# group/world-writable. A user-writable tree (e.g. ~/.local/share/ventoy) never counts,
# and is never copied in: /opt/ventoy is populated only from a verified download.
_ventoy_trusted_install() {
    local owner mode
    [ -n "$(find "$VENTOY_DIR_ROOT" -maxdepth 1 -name 'VentoyGUI.*' 2>/dev/null)" ] || return 1
    read -r owner mode < <(stat -c '%u %a' "$VENTOY_DIR_ROOT") || return 1
    [ "$owner" = "0" ] && (( (8#$mode & 8#022) == 0 ))
}

# Download the tarball and its release sha256.txt into <dir> (user-owned temp) and
# verify. Refuses on a missing checksum asset, a missing entry, or a mismatch.
# Usage: _ventoy_fetch_verified <tarball_url> <sha256_url> <dir>  -> <dir>/ventoy.tar.gz
_ventoy_fetch_verified() {
    local tarball_url=$1 sha_url=$2 dir=$3 name expected
    name="${tarball_url##*/}"
    if [ -z "$sha_url" ]; then
        print_status "error" "No sha256.txt in the Ventoy release; refusing to install unverified"
        return 1
    fi
    curl -fsSL -o "$dir/ventoy.tar.gz" "$tarball_url" 2>>"$LOG_FILE" || {
        print_status "warning" "Download failed. Visit https://ventoy.net"
        return 1
    }
    curl -fsSL -o "$dir/sha256.txt" "$sha_url" 2>>"$LOG_FILE" || {
        print_status "error" "Could not fetch sha256.txt; refusing to install unverified"
        return 1
    }
    expected=$(awk -v f="$name" '$2==f || $2=="*"f {print $1; exit}' "$dir/sha256.txt")
    if [ -z "$expected" ]; then
        print_status "error" "sha256.txt has no entry for $name; refusing to install"
        return 1
    fi
    if ! echo "$expected  $dir/ventoy.tar.gz" | sha256sum -c --status; then
        print_status "error" "Checksum mismatch for $name; refusing to extract"
        return 1
    fi
}

install_ventoy() {
    print_status "section" "VENTOY"

    local ventoy_dir="$VENTOY_DIR_ROOT" legacy="$HOME/.local/share/ventoy"

    if _ventoy_trusted_install; then
        print_status "info" "Ventoy already installed"
        install_ventoy_launchers
        return $?
    fi
    if [ -n "$(find "$legacy" -maxdepth 1 -name 'VentoyGUI.*' 2>/dev/null)" ]; then
        print_status "info" "$legacy is no longer used (user-writable, never run as root) and can be removed"
    fi

    print_status "info" "Fetching latest Ventoy release..."
    local release_json tarball_url sha_url
    release_json=$(curl -s "https://api.github.com/repos/ventoy/Ventoy/releases/latest")
    tarball_url=$(echo "$release_json" | grep "browser_download_url" | grep "linux\.tar\.gz" | head -n 1 | cut -d '"' -f 4)
    sha_url=$(echo "$release_json" | grep "browser_download_url" | grep "sha256\.txt" | head -n 1 | cut -d '"' -f 4)

    if [ -z "$tarball_url" ] || [ "$tarball_url" = "null" ]; then
        print_status "warning" "Could not resolve download URL. Visit https://ventoy.net"
        return 1
    fi

    local tmp_dir ventoy_installed=0
    tmp_dir=$(mktemp -d)
    print_status "info" "Downloading Ventoy..."
    if _ventoy_fetch_verified "$tarball_url" "$sha_url" "$tmp_dir"; then
        run_or_echo sudo mkdir -p "$ventoy_dir"
        run_or_echo sudo tar -xzf "$tmp_dir/ventoy.tar.gz" -C "$ventoy_dir" --strip-components=2

        if ! _ventoy_publish "$ventoy_dir"; then
            rm -rf "$tmp_dir"
            return 1
        fi
        install_ventoy_launchers
        print_status "success" "Ventoy installed to $ventoy_dir"
        ventoy_installed=1
    fi
    rm -rf "$tmp_dir"
    [ "$ventoy_installed" -eq 1 ] || return 1
}

# ============================================================================
# REGISTRY
# ============================================================================

INSTALL_REGISTRY+=(
    "install_virtual_machine_manager:VM Manager:Infra:virt-manager.desktop"
    "install_balena_etcher:Balena Etcher (USB Image Writer):Infra:balena-etcher.desktop"
    "install_ventoy:Ventoy (Multiboot USB):Infra:ventoy.desktop"
)
