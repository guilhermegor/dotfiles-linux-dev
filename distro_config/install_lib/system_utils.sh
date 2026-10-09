#!/bin/bash
#
# distro_config/install_lib/system_utils.sh
#
# System utilities, GNOME extensions, snap/flatpak rollups. Sourced by install_programs.sh.
# Depends on: print_status, command_exists, install_package, setup_flatpak,
#             $PACKAGE_MANAGER, $INSTALL_CMD, $DOWNLOADS_DIR, $DISTRO, $UBUNTU_VERSION

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "system_utils.sh is meant to be sourced, not executed." >&2
    exit 1
fi

# ============================================================================
# VITALS GNOME EXTENSION (+ helpers)
# ============================================================================

install_vitals() {
    print_status "section" "VITALS SYSTEM MONITOR"

    if gnome-extensions list 2>/dev/null | grep -q "Vitals@CoreCoding.com"; then
        print_status "info" "Vitals extension already installed"

        if gnome-extensions info "Vitals@CoreCoding.com" 2>/dev/null | grep -q "ENABLED"; then
            print_status "success" "Vitals extension is already enabled"
        else
            print_status "info" "Enabling Vitals extension..."
            if gnome-extensions enable "Vitals@CoreCoding.com" 2>&1 | tee -a "$LOG_FILE"; then
                print_status "success" "Vitals extension enabled"
            else
                print_status "warning" "Could not enable Vitals extension"
                print_status "info" "You may need to log out and log back in"
            fi
        fi
        return 0
    fi

    print_status "info" "Installing Vitals system monitor extension..."

    if ! command_exists gnome-shell; then
        print_status "warning" "GNOME Shell not detected. Vitals requires GNOME desktop environment."
        print_status "info" "Skipping Vitals installation for non-GNOME systems."
        return 1
    fi

    case "$PACKAGE_MANAGER" in
        apt)        install_vitals_debian ;;
        dnf|yum)    install_vitals_rpm ;;
        pacman)     install_vitals_arch ;;
        zypper)     install_vitals_opensuse ;;
        *)
            print_status "warning" "Unsupported package manager, trying manual installation"
            install_vitals_manual
            ;;
    esac

    verify_vitals_installation
}

verify_vitals_installation() {
    print_status "info" "Verifying Vitals installation..."

    local max_attempts=3
    local attempt=1
    local vitals_installed=false

    while [ $attempt -le $max_attempts ]; do
        print_status "info" "Verification attempt $attempt/$max_attempts..."

        if gnome-extensions list 2>/dev/null | grep -q "Vitals@CoreCoding.com"; then
            vitals_installed=true
            print_status "success" "Vitals detected in extension list"
            break
        fi

        print_status "info" "Refreshing extension list..."

        if command_exists dbus-send; then
            dbus-send --session --type=method_call \
                --dest=org.gnome.Shell \
                /org/gnome/Shell \
                org.gnome.Shell.Extensions.ReloadExtensionInfo \
                string:"Vitals@CoreCoding.com" 2>/dev/null || true
        fi

        if command_exists gdbus; then
            gdbus call --session --dest org.gnome.Shell \
                --object-path /org/gnome/Shell \
                --method org.gnome.Shell.Extensions.ReloadExtensionInfo \
                "Vitals@CoreCoding.com" 2>/dev/null || true
        fi

        sleep 3
        attempt=$((attempt + 1))
    done

    if [ "$vitals_installed" = true ]; then
        print_status "info" "Enabling Vitals extension..."

        if gnome-extensions enable "Vitals@CoreCoding.com" 2>&1 | tee -a "$LOG_FILE"; then
            print_status "success" "Vitals extension enabled successfully"

            sleep 2
            if gnome-extensions info "Vitals@CoreCoding.com" 2>/dev/null | grep -q "ENABLED"; then
                print_status "success" "Vitals extension is active and running"
            else
                print_status "warning" "Vitals enabled but may not be active"
            fi
        else
            print_status "warning" "Could not enable Vitals extension automatically"
            print_status "info" "You may need to enable it manually"
        fi
    else
        print_status "warning" "Vitals installation could not be verified automatically"

        local extensions_dir="$HOME/.local/share/gnome-shell/extensions"
        local vitals_dir="$extensions_dir/Vitals@CoreCoding.com"

        if [ -d "$vitals_dir" ]; then
            print_status "info" "Vitals files are present at: $vitals_dir"
            print_status "info" "The extension will be available after you:"
            print_status "config" "1. Log out and log back in, OR"
            print_status "config" "2. Restart GNOME Shell: Alt+F2, type 'r', press Enter"
        else
            print_status "error" "Vitals files not found"
            print_status "info" "You may need to install it manually from extensions.gnome.org"
        fi
        return 1
    fi
}

install_vitals_debian() {
    print_status "info" "Installing Vitals on Debian-based system..."

    print_status "info" "Installing GNOME Shell extension dependencies..."
    $INSTALL_CMD gnome-shell-extensions gnome-shell-extension-prefs chrome-gnome-shell

    if [[ "$DISTRO" == "ubuntu" ]] && [[ "$UBUNTU_VERSION" == "24.04" ]]; then
        print_status "info" "Ubuntu 24.04 detected, checking for Vitals in repositories..."
        if apt-cache search gnome-shell-extension-vitals 2>/dev/null | grep -q vitals; then
            print_status "info" "Installing Vitals from Ubuntu repository..."
            if $INSTALL_CMD gnome-shell-extension-vitals; then
                print_status "success" "Vitals installed from repository"
                return 0
            else
                print_status "warning" "Repository installation failed, trying manual..."
            fi
        fi
    fi

    install_vitals_manual
}

install_vitals_rpm() {
    print_status "info" "Installing Vitals on RPM-based system..."

    print_status "info" "Installing GNOME Shell extension dependencies..."
    $INSTALL_CMD gnome-shell-extension-tool gnome-tweaks

    print_status "info" "Checking for Vitals in repositories..."
    if $PACKAGE_MANAGER search gnome-shell-extension-vitals 2>/dev/null | grep -q vitals; then
        print_status "info" "Installing Vitals from repository..."
        if $INSTALL_CMD gnome-shell-extension-vitals; then
            print_status "success" "Vitals installed from repository"
            return 0
        else
            print_status "warning" "Repository installation failed, trying manual..."
        fi
    fi

    install_vitals_manual
}

install_vitals_arch() {
    print_status "info" "Installing Vitals on Arch Linux..."

    if command_exists yay; then
        print_status "info" "Installing Vitals from AUR..."
        if yay -S --noconfirm gnome-shell-extension-vitals 2>&1 | tee -a "$LOG_FILE"; then
            print_status "success" "Vitals installed from AUR"
            return 0
        fi
    fi

    install_vitals_manual
}

install_vitals_opensuse() {
    print_status "info" "Installing Vitals on openSUSE..."

    print_status "info" "Installing GNOME Shell extension dependencies..."
    $INSTALL_CMD gnome-shell-extension-common gnome-tweaks

    print_status "info" "Checking for Vitals in repositories..."
    if zypper search -s gnome-shell-extension-vitals 2>/dev/null | grep -q vitals; then
        print_status "info" "Installing Vitals from repository..."
        if $INSTALL_CMD gnome-shell-extension-vitals; then
            print_status "success" "Vitals installed from repository"
            return 0
        else
            print_status "warning" "Repository installation failed, trying manual..."
        fi
    fi

    install_vitals_manual
}

install_vitals_manual() {
    print_status "info" "Installing Vitals manually from GitHub..."

    local extensions_dir="$HOME/.local/share/gnome-shell/extensions"
    local vitals_dir="$extensions_dir/Vitals@CoreCoding.com"

    run_or_echo mkdir -p "$extensions_dir"

    if [ -d "$vitals_dir" ]; then
        print_status "info" "Vitals directory already exists, updating..."
        cd "$vitals_dir" || return 1
        if git pull 2>&1 | tee -a "$LOG_FILE"; then
            print_status "success" "Vitals updated from GitHub"
        else
            print_status "warning" "Could not update Vitals, using existing version"
        fi
        cd - > /dev/null || return 1
    else
        print_status "info" "Cloning Vitals from GitHub repository..."
        cd "$extensions_dir" || return 1
        if git clone https://github.com/corecoding/Vitals.git "Vitals@CoreCoding.com" 2>&1 | tee -a "$LOG_FILE"; then
            print_status "success" "Vitals cloned from GitHub"
        else
            print_status "error" "Failed to clone Vitals from GitHub"
            print_status "info" "You can download it manually from: https://extensions.gnome.org/extension/1460/vitals/"
            return 1
        fi
        cd - > /dev/null || return 1
    fi

    if [ ! -f "$vitals_dir/metadata.json" ]; then
        print_status "error" "Vitals installation incomplete - metadata.json not found"
        print_status "info" "Please check the extension directory: $vitals_dir"
        return 1
    fi

    if [ -d "$vitals_dir/schemas" ]; then
        print_status "info" "Compiling Vitals schemas..."
        if [ -f "$vitals_dir/schemas/gschemas.compiled" ]; then
            rm -f "$vitals_dir/schemas/gschemas.compiled"
        fi
        if command_exists glib-compile-schemas; then
            run_or_echo glib-compile-schemas "$vitals_dir/schemas" 2>&1 | tee -a "$LOG_FILE"
            print_status "success" "Vitals schemas compiled"
        fi
    fi

    print_status "info" "Setting correct permissions..."
    chmod -R 755 "$vitals_dir"

    print_status "info" "Creating desktop file for better integration..."
    local desktop_file="$HOME/.local/share/applications/gnome-shell-extension-vitals.desktop"
    cat > "$desktop_file" << EOF
[Desktop Entry]
Type=Application
Name=Vitals System Monitor
Comment=System monitor for GNOME Shell
Exec=/usr/bin/true
Terminal=false
Categories=Utility;
OnlyShowIn=GNOME;
EOF

    if [ "$EUID" -eq 0 ] || sudo -n true 2>/dev/null; then
        print_status "info" "Also installing to system directory for better compatibility..."
        run_or_echo sudo mkdir -p /usr/share/gnome-shell/extensions/
        run_or_echo sudo cp -r "$vitals_dir" /usr/share/gnome-shell/extensions/ 2>/dev/null || true
        run_or_echo sudo chown -R root:root /usr/share/gnome-shell/extensions/Vitals@CoreCoding.com 2>/dev/null || true
    fi

    print_status "info" "Vitals manual installation complete"
}

# ============================================================================
# DIM COMPLETED CALENDAR EVENTS (GNOME EXTENSION)
# ============================================================================

install_dim_calendar_events() {
    print_status "section" "DIM COMPLETED CALENDAR EVENTS"

    local EXT_UUID="dim-completed-calendar-events@marcinjahn.com"
    local EXT_PK=5979

    if gnome-extensions list 2>/dev/null | grep -q "$EXT_UUID"; then
        print_status "info" "Dim Completed Calendar Events already installed"

        if gnome-extensions info "$EXT_UUID" 2>/dev/null | grep -q "ENABLED"; then
            print_status "success" "Dim Completed Calendar Events is already enabled"
        else
            print_status "info" "Enabling Dim Completed Calendar Events..."
            if gnome-extensions enable "$EXT_UUID" 2>&1 | tee -a "$LOG_FILE"; then
                print_status "success" "Dim Completed Calendar Events enabled"
            else
                print_status "warning" "Could not enable extension"
                print_status "info" "You may need to log out and log back in"
            fi
        fi
        return 0
    fi

    print_status "info" "Installing Dim Completed Calendar Events extension..."

    if ! command_exists gnome-shell; then
        print_status "warning" "GNOME Shell not detected. This extension requires GNOME desktop environment."
        print_status "info" "Skipping installation for non-GNOME systems."
        return 1
    fi

    local shell_version
    shell_version=$(gnome-shell --version 2>/dev/null | grep -oP '\d+' | head -1)
    if [ -z "$shell_version" ]; then
        print_status "error" "Could not detect GNOME Shell version"
        return 1
    fi
    print_status "info" "Detected GNOME Shell version: $shell_version"

    local version_tag=""
    local api_url="https://extensions.gnome.org/extension-info/?pk=${EXT_PK}&shell_version=${shell_version}"

    print_status "info" "Querying extensions.gnome.org for compatible version..."
    if command_exists curl; then
        version_tag=$(curl -s "$api_url" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('version_tag',''))" 2>/dev/null)
    elif command_exists wget; then
        version_tag=$(wget -qO- "$api_url" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('version_tag',''))" 2>/dev/null)
    fi

    if [ -z "$version_tag" ]; then
        print_status "warning" "Could not query extensions.gnome.org API, using fallback"
        case "$shell_version" in
            46) version_tag=59030 ;;
            47|48|49) version_tag=66346 ;;
            *)
                print_status "error" "No known version_tag for GNOME Shell $shell_version"
                print_status "info" "Install manually from: https://extensions.gnome.org/extension/${EXT_PK}/"
                return 1
                ;;
        esac
    fi

    print_status "info" "Using version_tag: $version_tag"

    local tmp_zip="/tmp/${EXT_UUID}.zip"
    local download_url="https://extensions.gnome.org/download-extension/${EXT_UUID}.shell-extension.zip?version_tag=${version_tag}"

    print_status "info" "Downloading extension..."
    if command_exists curl; then
        run_or_echo curl -L -o "$tmp_zip" "$download_url" 2>&1 | tee -a "$LOG_FILE"
    elif command_exists wget; then
        run_or_echo wget -O "$tmp_zip" "$download_url" 2>&1 | tee -a "$LOG_FILE"
    else
        print_status "error" "Neither curl nor wget found. Cannot download extension."
        return 1
    fi

    if [ ! -f "$tmp_zip" ] || [ ! -s "$tmp_zip" ]; then
        print_status "error" "Download failed or file is empty"
        rm -f "$tmp_zip"
        return 1
    fi

    print_status "info" "Installing extension..."
    if gnome-extensions install --force "$tmp_zip" 2>&1 | tee -a "$LOG_FILE"; then
        print_status "success" "Extension installed"
    else
        print_status "error" "gnome-extensions install failed"
        rm -f "$tmp_zip"
        return 1
    fi

    rm -f "$tmp_zip"

    local ext_dir="$HOME/.local/share/gnome-shell/extensions/$EXT_UUID"
    if [ -d "$ext_dir/schemas" ]; then
        print_status "info" "Compiling extension schemas..."
        if command_exists glib-compile-schemas; then
            run_or_echo glib-compile-schemas "$ext_dir/schemas" 2>&1 | tee -a "$LOG_FILE"
        fi
    fi

    verify_dim_calendar_events
}

verify_dim_calendar_events() {
    print_status "info" "Verifying Dim Completed Calendar Events installation..."

    local EXT_UUID="dim-completed-calendar-events@marcinjahn.com"
    local max_attempts=3
    local attempt=1
    local ext_installed=false

    while [ $attempt -le $max_attempts ]; do
        print_status "info" "Verification attempt $attempt/$max_attempts..."

        if gnome-extensions list 2>/dev/null | grep -q "$EXT_UUID"; then
            ext_installed=true
            print_status "success" "Extension detected in extension list"
            break
        fi

        print_status "info" "Refreshing extension list..."
        if command_exists dbus-send; then
            dbus-send --session --type=method_call \
                --dest=org.gnome.Shell \
                /org/gnome/Shell \
                org.gnome.Shell.Extensions.ReloadExtensionInfo \
                string:"$EXT_UUID" 2>/dev/null || true
        fi
        if command_exists gdbus; then
            gdbus call --session --dest org.gnome.Shell \
                --object-path /org/gnome/Shell \
                --method org.gnome.Shell.Extensions.ReloadExtensionInfo \
                "$EXT_UUID" 2>/dev/null || true
        fi

        sleep 3
        attempt=$((attempt + 1))
    done

    if [ "$ext_installed" = true ]; then
        print_status "info" "Enabling extension..."
        if gnome-extensions enable "$EXT_UUID" 2>&1 | tee -a "$LOG_FILE"; then
            print_status "success" "Extension enabled successfully"
            sleep 2
            if gnome-extensions info "$EXT_UUID" 2>/dev/null | grep -q "ENABLED"; then
                print_status "success" "Extension is active and running"
            else
                print_status "warning" "Extension enabled but may not be active until next login"
            fi
        else
            print_status "warning" "Could not enable extension automatically"
            print_status "info" "You may need to enable it manually via Extensions app"
        fi
    else
        print_status "warning" "Installation could not be verified automatically"
        local ext_dir="$HOME/.local/share/gnome-shell/extensions/$EXT_UUID"
        if [ -d "$ext_dir" ]; then
            print_status "info" "Extension files are present at: $ext_dir"
            print_status "info" "The extension will be available after you:"
            print_status "config" "1. Log out and log back in, OR"
            print_status "config" "2. Restart GNOME Shell: Alt+F2, type 'r', press Enter"
        else
            print_status "error" "Extension files not found"
            print_status "info" "Install manually from: https://extensions.gnome.org/extension/5979/"
        fi
        return 1
    fi
}

uninstall_dim_calendar_events() {
    print_status "section" "UNINSTALL DIM COMPLETED CALENDAR EVENTS"

    local EXT_UUID="dim-completed-calendar-events@marcinjahn.com"

    if ! gnome-extensions list 2>/dev/null | grep -q "$EXT_UUID"; then
        local ext_dir="$HOME/.local/share/gnome-shell/extensions/$EXT_UUID"
        if [ ! -d "$ext_dir" ]; then
            print_status "info" "Extension is not installed, nothing to do"
            return 0
        fi
    fi

    print_status "info" "Disabling extension..."
    gnome-extensions disable "$EXT_UUID" 2>/dev/null || true

    print_status "info" "Uninstalling extension..."
    if gnome-extensions uninstall "$EXT_UUID" 2>&1 | tee -a "$LOG_FILE"; then
        print_status "success" "Extension uninstalled"
    else
        local ext_dir="$HOME/.local/share/gnome-shell/extensions/$EXT_UUID"
        if [ -d "$ext_dir" ]; then
            rm -rf "$ext_dir"
            print_status "success" "Extension removed manually"
        fi
    fi

    print_status "info" "Calendar dropdown restored to default behavior"
}

# ============================================================================
# COMMUNICATION / COLLABORATION
# ============================================================================

install_slack() {
    print_status "section" "SLACK"

    if command_exists slack || snap list 2>/dev/null | grep -q "^slack " || flatpak list 2>/dev/null | grep -q com.slack.Slack; then
        print_status "info" "Slack already installed"
        return 0
    fi

    cd "$DOWNLOADS_DIR" || return 1

    case "$PACKAGE_MANAGER" in
        apt)
            print_status "info" "Downloading Slack..."
            if wget -O slack-desktop-latest-amd64.deb "https://downloads.slack-edge.com/desktop-releases/linux/x64/latest/slack-desktop-latest-amd64.deb" 2>&1 | tee -a "$LOG_FILE"; then
                if [ -f "slack-desktop-latest-amd64.deb" ] && [ -s "slack-desktop-latest-amd64.deb" ]; then
                    print_status "info" "Installing Slack..."
                    run_or_echo sudo dpkg -i slack-desktop-latest-amd64.deb || {
                        print_status "warning" "dpkg installation had issues, fixing dependencies..."
                        run_or_echo sudo apt-get install -f -y
                    }

                    if command_exists slack || dpkg -l | grep -q slack; then
                        print_status "success" "Slack installed successfully"
                    else
                        print_status "warning" "Slack package installation failed, trying Snap..."
                        if command_exists snap; then
                            run_or_echo sudo snap install slack
                            print_status "success" "Slack installed via Snap"
                        fi
                    fi
                else
                    print_status "error" "Download failed, trying alternative method..."
                    if command_exists snap; then
                        run_or_echo sudo snap install slack
                        print_status "success" "Slack installed via Snap"
                    fi
                fi
            else
                print_status "error" "Download failed, trying Snap..."
                if command_exists snap; then
                    run_or_echo sudo snap install slack
                    print_status "success" "Slack installed via Snap"
                fi
            fi
            ;;
        dnf|yum)
            print_status "info" "Downloading Slack..."
            if wget -O slack-latest.rpm "https://downloads.slack-edge.com/desktop-releases/linux/x64/latest/slack-latest.x86_64.rpm" 2>&1 | tee -a "$LOG_FILE"; then
                print_status "info" "Installing Slack..."
                sudo $PACKAGE_MANAGER install -y slack-latest.rpm
                print_status "success" "Slack installed"
            else
                print_status "error" "Download failed, trying Flatpak..."
                if command_exists flatpak; then
                    run_or_echo flatpak install -y flathub com.slack.Slack
                    print_status "success" "Slack installed via Flatpak"
                fi
            fi
            ;;
        pacman)
            print_status "info" "Installing Slack..."
            if command_exists yay; then
                run_or_echo yay -S --noconfirm slack-desktop
                print_status "success" "Slack installed from AUR"
            else
                print_status "warning" "yay not found. Installing via Flatpak..."
                if command_exists flatpak; then
                    run_or_echo flatpak install -y flathub com.slack.Slack
                    print_status "success" "Slack installed via Flatpak"
                else
                    print_status "error" "Please install yay or Flatpak first"
                    return 1
                fi
            fi
            ;;
        zypper)
            print_status "info" "Downloading Slack..."
            if wget -O slack-latest.rpm "https://downloads.slack-edge.com/desktop-releases/linux/x64/latest/slack-latest.x86_64.rpm" 2>&1 | tee -a "$LOG_FILE"; then
                print_status "info" "Installing Slack..."
                $INSTALL_CMD slack-latest.rpm
                print_status "success" "Slack installed"
            else
                print_status "error" "Download failed, trying Flatpak..."
                if command_exists flatpak; then
                    run_or_echo flatpak install -y flathub com.slack.Slack
                    print_status "success" "Slack installed via Flatpak"
                fi
            fi
            ;;
    esac

    local slack_verified=0
    if command_exists slack; then
        print_status "success" "Slack is ready to use"
        print_status "info" "Launch with: slack"
        slack_verified=1
    elif snap list 2>/dev/null | grep -q "^slack "; then
        print_status "success" "Slack installed via Snap"
        print_status "info" "Launch with: slack"
        slack_verified=1
    elif flatpak list 2>/dev/null | grep -q com.slack.Slack; then
        print_status "success" "Slack installed via Flatpak"
        print_status "info" "Launch with: flatpak run com.slack.Slack"
        slack_verified=1
    else
        print_status "warning" "Slack installation could not be verified"
        print_status "info" "You can install Slack manually from https://slack.com/downloads/linux"
    fi

    cd - > /dev/null || return 1
    [ "$slack_verified" -eq 1 ] || return 1
}

configure_gsconnect() {
    print_status "section" "GSCONNECT CONFIGURATION"

    print_status "info" "Installing GNOME Shell extensions support..."
    run_or_echo sudo apt install -y gnome-shell-extensions chrome-gnome-shell

    if gnome-extensions list | grep -q gsconnect; then
        print_status "info" "Enabling GSConnect..."
        gnome-extensions enable gsconnect@andyholmes.github.io
        print_status "success" "GSConnect enabled"
    else
        print_status "warning" "GSConnect extension not found. Install it from extensions.gnome.org"
        return 1
    fi
}

# ============================================================================
# SNAP / FLATPAK ROLLUP INSTALLERS
# ============================================================================

install_snap_apps() {
    print_status "section" "SNAP APPLICATIONS"

    local apps=(
        "notion-snap-reborn:Notion"
        "postman:Postman"
        "spotify:Spotify"
    )

    for app_info in "${apps[@]}"; do
        IFS=':' read -r snap_name display_name <<< "$app_info"

        if snap list | grep -q "$snap_name"; then
            print_status "info" "$display_name already installed"
        else
            print_status "info" "Installing $display_name..."
            run_or_echo sudo snap install "$snap_name"
            print_status "success" "$display_name installed"
        fi
    done
}

install_flatpak_apps() {
    print_status "section" "FLATPAK APPLICATIONS"

    local apps=(
        "me.iepure.devtoolbox:Dev Toolbox"
        "com.github.ADBeveridge.Raider:Raider (File Shredder)"
        "io.missioncenter.MissionCenter:Mission Center"
        "io.github.thetumultuousunicornofdarkness.cpu-x:CPU-X"
        "org.gnome.NetworkDisplays:Network Displays"
        "org.freedesktop.Piper:Piper"
        "com.notepadqq.Notepadqq:Notepadqq"
    )

    for app_info in "${apps[@]}"; do
        IFS=':' read -r app_id display_name <<< "$app_info"

        if flatpak list | grep -q "$app_id"; then
            print_status "info" "$display_name already installed"
        else
            print_status "info" "Installing $display_name..."
            run_or_echo flatpak install -y flathub "$app_id"
            print_status "success" "$display_name installed"
        fi
    done
}

# ============================================================================
# INDIVIDUAL UTILITIES
# ============================================================================

install_fastfetch() {
    if command_exists fastfetch; then
        print_status "info" "fastfetch already installed"
        return 0
    fi

    print_status "info" "Installing fastfetch..."

    case "$PACKAGE_MANAGER" in
        apt)
            if $INSTALL_CMD fastfetch; then
                print_status "success" "fastfetch installed from apt repositories"
            else
                print_status "warning" "fastfetch not available via apt, trying official .deb release..."

                local arch download_arch tmp_dir deb_url
                arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
                case "$arch" in
                    amd64|x86_64)   download_arch="amd64" ;;
                    arm64|aarch64)  download_arch="aarch64" ;;
                    armhf|armv7l)   download_arch="armv7l" ;;
                    *)
                        print_status "warning" "Unsupported architecture for fastfetch .deb fallback: $arch"
                        return 1
                        ;;
                esac

                tmp_dir=$(mktemp -d)
                deb_url="https://github.com/fastfetch-cli/fastfetch/releases/latest/download/fastfetch-linux-${download_arch}.deb"

                if wget -O "$tmp_dir/fastfetch.deb" "$deb_url" 2>>"$LOG_FILE" || \
                   run_or_echo curl -L -o "$tmp_dir/fastfetch.deb" "$deb_url" 2>>"$LOG_FILE"; then
                    if run_or_echo sudo apt-get install -y "$tmp_dir/fastfetch.deb"; then
                        print_status "success" "fastfetch installed from official .deb"
                    else
                        print_status "warning" "fastfetch .deb installation failed"
                    fi
                else
                    print_status "warning" "Failed to download fastfetch .deb from official releases"
                fi

                rm -rf "$tmp_dir"
            fi
            ;;
        dnf|yum|pacman|zypper)
            install_package "fastfetch" "fastfetch" "fastfetch" "fastfetch" || print_status "warning" "fastfetch installation failed"
            ;;
    esac

    if command_exists fastfetch; then
        print_status "success" "fastfetch is ready: $(fastfetch --version 2>/dev/null | head -n1)"
    else
        print_status "warning" "fastfetch could not be installed automatically"
        return 1
    fi
}

install_flameshot() {
    print_status "section" "FLAMESHOT SCREENSHOT TOOL"

    if command_exists flameshot; then
        print_status "info" "Flameshot already installed"
        return 0
    fi

    print_status "info" "Installing Flameshot..."
    install_package "flameshot" "flameshot" "flameshot" "flameshot"

    print_status "success" "Flameshot installed"
    print_status "info" "Usage: flameshot gui (for interactive screenshot tool)"
    print_status "info" "You can set up keyboard shortcuts for quick access"
}

install_rofi() {
    print_status "section" "ROFI LAUNCHER"

    if command_exists rofi; then
        print_status "info" "Rofi already installed"
        return 0
    fi

    print_status "info" "Installing Rofi..."
    install_package "rofi" "rofi" "rofi" "rofi"

    print_status "success" "Rofi installed"
    print_status "info" "Used by Super+J shortcut cheat-sheet popup"
}

install_pinta() {
    print_status "section" "PINTA IMAGE EDITOR"

    if command_exists pinta || flatpak list 2>/dev/null | grep -q "com.github.PintaProject.Pinta" || dpkg -l 2>/dev/null | grep -q "^ii  pinta "; then
        print_status "info" "Pinta already installed"
        return 0
    fi

    print_status "info" "Installing Pinta image editor..."

    case "$PACKAGE_MANAGER" in
        apt)
            if install_package "pinta" "pinta" "pinta" "pinta"; then
                print_status "success" "Pinta installed via system package manager"
            else
                print_status "warning" "Pinta not available in repositories, trying Flatpak..."
                if command_exists flatpak; then
                    run_or_echo flatpak install -y flathub com.github.PintaProject.Pinta
                    print_status "success" "Pinta installed via Flatpak"
                else
                    print_status "error" "Could not install Pinta. Please install manually."
                    return 1
                fi
            fi
            ;;
        dnf|yum)
            if command_exists flatpak; then
                run_or_echo flatpak install -y flathub com.github.PintaProject.Pinta
                print_status "success" "Pinta installed via Flatpak"
            else
                print_status "warning" "Flatpak not available, trying system repositories..."
                if install_package "pinta" "pinta" "pinta" "pinta"; then
                    print_status "success" "Pinta installed via system package manager"
                else
                    print_status "error" "Could not install Pinta. Please install Flatpak first or install Pinta manually."
                    return 1
                fi
            fi
            ;;
        pacman)
            if command_exists yay; then
                run_or_echo yay -S --noconfirm pinta
                print_status "success" "Pinta installed from AUR"
            elif command_exists flatpak; then
                run_or_echo flatpak install -y flathub com.github.PintaProject.Pinta
                print_status "success" "Pinta installed via Flatpak"
            else
                print_status "warning" "Please install Pinta manually: yay -S pinta or enable Flatpak"
                return 1
            fi
            ;;
        zypper)
            if command_exists flatpak; then
                run_or_echo flatpak install -y flathub com.github.PintaProject.Pinta
                print_status "success" "Pinta installed via Flatpak"
            else
                if install_package "pinta" "pinta" "pinta" "pinta"; then
                    print_status "success" "Pinta installed via system package manager"
                else
                    print_status "error" "Could not install Pinta. Please install Flatpak first."
                    return 1
                fi
            fi
            ;;
    esac

    if command_exists pinta || flatpak list 2>/dev/null | grep -q "com.github.PintaProject.Pinta"; then
        print_status "success" "Pinta image editor is ready to use"
        print_status "info" "Pinta: Simple yet powerful image editing tool"
        print_status "config" "Alternative to Paint.NET for Linux"
        print_status "config" "Launch with: pinta"

        if flatpak list 2>/dev/null | grep -q "com.github.PintaProject.Pinta"; then
            print_status "config" "Or if installed via Flatpak: flatpak run com.github.PintaProject.Pinta"
        fi
    else
        print_status "warning" "Pinta installation could not be verified"
        print_status "info" "You can install Pinta manually:"
        print_status "config" "Flatpak: flatpak install flathub com.github.PintaProject.Pinta"
        print_status "config" "Or visit: https://www.pinta-project.com/"
        return 1
    fi
}

install_gimp() {
    print_status "section" "GIMP IMAGE EDITOR"

    if command_exists gimp || flatpak list --app 2>/dev/null | grep -q "org.gimp.GIMP"; then
        print_status "info" "GIMP already installed"
        return 0
    fi

    setup_flatpak

    # No official .deb from the GIMP project (distro packages exist but lag
    # the 3.x series). Flatpak is the vendor-recommended channel on Linux —
    # method #2 in the "App Installation Preference Order" below.
    print_status "info" "Installing GIMP via Flatpak..."
    run_or_echo flatpak install -y flathub org.gimp.GIMP
    print_status "success" "GIMP installed via Flatpak"
    print_status "config" "Launch with: flatpak run org.gimp.GIMP"
}

install_veracrypt_appimage() {
    print_status "section" "VERACRYPT APPIMAGE"

    if [ -f "$HOME/Downloads/veracrypt.AppImage" ]; then
        print_status "info" "VeraCrypt AppImage already downloaded"
        return 0
    fi

    cd "$DOWNLOADS_DIR" || return 1
    print_status "info" "Downloading VeraCrypt AppImage..."
    run_or_echo wget -O veracrypt.AppImage "https://launchpad.net/veracrypt/trunk/1.26.24/+download/VeraCrypt-1.26.24-x86_64.AppImage"
    run_or_echo chmod +x veracrypt.AppImage

    print_status "success" "VeraCrypt AppImage downloaded to $DOWNLOADS_DIR"
    cd - > /dev/null || return 1
}

# ============================================================================
# OPENLOGI (Logitech HID++ device manager — replaces Solaar, see issue #235)
# ============================================================================
# Local-first alternative to Logitech Options+. No apt/dnf/pacman repo exists
# (see distro_config CLAUDE.md "App Installation Preference Order" #1 —
# official .deb from vendor); the vendor's own download page 302-redirects
# "linux-<arch>" to the current release asset, so it doubles as a poor man's
# "latest" channel without a GitHub API call.
#
# Only one HID++ manager may hold a receiver at a time, so this repo never
# installs openlogi alongside Solaar (Solaar is fully removed — see #237).

# Verify the downloaded .deb against the release's own SHA256SUMS before it is handed to
# `sudo apt-get install`. The vendor's "latest" URL deliberately hides both the version and
# the asset name, so the redirect has to be resolved first — SHA256SUMS is published beside
# the asset it covers, in the same release directory.
#
# Fails CLOSED: an unverifiable download is not installed. A .deb is unpacked as root, so
# "could not check" and "checksum did not match" earn the same answer.
_verify_openlogi_deb() {
    local deb_file="$1" deb_url="$2"
    local effective_url asset_name sums_url sums_file actual

    if [ "${DRY_RUN:-0}" = "1" ]; then
        print_status "info" "[dry-run] would verify $deb_file against the release SHA256SUMS"
        return 0
    fi

    if ! command_exists sha256sum; then
        print_status "warning" "sha256sum unavailable — cannot verify the openlogi .deb"
        return 1
    fi

    effective_url=$(curl -fLs -o /dev/null -w '%{url_effective}' "$deb_url" 2>>"$LOG_FILE") \
        || effective_url=""
    if [ -z "$effective_url" ] || [ "$effective_url" = "$deb_url" ]; then
        print_status "warning" "Could not resolve the openlogi release asset URL for verification"
        return 1
    fi

    asset_name="${effective_url##*/}"
    sums_url="${effective_url%/*}/SHA256SUMS"
    sums_file="$(dirname "$deb_file")/SHA256SUMS"

    if ! curl -fLs -o "$sums_file" "$sums_url" 2>>"$LOG_FILE"; then
        print_status "warning" "Could not download SHA256SUMS from $sums_url"
        return 1
    fi

    actual=$(sha256sum "$deb_file" | awk '{print $1}')
    if grep -qiE "^${actual}[[:space:]]+\*?${asset_name}\$" "$sums_file"; then
        print_status "success" "openlogi .deb verified against $asset_name"
        return 0
    fi

    print_status "error" "Checksum mismatch — $asset_name not matched in SHA256SUMS"
    return 1
}

_openlogi_download_arch() {
    local arch="$1"
    case "$arch" in
        amd64|x86_64)  echo "x64" ;;
        arm64|aarch64) echo "arm64" ;;
        *)             return 1 ;;
    esac
}

install_openlogi() {
    print_status "section" "OPENLOGI"

    if command_exists openlogi; then
        print_status "info" "openlogi already installed"
    else
        print_status "info" "Installing openlogi (Logitech HID++ manager)..."

        local arch download_arch
        arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
        if ! download_arch=$(_openlogi_download_arch "$arch"); then
            print_status "warning" "openlogi has no prebuilt package for architecture: $arch"
            print_status "info" "Install manually from: https://openlogi.org/download/linux"
            return 1
        fi

        case "$PACKAGE_MANAGER" in
            apt)
                local tmp_dir deb_url
                tmp_dir=$(mktemp -d)
                deb_url="https://openlogi.org/download/linux-${download_arch}"

                if run_or_echo curl -fL -o "$tmp_dir/openlogi.deb" "$deb_url" 2>>"$LOG_FILE"; then
                    if _verify_openlogi_deb "$tmp_dir/openlogi.deb" "$deb_url"; then
                        if run_or_echo sudo apt-get install -y "$tmp_dir/openlogi.deb"; then
                            print_status "success" "openlogi installed from official .deb"
                        else
                            print_status "warning" "openlogi .deb installation failed"
                        fi
                    else
                        print_status "error" "openlogi .deb failed checksum verification — NOT installing"
                    fi
                else
                    print_status "warning" "Failed to download openlogi .deb from $deb_url"
                fi
                rm -rf "$tmp_dir"
                ;;
            dnf|yum|pacman|zypper)
                print_status "warning" "openlogi has no $PACKAGE_MANAGER repository; only the .deb download is automated"
                print_status "info" "Download the .rpm / .pkg.tar.zst manually from: https://openlogi.org/download/linux"
                return 1
                ;;
            *)
                print_status "warning" "openlogi installation is not automated for $PACKAGE_MANAGER"
                print_status "info" "Install manually from: https://openlogi.org/download/linux"
                return 1
                ;;
        esac
    fi

    _link_openlogi_config

    if command_exists systemctl; then
        print_status "info" "Enabling openlogi-agent user service..."
        run_or_echo systemctl --user enable --now openlogi-agent.service 2>>"$LOG_FILE" \
            || print_status "warning" "Could not enable openlogi-agent.service — enable manually after next login"
    fi

    verify_openlogi
}

# Symlink the repo-tracked config.toml into ~/.config/openlogi/ so button/DPI/
# SmartShift bindings survive a reinstall. Any pre-existing non-symlink file
# is backed up rather than clobbered (bindings don't auto-migrate from Solaar
# — see #237).
_link_openlogi_config() {
    local repo_root source_file config_dir target_file
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || return 1
    source_file="$repo_root/distro_config/dotfiles/openlogi/config.toml"
    config_dir="$HOME/.config/openlogi"
    target_file="$config_dir/config.toml"

    if [ ! -f "$source_file" ]; then
        print_status "warning" "Tracked openlogi config.toml not found at $source_file"
        return 1
    fi

    run_or_echo mkdir -p "$config_dir"

    if [ -L "$target_file" ] && [ "$(readlink -f "$target_file")" = "$(readlink -f "$source_file")" ]; then
        print_status "info" "openlogi config.toml already symlinked"
        return 0
    fi

    if [ -e "$target_file" ] && [ ! -L "$target_file" ]; then
        print_status "info" "Backing up existing openlogi config.toml..."
        run_or_echo mv "$target_file" "$target_file.bak.$(date +%Y%m%d%H%M%S)"
    fi

    run_or_echo ln -sf "$source_file" "$target_file"
    print_status "success" "openlogi config.toml symlinked from repo"
}

verify_openlogi() {
    print_status "info" "Verifying openlogi installation..."

    if command_exists openlogi; then
        print_status "success" "openlogi is ready"
        print_status "info" "openlogi: Logitech HID++ manager — GUI: 'openlogi-desktop', CLI: 'openlogi'"
        print_status "info" "Bindings live in ~/.config/openlogi/config.toml (tracked in this repo)"
    else
        print_status "warning" "openlogi could not be verified"
        print_status "info" "Install manually from: https://openlogi.org/download/linux"
        return 1
    fi
}

# ============================================================================
# UTILITIES ROLLUP (calls fastfetch + 4k_video_downloader)
# ============================================================================
# install_4k_video_downloader lives in media.sh; it'll be available at call time
# because all install_lib/*.sh are sourced before any install runs.

install_utilities() {
    print_status "section" "SYSTEM UTILITIES"

    install_fastfetch || print_status "warning" "fastfetch installation failed — continuing with system utilities"

    local utilities=(
        "vim:vim:vim:vim"
        "vlc:vlc:vlc:vlc"
        "p7zip-full:p7zip:p7zip-full:p7zip"
        "timeshift:timeshift:timeshift:timeshift"
        "kdeconnect:kdeconnect:kdeconnect:kdeconnect"
        "flameshot:flameshot:flameshot:flameshot"
        "lynx:lynx:lynx:lynx"
    )

    for util_info in "${utilities[@]}"; do
        IFS=':' read -r display debian fedora arch <<< "$util_info"

        local check_cmd="${debian%% *}"
        if command_exists "$check_cmd" || dpkg -l 2>/dev/null | grep -q "^ii  $debian " || rpm -q "$fedora" &>/dev/null || pacman -Q "$arch" &>/dev/null; then
            print_status "info" "$display already installed"
        else
            print_status "info" "Installing $display..."
            install_package "$display" "$debian" "$fedora" "$arch" || print_status "warning" "$display installation failed"
        fi
    done

    install_4k_video_downloader || print_status "warning" "4K Video Downloader Plus installation failed — continuing with system utilities"

    print_status "info" "Installing Piper (gaming device configuration)..."
    case "$PACKAGE_MANAGER" in
        apt)
            install_package "Piper" "piper" "piper" "piper" || {
                print_status "info" "Installing Piper via Flatpak..."
                run_or_echo flatpak install -y flathub org.freedesktop.Piper 2>/dev/null || print_status "warning" "Piper installation failed"
            }
            ;;
        dnf|yum|pacman)
            install_package "Piper" "piper" "piper" "piper" || print_status "warning" "Piper not available, try: flatpak install flathub org.freedesktop.Piper"
            ;;
    esac

    case "$PACKAGE_MANAGER" in
        apt)
            install_package "CopyQ" "copyq" "copyq" "copyq" || true
            install_package "Shotwell" "shotwell" "shotwell" "shotwell" || true
            install_package "VeraCrypt" "veracrypt" "veracrypt" "veracrypt" || true
            install_package "LibreOffice" "libreoffice" "libreoffice" "libreoffice" || true
            install_package "Preload" "preload" "preload" "preload" || true
            install_package "F3" "f3" "f3" "f3" || true
            if ! command_exists calibre; then
                print_status "info" "Installing Calibre..."
                $INSTALL_CMD libxcb-cursor0
                sudo -v && run_or_echo wget -nv -O- https://download.calibre-ebook.com/linux-installer.sh | run_or_echo sudo sh /dev/stdin || true
            fi
            ;;
        dnf|yum)
            $INSTALL_CMD copyq shotwell libreoffice calibre f3 || true
            ;;
        pacman)
            $INSTALL_CMD copyq shotwell libreoffice calibre f3 || true
            ;;
    esac

    print_status "success" "System utilities installed"
    print_status "info" "Piper: Gaming device configuration tool"
    print_status "info" "Flameshot: Screenshot tool - launch with 'flameshot' command"
    print_status "info" "Lynx: Terminal-based web browser - launch with 'lynx' command"
}

# ============================================================================
# COOLERCONTROL (fan/pump/AIO control + temperature dashboard)
# ============================================================================
# Routes follow https://docs.coolercontrol.org/installation/. Upstream warns that two active
# sources for one distro (Copr + Terra, distro package + OBS) cause version conflicts, so every
# route that ADDS a source first checks no CoolerControl source is already configured.
# Board-specific extras (liquidctl, it87-dkms, nct6687d-dkms) are deliberately not installed.

COOLERCONTROL_APT_URL="https://apt.coolercontrol.org"
COOLERCONTROL_KEYRING="/usr/share/keyrings/coolercontrol-archive-keyring.gpg"
COOLERCONTROL_APT_SOURCES="/etc/apt/sources.list.d/coolercontrol.sources"

# Same tree choice as upstream's setup.sh: Ubuntu-based ids/ID_LIKE → ubuntu, plain Debian →
# debian, anything unknown → ubuntu. Kali and Mint report ID_LIKE=debian but belong on ubuntu.
_coolercontrol_apt_tree() {
    local id="" id_like=""
    if [ -r /etc/os-release ]; then
        id=$(. /etc/os-release && echo "${ID-}")
        id_like=$(. /etc/os-release && echo "${ID_LIKE-}")
    fi
    case " $id " in
        " ubuntu "|" pop "|" elementary "|" neon "|" zorin "|" kali ") echo ubuntu; return ;;
        " debian ") echo debian; return ;;
    esac
    case " $id_like " in
        *" ubuntu "*) echo ubuntu ;;
        *" debian "*) echo debian ;;
        *)            echo ubuntu ;;
    esac
}

# Match on content, not file name: the old Cloudsmith entry (and hand-written variants) would
# otherwise stay active beside apt.coolercontrol.org. Mirrors upstream's setup.sh.
_coolercontrol_disable_cloudsmith_sources() {
    local file
    for file in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [ -f "$file" ] || continue
        [ "$file" = "$COOLERCONTROL_APT_SOURCES" ] && continue
        grep -qi 'coolercontrol' "$file" 2>/dev/null || continue
        grep -q 'dl\.cloudsmith\.io' "$file" 2>/dev/null || continue
        print_status "info" "Disabling old CoolerControl source: $file"
        run_or_echo sudo mv "$file" "$file.disabled"
    done
}

_coolercontrol_install_apt() {
    local tree
    tree=$(_coolercontrol_apt_tree)
    refresh_apt_keyring "$COOLERCONTROL_APT_URL/coolercontrol-archive-keyring.gpg" \
        "$COOLERCONTROL_KEYRING" || return 1
    # Fixed file name, rewritten each run: re-running can never stack a second repo line.
    printf 'Types: deb\nURIs: %s/%s\nSuites: stable\nComponents: main\nSigned-By: %s\n' \
        "$COOLERCONTROL_APT_URL" "$tree" "$COOLERCONTROL_KEYRING" \
        | run_or_echo sudo tee "$COOLERCONTROL_APT_SOURCES"
    _coolercontrol_disable_cloudsmith_sources
    run_or_echo sudo apt-get update -y
    $INSTALL_CMD coolercontrol
}

_coolercontrol_install_dnf() {
    if ! grep -qis coolercontrol /etc/yum.repos.d/*.repo; then
        $INSTALL_CMD dnf-plugins-core
        run_or_echo sudo dnf copr enable -y codifryed/CoolerControl
    fi
    $INSTALL_CMD coolercontrol
}

_coolercontrol_install_pacman() {
    local helper
    for helper in yay paru; do
        if command_exists "$helper"; then
            run_or_echo "$helper" -S --noconfirm coolercontrol-bin
            return
        fi
    done
    print_status "warning" "CoolerControl is AUR-only on Arch: install yay or paru, then re-run"
}

# Distro package first (Tumbleweed); the project's OBS repo only when that fails and no
# CoolerControl repo is configured yet.
_coolercontrol_install_zypper() {
    $INSTALL_CMD coolercontrol && return
    if zypper lr -u 2>/dev/null | grep -qi coolercontrol; then
        return 1
    fi
    run_or_echo sudo zypper addrepo \
        https://download.opensuse.org/repositories/home:codifryed/openSUSE_Tumbleweed/home:codifryed.repo
    run_or_echo sudo zypper refresh
    $INSTALL_CMD coolercontrol
}

install_coolercontrol() {
    print_status "section" "COOLERCONTROL"

    if command_exists coolercontrol; then
        print_status "info" "CoolerControl already installed"
    else
        case "$PACKAGE_MANAGER" in
            apt)    _coolercontrol_install_apt    || return 1 ;;
            dnf)    _coolercontrol_install_dnf    || return 1 ;;
            pacman) _coolercontrol_install_pacman || return 1 ;;
            zypper) _coolercontrol_install_zypper || return 1 ;;
            *)
                print_status "warning" "No CoolerControl route for '$PACKAGE_MANAGER' — see https://docs.coolercontrol.org/installation/appimage.html"
                return 0
                ;;
        esac
    fi

    # The daemon does the hardware control; enable --now is idempotent.
    run_or_echo sudo systemctl enable --now coolercontrold

    if [ "${DRY_RUN:-0}" != "1" ] && ! command_exists coolercontrol; then
        print_status "warning" "CoolerControl installation could not be verified"
        return 1
    fi
    print_status "success" "CoolerControl ready"
}

install_gsmartcontrol() {
    print_status "section" "GSMARTCONTROL (disk SMART health)"

    if command_exists gsmartcontrol; then
        print_status "info" "GSmartControl already installed"
        return 0
    fi

    print_status "info" "Installing GSmartControl (pulls in smartmontools)..."
    install_package "gsmartcontrol" "gsmartcontrol" "gsmartcontrol" "gsmartcontrol" || return 1

    print_status "success" "GSmartControl installed"
}

install_nvtop() {
    print_status "section" "NVTOP (per-process GPU usage)"

    if command_exists nvtop; then
        print_status "info" "nvtop already installed"
        return 0
    fi

    print_status "info" "Installing nvtop..."
    install_package "nvtop" "nvtop" "nvtop" "nvtop" || return 1

    print_status "success" "nvtop installed"
    print_status "info" "Usage: nvtop (terminal app; NVIDIA, AMD and Intel GPUs)"
}

# ============================================================================
# GOOGLE AUTHENTICATOR (optional TOTP second factor, issue #676)
# ============================================================================

_GA_PAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../pam" && pwd)"
_GA_PAM_PROFILE="/usr/share/pam-configs/google-authenticator"
_GA_SSHD_DROPIN="/etc/ssh/sshd_config.d/google-authenticator.conf"

# Installs the package and enables a pam-auth-update profile (nullok, so a
# user who has not run `google-authenticator` still logs in with the password
# alone). Never edits /etc/pam.d/* — pam-auth-update regenerates common-auth.
# Enrollment stays manual: see docs/totp-2fa.md.
install_google_authenticator() {
    print_status "section" "GOOGLE AUTHENTICATOR (TOTP 2FA)"

    if [ "$PACKAGE_MANAGER" != "apt" ]; then
        print_status "error" "pam-auth-update is Debian/Ubuntu only"
        return 1
    fi

    run_or_echo sudo apt-get install -y libpam-google-authenticator || return 1
    run_or_echo sudo install -m 0644 "$_GA_PAM_DIR/google-authenticator" \
        "$_GA_PAM_PROFILE" || return 1
    run_or_echo sudo pam-auth-update --enable google-authenticator || return 1

    if command_exists sshd; then
        run_or_echo sudo install -m 0644 \
            "$_GA_PAM_DIR/sshd-google-authenticator.conf" "$_GA_SSHD_DROPIN" || return 1
        if ! run_or_echo sudo sshd -t; then
            print_status "error" "sshd -t rejected the drop-in; removing it"
            run_or_echo sudo rm -f "$_GA_SSHD_DROPIN"
            return 1
        fi
    else
        print_status "info" "openssh-server not installed; skipping the ssh drop-in"
    fi

    print_status "success" "TOTP profile enabled (not enrolled yet)"
    print_status "info" "Keep a root shell open, then run: google-authenticator"
}

uninstall_google_authenticator() {
    print_status "section" "UNINSTALL GOOGLE AUTHENTICATOR (TOTP 2FA)"

    run_or_echo sudo pam-auth-update --disable google-authenticator || return 1
    run_or_echo sudo rm -f "$_GA_SSHD_DROPIN" "$_GA_PAM_PROFILE"
    print_status "success" "TOTP profile disabled and ssh drop-in removed"
}

# ============================================================================
# REGISTRY
# ============================================================================
# Entry order = run order. uninstall_dim_calendar_events is NOT registered
# here on purpose (issue #342): a registry entry runs during Full
# Installation too, which would install the extension and immediately
# uninstall it again. It stays a plain function — run it manually with
# `bash -c 'source distro_config/install_lib/system_utils.sh; uninstall_dim_calendar_events'`
# if you need to remove the extension.

INSTALL_REGISTRY+=(
    "install_utilities:System Utilities::"
    "install_openlogi:openlogi (Logitech HID++ manager):Sistema:"
    "install_fastfetch:fastfetch (system info)::"
    "install_flameshot:Flameshot Screenshot Tool:Utilitarios:org.flameshot.Flameshot.desktop"
    # gnome_folder is Sistema, not Utilitarios: Rofi was duplicated into both
    # System (this file's own hardcoded system_app_names list in
    # ubuntu_workspace.sh) and Utilities (this registry entry) — System is
    # the folder that fits, per the never-Utilities-on-a-tie rule (#391).
    "install_rofi:Rofi Launcher:Sistema:rofi.desktop"
    "install_pinta:Pinta Image Editor:Design:com.github.PintaProject.Pinta.desktop"
    "install_gimp:GIMP Image Editor:Design:org.gimp.GIMP.desktop"
    "install_veracrypt_appimage:VeraCrypt AppImage::"
    "install_slack:Slack:Social:slack_slack.desktop"
    "install_snap_apps:Snap Applications::"
    "install_flatpak_apps:Flatpak Applications::"
    "install_vitals:Vitals System Monitor::"
    "install_coolercontrol:CoolerControl:Monitoring:org.coolercontrol.CoolerControl.desktop"
    "install_gsmartcontrol:GSmartControl (disk SMART health):Monitoring:gsmartcontrol.desktop"
    "install_nvtop:nvtop (GPU process monitor):Monitoring:nvtop.desktop"
    "install_google_authenticator:Google Authenticator (TOTP 2FA)::"
    "install_dim_calendar_events:Calendar Events Enhancement::"
    "configure_gsconnect:GSConnect::"
)
