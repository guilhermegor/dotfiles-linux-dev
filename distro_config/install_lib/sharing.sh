#!/bin/bash
#
# distro_config/install_lib/sharing.sh
#
# File-sharing, remote-desktop, sync, antivirus. Sourced by install_programs.sh.
# Depends on: print_status, command_exists, install_package, $PACKAGE_MANAGER,
#             $INSTALL_CMD, $DOWNLOADS_DIR, $DISTRO, $UBUNTU_VERSION, $UBUNTU_CODENAME,
#             $LOG_FILE

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "sharing.sh is meant to be sourced, not executed." >&2
    exit 1
fi

# ============================================================================
# LOCALSEND
# ============================================================================

install_localsend() {
    print_status "section" "LOCALSEND"

    if command_exists localsend || flatpak list 2>/dev/null | grep -q "org.localsend.localsend_app"; then
        print_status "info" "LocalSend already installed"
        return 0
    fi

    cd "$DOWNLOADS_DIR" || return 1

    case "$PACKAGE_MANAGER" in
        apt)
            print_status "info" "Detecting system architecture..."
            local arch
            arch=$(dpkg --print-architecture)
            local download_arch=""

            case "$arch" in
                amd64)  download_arch="x86-64"; print_status "info" "Architecture: x86-64 (amd64)" ;;
                arm64)  download_arch="arm-64"; print_status "info" "Architecture: ARM 64-bit" ;;
                armhf)  download_arch="arm-32"; print_status "info" "Architecture: ARM 32-bit" ;;
                *)
                    print_status "warning" "Unsupported architecture: $arch. Installing via Flatpak..."
                    run_or_echo flatpak install -y flathub org.localsend.localsend_app
                    cd - > /dev/null || return 1
                    return 0
                    ;;
            esac

            print_status "info" "Fetching latest LocalSend release..."
            local latest_url
            latest_url=$(curl -s https://api.github.com/repos/localsend/localsend/releases/latest | \
                grep "browser_download_url.*linux-${download_arch}.deb" | head -n 1 | cut -d '"' -f 4)

            if [ -n "$latest_url" ] && [ "$latest_url" != "null" ]; then
                print_status "info" "Downloading LocalSend from GitHub..."
                print_status "config" "URL: $latest_url"

                if wget -O localsend.deb "$latest_url"; then
                    print_status "info" "Installing LocalSend..."
                    run_or_echo sudo dpkg -i localsend.deb
                    run_or_echo sudo apt-get install -f -y
                    print_status "success" "LocalSend installed via .deb package"
                else
                    print_status "warning" "Download failed. Installing via Flatpak..."
                    run_or_echo flatpak install -y flathub org.localsend.localsend_app
                    print_status "success" "LocalSend installed via Flatpak"
                fi
            else
                print_status "warning" "Could not fetch latest release. Installing via Flatpak..."
                run_or_echo flatpak install -y flathub org.localsend.localsend_app
                print_status "success" "LocalSend installed via Flatpak"
            fi
            ;;
        dnf|yum|zypper)
            print_status "info" "Detecting system architecture..."
            local arch
            arch=$(uname -m)
            local download_arch=""

            case "$arch" in
                x86_64)   download_arch="x86-64"; print_status "info" "Architecture: x86-64" ;;
                aarch64)  download_arch="arm-64"; print_status "info" "Architecture: ARM 64-bit" ;;
                *)
                    print_status "warning" "Unsupported architecture: $arch. Installing via Flatpak..."
                    run_or_echo flatpak install -y flathub org.localsend.localsend_app
                    cd - > /dev/null || return 1
                    return 0
                    ;;
            esac

            print_status "info" "Fetching latest LocalSend release..."
            local latest_url
            latest_url=$(curl -s https://api.github.com/repos/localsend/localsend/releases/latest | \
                grep "browser_download_url.*linux-${download_arch}.rpm" | head -n 1 | cut -d '"' -f 4)

            if [ -n "$latest_url" ] && [ "$latest_url" != "null" ]; then
                print_status "info" "Downloading LocalSend from GitHub..."
                print_status "config" "URL: $latest_url"

                if wget -O localsend.rpm "$latest_url"; then
                    print_status "info" "Installing LocalSend..."
                    if [ "$PACKAGE_MANAGER" = "zypper" ]; then
                        $INSTALL_CMD localsend.rpm
                    else
                        sudo $PACKAGE_MANAGER install -y localsend.rpm
                    fi
                    print_status "success" "LocalSend installed via .rpm package"
                else
                    print_status "warning" "Download failed. Installing via Flatpak..."
                    run_or_echo flatpak install -y flathub org.localsend.localsend_app
                    print_status "success" "LocalSend installed via Flatpak"
                fi
            else
                print_status "warning" "Could not fetch latest release. Installing via Flatpak..."
                run_or_echo flatpak install -y flathub org.localsend.localsend_app
                print_status "success" "LocalSend installed via Flatpak"
            fi
            ;;
        pacman)
            if command_exists yay; then
                print_status "info" "Installing LocalSend from AUR..."
                run_or_echo yay -S --noconfirm localsend-bin
                print_status "success" "LocalSend installed from AUR"
            else
                print_status "info" "yay not found. Installing LocalSend via Flatpak..."
                run_or_echo flatpak install -y flathub org.localsend.localsend_app
                print_status "success" "LocalSend installed via Flatpak"
            fi
            ;;
    esac

    print_status "info" "Configuring firewall for LocalSend..."
    case "$PACKAGE_MANAGER" in
        apt|pacman)
            if command_exists ufw; then
                run_or_echo sudo ufw allow 53317/tcp comment "LocalSend" 2>/dev/null
                run_or_echo sudo ufw allow 53317/udp comment "LocalSend" 2>/dev/null
                run_or_echo sudo ufw reload 2>/dev/null
                print_status "success" "Firewall configured for LocalSend (port 53317)"
            else
                print_status "info" "UFW not installed. Skipping firewall configuration."
            fi
            ;;
        dnf|yum|zypper)
            if command_exists firewall-cmd; then
                run_or_echo sudo firewall-cmd --permanent --add-port=53317/tcp 2>/dev/null
                run_or_echo sudo firewall-cmd --permanent --add-port=53317/udp 2>/dev/null
                run_or_echo sudo firewall-cmd --reload 2>/dev/null
                print_status "success" "Firewall configured for LocalSend (port 53317)"
            else
                print_status "info" "firewalld not installed. Skipping firewall configuration."
            fi
            ;;
    esac

    print_status "info" "LocalSend: Secure file sharing on your local network"
    print_status "config" "Available on Android, iOS, Windows, macOS, and Linux"

    cd - > /dev/null || return 1
}

# ============================================================================
# RUSTDESK
# ============================================================================

install_rustdesk() {
    print_status "section" "RUSTDESK REMOTE DESKTOP"

    if command_exists rustdesk || flatpak list 2>/dev/null | grep -q "com.rustdesk.RustDesk" || dpkg -l 2>/dev/null | grep -q "^ii  rustdesk "; then
        print_status "info" "RustDesk already installed"
        return 0
    fi

    cd "$DOWNLOADS_DIR" || return 1

    case "$PACKAGE_MANAGER" in
        apt)
            print_status "info" "Detecting system architecture..."
            local arch
            arch=$(dpkg --print-architecture)
            local download_arch=""

            case "$arch" in
                amd64)  download_arch="x86_64"; print_status "info" "Architecture: x86-64 (amd64)" ;;
                arm64)  download_arch="aarch64"; print_status "info" "Architecture: ARM 64-bit" ;;
                armhf)  download_arch="armv7"; print_status "info" "Architecture: ARM 32-bit" ;;
                *)
                    print_status "warning" "Unsupported architecture: $arch. Installing via Flatpak..."
                    run_or_echo flatpak install -y flathub com.rustdesk.RustDesk
                    cd - > /dev/null || return 1
                    return 0
                    ;;
            esac

            print_status "info" "Fetching latest RustDesk release..."
            local latest_info
            latest_info=$(curl -s https://api.github.com/repos/rustdesk/rustdesk/releases/latest)
            local latest_version
            latest_version=$(echo "$latest_info" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

            if [ -z "$latest_version" ]; then
                print_status "warning" "Could not fetch latest version, using fallback"
                latest_version="1.4.4"
            fi

            print_status "info" "Latest RustDesk version: $latest_version"

            local deb_filename="rustdesk-${latest_version}-${download_arch}.deb"
            local latest_url="https://github.com/rustdesk/rustdesk/releases/download/${latest_version}/${deb_filename}"

            print_status "info" "Downloading RustDesk from GitHub..."
            print_status "config" "URL: $latest_url"

            if wget -O rustdesk.deb "$latest_url"; then
                print_status "success" "RustDesk downloaded successfully"

                print_status "info" "Checking for existing dependency issues..."
                run_or_echo sudo apt-get install -f -y || true

                print_status "info" "Installing RustDesk dependencies..."
                sudo apt-get update

                local essential_deps=(
                    "libxdo3"
                    "libgtk-3-0"
                    "libxtst6"
                    "libxcb-randr0"
                    "libxcb-shape0"
                    "libxcb-xfixes0"
                    "libxcb-keysyms1"
                    "libxcb-image0"
                    "libxcb-xtest0"
                )

                local dep
                for dep in "${essential_deps[@]}"; do
                    print_status "info" "Installing $dep..."
                    run_or_echo sudo apt-get install -y "$dep" || print_status "warning" "Failed to install $dep, continuing..."
                done

                if run_or_echo sudo apt-get install -y libayatana-appindicator3-1 2>/dev/null; then
                    print_status "info" "Installed libayatana-appindicator3-1"
                elif run_or_echo sudo apt-get install -y libappindicator3-1 2>/dev/null; then
                    print_status "info" "Installed libappindicator3-1"
                else
                    print_status "warning" "Could not install appindicator library, continuing..."
                fi

                print_status "info" "Installing RustDesk..."
                if run_or_echo sudo dpkg -i rustdesk.deb; then
                    print_status "success" "RustDesk installed via .deb package"
                else
                    print_status "warning" "dpkg installation had issues, fixing dependencies..."
                    run_or_echo sudo apt-get install -f -y

                    if dpkg -l | grep -q "^ii  rustdesk "; then
                        print_status "success" "RustDesk installed after fixing dependencies"
                    else
                        print_status "error" "Failed to install RustDesk via .deb package"
                        print_status "info" "Trying Flatpak installation..."
                        if run_or_echo flatpak install -y flathub com.rustdesk.RustDesk; then
                            print_status "success" "RustDesk installed via Flatpak"
                        else
                            print_status "error" "All installation methods failed"
                            print_status "info" "You can install RustDesk manually from:"
                            print_status "config" "https://github.com/rustdesk/rustdesk/releases"
                        fi
                    fi
                fi
            else
                print_status "warning" "Download failed. Installing via Flatpak..."
                if run_or_echo flatpak install -y flathub com.rustdesk.RustDesk; then
                    print_status "success" "RustDesk installed via Flatpak"
                else
                    print_status "error" "Flatpak installation also failed"
                fi
            fi
            ;;
        dnf|yum|zypper)
            print_status "info" "Detecting system architecture..."
            local arch
            arch=$(uname -m)
            local download_arch=""

            case "$arch" in
                x86_64)   download_arch="x86_64"; print_status "info" "Architecture: x86-64" ;;
                aarch64)  download_arch="aarch64"; print_status "info" "Architecture: ARM 64-bit" ;;
                *)
                    print_status "warning" "Unsupported architecture: $arch. Installing via Flatpak..."
                    run_or_echo flatpak install -y flathub com.rustdesk.RustDesk
                    cd - > /dev/null || return 1
                    return 0
                    ;;
            esac

            print_status "info" "Fetching latest RustDesk release..."
            local latest_info
            latest_info=$(curl -s https://api.github.com/repos/rustdesk/rustdesk/releases/latest)
            local latest_version
            latest_version=$(echo "$latest_info" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

            if [ -z "$latest_version" ]; then
                print_status "warning" "Could not fetch latest version, using fallback"
                latest_version="1.4.4"
            fi

            print_status "info" "Latest RustDesk version: $latest_version"

            local rpm_filename="rustdesk-${latest_version}-${download_arch}.rpm"
            local latest_url="https://github.com/rustdesk/rustdesk/releases/download/${latest_version}/${rpm_filename}"

            print_status "info" "Downloading RustDesk from GitHub..."
            print_status "config" "URL: $latest_url"

            if wget -O rustdesk.rpm "$latest_url"; then
                print_status "info" "Installing RustDesk..."
                if [ "$PACKAGE_MANAGER" = "zypper" ]; then
                    $INSTALL_CMD rustdesk.rpm
                else
                    sudo $PACKAGE_MANAGER install -y rustdesk.rpm
                fi
                print_status "success" "RustDesk installed via .rpm package"
            else
                print_status "warning" "Download failed. Installing via Flatpak..."
                run_or_echo flatpak install -y flathub com.rustdesk.RustDesk
                print_status "success" "RustDesk installed via Flatpak"
            fi
            ;;
        pacman)
            if command_exists yay; then
                print_status "info" "Installing RustDesk from AUR..."
                run_or_echo yay -S --noconfirm rustdesk-bin
                print_status "success" "RustDesk installed from AUR"
            else
                print_status "info" "yay not found. Installing RustDesk via Flatpak..."
                run_or_echo flatpak install -y flathub com.rustdesk.RustDesk
                print_status "success" "RustDesk installed via Flatpak"
            fi
            ;;
    esac

    print_status "info" "Configuring firewall for RustDesk..."
    case "$PACKAGE_MANAGER" in
        apt|pacman)
            if command_exists ufw; then
                run_or_echo sudo ufw allow 21115:21119/tcp comment "RustDesk" 2>/dev/null
                run_or_echo sudo ufw allow 21115:21119/udp comment "RustDesk" 2>/dev/null
                run_or_echo sudo ufw reload 2>/dev/null
                print_status "success" "Firewall configured for RustDesk (ports 21115-21119)"
            else
                print_status "info" "UFW not installed. Skipping firewall configuration."
            fi
            ;;
        dnf|yum|zypper)
            if command_exists firewall-cmd; then
                run_or_echo sudo firewall-cmd --permanent --add-port=21115-21119/tcp 2>/dev/null
                run_or_echo sudo firewall-cmd --permanent --add-port=21115-21119/udp 2>/dev/null
                run_or_echo sudo firewall-cmd --reload 2>/dev/null
                print_status "success" "Firewall configured for RustDesk (ports 21115-21119)"
            else
                print_status "info" "firewalld not installed. Skipping firewall configuration."
            fi
            ;;
    esac

    local rustdesk_verified=0
    if command_exists rustdesk || dpkg -l 2>/dev/null | grep -q "^ii  rustdesk " || flatpak list 2>/dev/null | grep -q "com.rustdesk.RustDesk"; then
        print_status "success" "RustDesk is ready to use"
        print_status "info" "RustDesk: Open-source remote desktop software"
        print_status "config" "Alternative to TeamViewer and AnyDesk"
        print_status "config" "Launch with: rustdesk"
        print_status "config" "You can set up your own relay server for better performance"
        rustdesk_verified=1

        if command_exists rustdesk; then
            rustdesk --version 2>&1 | head -n1 >> "$LOG_FILE" || true
        fi
    else
        print_status "warning" "RustDesk installation could not be verified"
        print_status "info" "You can install RustDesk manually from:"
        print_status "config" "https://github.com/rustdesk/rustdesk/releases"
        print_status "config" "Or via Flatpak: flatpak install flathub com.rustdesk.RustDesk"
    fi

    cd - > /dev/null || return 1
    [ "$rustdesk_verified" -eq 1 ] || return 1
}

# ============================================================================
# INSYNC (Google Drive client)
# ============================================================================

install_insync() {
    print_status "section" "INSYNC DOWNLOAD AND INSTALLATION"

    if command_exists insync || dpkg -l 2>/dev/null | grep -q insync; then
        print_status "info" "Insync already installed"
        return 0
    fi

    if [[ "$DISTRO" != "ubuntu" && "$DISTRO" != "debian" ]]; then
        print_status "warning" "Insync installation currently only supported on Ubuntu/Debian"
        print_status "info" "Please install Insync manually for your distribution"
        return 1
    fi

    cd "$DOWNLOADS_DIR" || return 1

    local insync_codename=""
    case "$UBUNTU_CODENAME" in
        noble)      insync_codename="noble" ;;
        jammy)      insync_codename="jammy" ;;
        focal)      insync_codename="focal" ;;
        bionic)     insync_codename="bionic" ;;
        *)
            print_status "warning" "Unknown Ubuntu codename: $UBUNTU_CODENAME, using noble as fallback"
            insync_codename="noble"
            ;;
    esac

    local insync_version="3.9.6.60027"
    local insync_deb_url="https://cdn.insynchq.com/builds/linux/${insync_version}/insync_${insync_version}-${insync_codename}_amd64.deb"
    local insync_deb_file="insync_${insync_version}-${insync_codename}_amd64.deb"

    print_status "info" "Detected Ubuntu $UBUNTU_VERSION ($UBUNTU_CODENAME)"
    print_status "info" "Downloading Insync for $insync_codename..."
    print_status "config" "Download URL: $insync_deb_url"

    if wget -O "$insync_deb_file" "$insync_deb_url" 2>&1 | tee -a "$LOG_FILE"; then
        if [ -f "$insync_deb_file" ] && [ -s "$insync_deb_file" ]; then
            print_status "success" "Insync downloaded successfully"

            if file "$insync_deb_file" | grep -q "Debian"; then
                print_status "info" "Installing Insync..."

                if run_or_echo sudo dpkg -i "$insync_deb_file"; then
                    print_status "success" "Insync installed successfully"
                    run_or_echo sudo apt-get install -f -y

                    if command_exists insync || dpkg -l | grep -q insync; then
                        print_status "success" "Insync installation verified"
                        print_status "info" "Insync version: $insync_version"
                        print_status "info" "Starting Insync..."
                        insync start &>> "$LOG_FILE" &
                        print_status "success" "Insync started"
                    else
                        print_status "warning" "Insync installed but command not found"
                        return 1
                    fi
                else
                    print_status "error" "Failed to install Insync package"
                    print_status "info" "Attempting to fix dependencies..."
                    run_or_echo sudo apt-get install -f -y

                    if run_or_echo sudo dpkg -i "$insync_deb_file"; then
                        print_status "success" "Insync installed after fixing dependencies"
                    else
                        print_status "error" "Failed to install Insync even after fixing dependencies"
                        return 1
                    fi
                fi
            else
                print_status "error" "Downloaded file is not a valid .deb package"
                rm -f "$insync_deb_file"
                return 1
            fi
        else
            print_status "error" "Downloaded file is empty or missing"
            return 1
        fi
    else
        print_status "error" "Failed to download Insync"
        print_status "info" "Please check your internet connection and try again"
        print_status "info" "Or download manually from: https://www.insynchq.com/downloads"
        return 1
    fi

    if [ ! -f "$insync_deb_file" ] || [ ! -s "$insync_deb_file" ]; then
        print_status "warning" "Primary download method failed, trying alternative..."

        local alt_url="https://cdn.insynchq.com/builds/linux/3.9.6.60027/insync_3.9.6.60027-noble_amd64.deb"
        print_status "info" "Trying alternative URL: $alt_url"

        if curl -L -o "insync_alternative.deb" "$alt_url" 2>&1 | tee -a "$LOG_FILE"; then
            if [ -f "insync_alternative.deb" ] && [ -s "insync_alternative.deb" ]; then
                print_status "info" "Installing Insync from alternative download..."
                run_or_echo sudo dpkg -i "insync_alternative.deb"
                run_or_echo sudo apt-get install -f -y
                print_status "success" "Insync installed from alternative download"
            else
                print_status "error" "Alternative download also failed"
                return 1
            fi
        else
            print_status "error" "All download methods failed"
            return 1
        fi
    fi

    print_status "info" "Insync: Google Drive sync client for Linux"
    print_status "config" "Launch with: insync start"
    print_status "config" "Configure with: insync show"

    cd - > /dev/null || return 1
}

# ============================================================================
# RCLONE (on-demand cloud mount — replaces Insync, see issue #360)
# ============================================================================
# Prefer the distro package over the rclone.org install script. Ubuntu noble
# ships rclone 1.60.1+dfsg-3ubuntu0.24.04.6 (checked via `apt-cache policy
# rclone`, 2026-09-13) — well past the 1.39/1.40 releases that introduced
# --vfs-cache-max-size / --vfs-cache-max-age (rclone's own changelog puts VFS
# caching in the 1.39 series), so no version-based fallback to the official
# install script is needed here.
#
# rclone is a CLI, not a GUI app: its INSTALL_REGISTRY entry leaves
# gnome_folder and desktop_file empty (#357 — a wrong desktop id places
# nothing in the app grid, silently).
#
# `rclone config` is interactive and account-bound: it is operator work, not
# installer work (issue #360). This function never runs it and never writes
# anything under ~/.config/rclone/ — it only installs the binary and prints
# the next manual step.
install_rclone() {
    print_status "section" "RCLONE (ON-DEMAND CLOUD MOUNT)"

    if command_exists rclone; then
        print_status "info" "rclone already installed: $(rclone version 2>/dev/null | head -n1)"
    else
        print_status "info" "Installing rclone..."
        if ! install_package "rclone" "rclone" "rclone" "rclone"; then
            print_status "error" "Failed to install rclone via $PACKAGE_MANAGER"
            return 1
        fi
    fi

    if ! command_exists rclone; then
        print_status "error" "rclone installation could not be verified — command not found"
        return 1
    fi

    print_status "success" "rclone is ready: $(rclone version 2>/dev/null | head -n1)"
    print_status "info" "Next step (operator, not automated): run 'rclone config' to add a remote"
    print_status "config" "This installer never runs 'rclone config' and stores no token"
    print_status "info" "Then generate the mount unit with install_rclone_mount_unit <remote> <mountpoint>"
}

# Write the non-secret skeleton of ~/.config/rclone/rclone.conf and run the
# one-time browser sign-in (issue #365). Never runs the interactive
# `rclone config` wizard — it offers "set configuration password", which
# encrypts the file and leaves the systemd mount unable to unlock it at
# boot. Writing the skeleton directly and deferring only the OAuth step to
# `rclone config reconnect` sidesteps that option entirely.
#   install_rclone_config [remote] [type] [region]
# Args fall back to RCLONE_REMOTE/RCLONE_TYPE/RCLONE_REGION (env, set by the
# Custom Installation orchestrator) and then to onedrive/onedrive/global —
# `${1-...}` (no colon) so an explicitly empty arg is kept, not defaulted.
install_rclone_config() {
    local remote="${1-${RCLONE_REMOTE:-onedrive}}"
    local rclone_type="${2-${RCLONE_TYPE:-onedrive}}"
    local region="${3-${RCLONE_REGION:-global}}"

    if ! command_exists rclone; then
        print_status "error" "rclone is not installed — run install_rclone first"
        return 1
    fi

    local conf_dir="$HOME/.config/rclone"
    local conf_file="$conf_dir/rclone.conf"

    if [ -f "$conf_file" ]; then
        print_status "error" "Refusing to overwrite existing $conf_file — it may hold a working token"
        return 1
    fi

    run_or_echo mkdir -p "$conf_dir"
    {
        echo "[$remote]"
        echo "type = $rclone_type"
        echo "region = $region"
    } > "$conf_file" || return 1
    chmod 600 "$conf_file"

    print_status "success" "Wrote skeleton $conf_file (mode 600)"

    if [ -t 0 ]; then
        print_status "info" "Browser sign-in required for ${remote}:"
        run_or_echo rclone config reconnect "${remote}:"
    else
        print_status "warning" "Unattended run — skipping the browser sign-in"
        print_status "config" "Run manually: rclone config reconnect ${remote}:"
    fi
}

# Write (never enable or start) a systemd USER unit for an rclone mount,
# creating the mount point when it is absent.
#   install_rclone_mount_unit [remote-name] [mountpoint]
#
# Args fall back to RCLONE_REMOTE/RCLONE_MOUNT_POINT (env, set by the Custom
# Installation orchestrator) and then to onedrive/~/OneDrive (issue #365).
# `${1-...}` (no colon) so an explicitly empty arg is kept, not defaulted —
# callers relying on the "usage" error below still get it.
#
# Enabling/starting the mount is operator work (issue #360): the operator
# must have already run `rclone config` for <remote-name>, and reviewing the
# generated unit before it goes live is the whole point of not auto-enabling
# it. Never registered in INSTALL_REGISTRY — Full Installation should not
# silently claim a mount point without the operator picking one first.
install_rclone_mount_unit() {
    local remote="${1-${RCLONE_REMOTE:-onedrive}}"
    local mountpoint="${2-${RCLONE_MOUNT_POINT:-$HOME/OneDrive}}"

    if [ -z "$remote" ] || [ -z "$mountpoint" ]; then
        print_status "error" "Usage: install_rclone_mount_unit <remote-name> <mountpoint>"
        return 1
    fi

    if ! command_exists rclone; then
        print_status "error" "rclone is not installed — run install_rclone first"
        return 1
    fi

    if [ "$mountpoint" = "$HOME/Insync" ]; then
        print_status "error" "Refusing to mount over $HOME/Insync — that directory must be gone first (issue #360)"
        return 1
    fi

    if [ -e "$mountpoint" ]; then
        if [ ! -d "$mountpoint" ]; then
            print_status "error" "$mountpoint exists and is not a directory"
            return 1
        fi
        if [ -n "$(find "$mountpoint" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
            print_status "error" "Refusing to mount over $mountpoint — it already exists and is not empty"
            return 1
        fi
    else
        print_status "info" "Creating mount point $mountpoint"
        run_or_echo mkdir -p "$mountpoint" || return 1
    fi

    local repo_root template_file unit_dir unit_file
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || return 1
    template_file="$repo_root/distro_config/dotfiles/rclone/rclone-mount.service.template"
    unit_dir="$HOME/.config/systemd/user"
    unit_file="$unit_dir/rclone-${remote}.service"

    if [ ! -f "$template_file" ]; then
        print_status "error" "Template not found: $template_file"
        return 1
    fi

    run_or_echo mkdir -p "$unit_dir"

    # Substitute only from [Unit] onward — the header comments above it use
    # the same {{REMOTE}}/{{MOUNTPOINT}} tokens to document the placeholders
    # themselves, and a blanket substitution made every generated unit's
    # header read "substitutes onedrive and /home/.../OneDrive..." (#365).
    sed \
        -e "/^\[Unit\]/,\$ s|{{REMOTE}}|${remote}|g" \
        -e "/^\[Unit\]/,\$ s|{{MOUNTPOINT}}|${mountpoint}|g" \
        "$template_file" > "$unit_file" || return 1

    print_status "success" "Wrote $unit_file"
    print_status "info" "Not enabled or started — review it, then run:"
    print_status "config" "  systemctl --user daemon-reload"
    print_status "config" "  systemctl --user enable --now rclone-${remote}.service"
}

# ============================================================================
# UNINSTALL INSYNC (replaced by rclone mount, see issue #360)
# ============================================================================
# ⚠️ Deleting ~/Insync while Insync is running propagates the deletion to
# Google Drive — that is exactly what a sync client is for, and it is the one
# way this could destroy remote data. These 5 steps are mandatory and
# ordered; each refuses to continue when its precondition fails rather than
# pressing on. Never registered in INSTALL_REGISTRY (#342 — a registry entry
# runs during Full Installation too, which would fight install_insync). Call
# manually:
#   bash -c 'source distro_config/install_lib/sharing.sh; uninstall_insync <remote> [account-dir]'
#
# Step 4 (deleting ~/Insync and ~/.config/Insync) additionally requires the
# explicit opt-in INSYNC_CONFIRM_DELETE=1 env var — it is the one step that
# destroys local data, and it must never run just because steps 1-3 passed.
uninstall_insync() {
    local remote="$1"
    local account_dir="${2:-$HOME/Insync}"

    print_status "section" "UNINSTALL INSYNC (5-step ordered removal)"

    # Step 1: quit Insync, verify no process survives, no autostart entry remains.
    print_status "info" "Step 1/5: quitting Insync and checking for a surviving process..."
    if command_exists insync; then
        insync quit &>> "$LOG_FILE" || true
        sleep 2
    fi
    if pgrep -a insync > /dev/null 2>&1; then
        print_status "error" "Step 1/5: an insync process is still running — refusing to continue"
        pgrep -a insync | tee -a "$LOG_FILE"
        return 1
    fi
    local autostart_file="$HOME/.config/autostart/insync.desktop"
    if [ -f "$autostart_file" ]; then
        run_or_echo rm -f "$autostart_file"
        print_status "info" "Step 1/5: removed autostart entry $autostart_file"
    fi
    print_status "success" "Step 1/5: no insync process running, no autostart entry"

    # Step 2: verify remote-side integrity while the local copy still exists.
    if [ -z "$remote" ]; then
        print_status "error" "Step 2/5: remote name required — usage: uninstall_insync <remote> [account-dir]"
        return 1
    fi
    if ! command_exists rclone; then
        print_status "error" "Step 2/5: rclone is not installed — cannot verify the remote, refusing to continue"
        return 1
    fi
    if [ ! -d "$account_dir" ]; then
        print_status "error" "Step 2/5: local account directory not found: $account_dir"
        return 1
    fi
    # --one-way means "source files must exist on destination" (rclone check
    # --help) — the local tree must be the SOURCE so the check proves every
    # local file made it to the remote, not the reverse (issue #577: with the
    # remote as source, a file Insync never uploaded still passes and then
    # gets deleted). --size-only skips hashing 1.3 T from disk, which would
    # otherwise run silently for hours inside this $(...) capture.
    local log_dir="."
    [ -n "${LOG_FILE:-}" ] && log_dir="$(dirname "$LOG_FILE")"
    local missing_on_dst_file="$log_dir/uninstall_insync_missing_on_dst.txt"
    local differ_file="$log_dir/uninstall_insync_differ.txt"
    print_status "info" "Step 2/5: comparing local '$account_dir' against remote '$remote:' (read-only)..."
    local check_output check_rc
    check_output=$(rclone check "$account_dir" "$remote:" --one-way --size-only \
        --missing-on-dst "$missing_on_dst_file" --differ "$differ_file" 2>&1)
    check_rc=$?
    echo "$check_output" >> "$LOG_FILE"
    if [ "$check_rc" -ne 0 ] || [ -s "$missing_on_dst_file" ] || [ -s "$differ_file" ]; then
        print_status "error" "Step 2/5: local copy is not fully backed up to the remote — refusing to delete anything"
        print_status "info" "Files missing on remote: $missing_on_dst_file"
        print_status "info" "Files that differ: $differ_file"
        print_status "info" "Resolve the discrepancy, then re-run uninstall_insync"
        return 1
    fi
    print_status "success" "Step 2/5: every local file exists on the remote — comparison recorded in $LOG_FILE"

    # Step 3: uninstall the package. Touches only the local machine; Google
    # Drive keeps everything regardless of which client is installed.
    print_status "info" "Step 3/5: removing the insync package..."
    run_or_echo sudo apt remove --purge -y insync
    if dpkg -l 2>/dev/null | grep -q '^ii  insync'; then
        print_status "error" "Step 3/5: insync package is still installed — refusing to continue"
        return 1
    fi
    print_status "success" "Step 3/5: insync package removed"

    # Step 4: only now delete local data — no daemon is watching the
    # directory anymore, so this is a local disk operation with no remote
    # consequence. Still gated behind an explicit opt-in.
    if [ "${INSYNC_CONFIRM_DELETE:-0}" != "1" ]; then
        print_status "warning" "Step 4/5: skipped — set INSYNC_CONFIRM_DELETE=1 to delete $account_dir and $HOME/.config/Insync"
        print_status "info" "No local data was deleted. Re-run with INSYNC_CONFIRM_DELETE=1 when ready."
        return 0
    fi
    print_status "info" "Step 4/5: deleting local data (no daemon is watching it)..."
    run_or_echo rm -rf "$account_dir"
    run_or_echo rm -rf "$HOME/.config/Insync"
    print_status "success" "Step 4/5: local Insync data removed"

    # Step 5: re-check the remote after deletion. Proof, not assurance.
    print_status "info" "Step 5/5: re-checking remote counts after deletion..."
    local lsjson_output lsjson_rc
    lsjson_output=$(rclone lsjson "$remote:" --stat 2>&1)
    lsjson_rc=$?
    echo "$lsjson_output" >> "$LOG_FILE"
    if [ "$lsjson_rc" -ne 0 ]; then
        print_status "warning" "Step 5/5: could not re-list remote — check manually"
    fi
    print_status "success" "Uninstall complete — compare the before/after counts recorded in $LOG_FILE"
}

# ============================================================================
# CLAMAV ANTIVIRUS
# ============================================================================

install_clamav() {
    print_status "section" "ANTIVIRUS (CLAMAV)"

    print_status "info" "Installing ClamAV..."
    run_or_echo sudo apt-get install -y clamav clamav-daemon clamtk

    print_status "info" "Updating virus definitions..."
    run_or_echo sudo systemctl stop clamav-freshclam
    sudo freshclam
    run_or_echo sudo systemctl start clamav-freshclam

    print_status "success" "ClamAV installed and configured"
}

# ============================================================================
# REGISTRY
# ============================================================================

INSTALL_REGISTRY+=(
    "install_localsend:LocalSend File Sharing:Sharing:localsend_app.desktop"
    # gnome_folder is Infra, not Sharing: RustDesk was duplicated into both
    # Infra (this file's own hardcoded infra_app_names list in
    # ubuntu_workspace.sh) and Sharing (this registry entry) — Infra is the
    # folder that fits (#391). install_rustdesk stays defined here; only the
    # placement changes.
    "install_rustdesk:RustDesk Remote Desktop:Infra:rustdesk.desktop"
    "install_insync:Insync (Google Drive):Sharing:insync.desktop"
    "install_rclone:rclone (on-demand cloud mount)::"
    "install_clamav:ClamAV Antivirus:Seguranca:clamtk.desktop"
)
