#!/bin/bash
#
# distro_config/install_programs.sh
#
# Multi-distribution development environment setup — desktop programs.
# Coding-side tools (docker, vscode, languages, AI CLIs) live in install_coding.sh.
#
# Architecture:
#   - distro_config/install_lib/_common.sh      Shared utilities + INSTALL_REGISTRY infra
#   - distro_config/install_lib/<category>.sh   One file per category, each ending in an
#                                               INSTALL_REGISTRY+=( ... ) block
#   - This file is the orchestrator: sources lib/_common.sh, sources every lib/*.sh,
#     declares framework steps, then drives the menu loop.
#
# Failure policy: failures during 'Full Installation' are collected and reported at the
# end (see run_install in _common.sh). The orchestrator does NOT use `set -e` — each
# install function runs in a subshell where set -e applies locally, so failures stop
# the function but not the whole run.

# Resolve the orchestrator's own directory so we can find install_lib/.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Override default LOG_FILE before sourcing _common.sh
LOG_FILE="$HOME/setup_$(date +%Y%m%d_%H%M%S).log"

# ----------------------------------------------------------------------------
# 1. Source utilities
# ----------------------------------------------------------------------------

if [ ! -f "$SCRIPT_DIR/install_lib/_common.sh" ]; then
    echo "Missing $SCRIPT_DIR/install_lib/_common.sh — orchestrator cannot start." >&2
    exit 1
fi
# shellcheck source=install_lib/_common.sh
source "$SCRIPT_DIR/install_lib/_common.sh"

# ----------------------------------------------------------------------------
# 2. Framework install steps (specific to install_programs.sh)
# ----------------------------------------------------------------------------

create_dev_folder() {
    print_status "section" "DEVELOPMENT DIRECTORY"

    local dev_dir="$HOME/dev"
    if [ -d "$dev_dir" ]; then
        print_status "info" "Development directory already exists: $dev_dir"
        return 0
    fi

    print_status "info" "Creating development directory at $dev_dir..."
    mkdir -p "$dev_dir"
    chmod 755 "$dev_dir" 2>/dev/null || true

    if [ -d "$dev_dir" ]; then
        print_status "success" "Development directory created: $dev_dir"
    else
        print_status "error" "Failed to create development directory: $dev_dir"
        return 1
    fi
}

update_system() {
    print_status "section" "SYSTEM UPDATE"
    print_status "info" "Updating package lists..."
    $UPDATE_CMD || { print_status "error" "Failed to update package lists"; return 1; }

    print_status "info" "Upgrading installed packages..."
    $UPGRADE_CMD || print_status "warning" "Some packages failed to upgrade"

    print_status "success" "System updated successfully"
}

setup_firewall() {
    print_status "section" "FIREWALL SETUP"

    case "$PACKAGE_MANAGER" in
        apt)
            print_status "info" "Enabling UFW firewall..."
            command_exists ufw || $INSTALL_CMD ufw
            run_or_echo sudo ufw --force enable
            ;;
        dnf|yum)
            print_status "info" "Enabling firewalld..."
            command_exists firewall-cmd || $INSTALL_CMD firewalld
            run_or_echo sudo systemctl enable --now firewalld
            ;;
        pacman)
            print_status "info" "Installing UFW..."
            command_exists ufw || $INSTALL_CMD ufw
            run_or_echo sudo systemctl enable --now ufw
            run_or_echo sudo ufw --force enable
            ;;
        zypper)
            print_status "info" "Enabling firewalld..."
            command_exists firewall-cmd || $INSTALL_CMD firewalld
            run_or_echo sudo systemctl enable --now firewalld
            ;;
    esac

    print_status "info" "Configuring KDE Connect ports..."
    case "$PACKAGE_MANAGER" in
        apt|pacman)
            run_or_echo sudo ufw allow 1714:1764/udp
            run_or_echo sudo ufw allow 1714:1764/tcp
            run_or_echo sudo ufw reload
            ;;
        dnf|yum|zypper)
            run_or_echo sudo firewall-cmd --permanent --add-port=1714-1764/tcp
            run_or_echo sudo firewall-cmd --permanent --add-port=1714-1764/udp
            run_or_echo sudo firewall-cmd --reload
            ;;
    esac

    print_status "success" "Firewall configured and enabled"
}

cleanup_system() {
    print_status "section" "SYSTEM CLEANUP"

    if [ -f /var/lib/apt/lists/lock ]; then
        print_status "warning" "Apt lock detected, trying to release..."
        run_or_echo sudo rm -f /var/lib/apt/lists/lock
        run_or_echo sudo rm -f /var/lib/dpkg/lock
        run_or_echo sudo rm -f /var/lib/dpkg/lock-frontend
    fi

    run_or_echo sudo systemctl stop packagekitd 2>/dev/null || true

    print_status "info" "Listing upgradable packages..."
    case "$PACKAGE_MANAGER" in
        apt)        run_or_echo sudo apt list --upgradable >> "$LOG_FILE" 2>&1 || true ;;
        dnf|yum)    run_or_echo sudo "$PACKAGE_MANAGER" list upgrades >> "$LOG_FILE" 2>&1 || true ;;
        pacman)     pacman -Qu >> "$LOG_FILE" 2>&1 || true ;;
    esac

    print_status "info" "Running full upgrade..."
    case "$PACKAGE_MANAGER" in
        apt)        run_or_echo sudo apt full-upgrade -y ;;
        dnf|yum)    run_or_echo sudo $PACKAGE_MANAGER upgrade -y ;;
        pacman)     run_or_echo sudo pacman -Syu --noconfirm ;;
        zypper)     run_or_echo sudo zypper update -y ;;
    esac

    print_status "info" "Removing unnecessary packages..."
    case "$PACKAGE_MANAGER" in
        apt)        run_or_echo sudo apt autoremove -y && run_or_echo sudo apt clean ;;
        dnf|yum)    run_or_echo sudo $PACKAGE_MANAGER autoremove -y && run_or_echo sudo $PACKAGE_MANAGER clean all ;;
        pacman)     run_or_echo sudo pacman -Sc --noconfirm ;;
        zypper)     run_or_echo sudo zypper clean -a ;;
    esac

    print_status "success" "System cleaned up"
}

# ----------------------------------------------------------------------------
# 3. Source category lib files (alphabetical via glob; _common.sh excluded)
# ----------------------------------------------------------------------------

# Glob excludes _common.sh and any other leading-underscore file (reserved for
# foundation/internal). Each category file contributes its install_* functions
# and appends to INSTALL_REGISTRY.
shopt -s nullglob
for lib in "$SCRIPT_DIR/install_lib/"[!_]*.sh; do
    # shellcheck source=/dev/null
    if ! source "$lib"; then
        print_status "error" "Failed to source $lib — orchestrator aborting."
        exit 1
    fi
done
shopt -u nullglob

# ----------------------------------------------------------------------------
# 4. Splice framework entries into INSTALL_REGISTRY
#    Prepend bootstrap (dev folder, update, firewall) and append cleanup.
#    Category-contributed entries keep their declaration order in between.
# ----------------------------------------------------------------------------

INSTALL_REGISTRY=(
    "create_dev_folder:Create ~/dev folder::"
    "update_system:System Update::"
    "setup_firewall:Firewall::"
    "${INSTALL_REGISTRY[@]}"
    "cleanup_system:System Cleanup::"
)

# ----------------------------------------------------------------------------
# 5. Validate the registry before any install runs
# ----------------------------------------------------------------------------

validate_registry

# ----------------------------------------------------------------------------
# 6. Menu + dispatch
# ----------------------------------------------------------------------------

show_menu() {
    echo -e "\n${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}   ${MAGENTA}Multi-Distribution Development Environment Setup${NC}   ${CYAN}      ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}\n"

    echo -e "${GREEN}Detected System:${NC} $DISTRO"
    echo -e "${GREEN}Package Manager:${NC} $PACKAGE_MANAGER"
    if [ -n "$UBUNTU_VERSION" ]; then
        echo -e "${GREEN}Ubuntu Version:${NC} $UBUNTU_VERSION ($UBUNTU_CODENAME)"
    fi
    echo -e "${GREEN}Registry entries:${NC} ${#INSTALL_REGISTRY[@]}"
    echo
    echo -e "${YELLOW}Select installation mode:${NC}"
    echo -e "  ${GREEN}1)${NC} Full Installation (all registry entries, failures collected)"
    echo -e "  ${GREEN}2)${NC} Custom Installation (pick entries)"
    echo -e "  ${GREEN}3)${NC} Exit"
    echo -e "\n${CYAN}Choice:${NC} "
}

# Ask the non-secret rclone questions (remote name, type, region, account
# kind, mount point) — issue #365. Only called from the interactive Custom
# Installation path; install_lib/sharing.sh itself never prompts (#339), and
# Full/unattended runs take the defaults silently by leaving these unset.
prompt_rclone_choices() {
    echo -e "\n${YELLOW}rclone setup — press Enter to accept the default:${NC}"

    read -r -p "Remote name [onedrive]: " RCLONE_REMOTE
    RCLONE_REMOTE="${RCLONE_REMOTE:-onedrive}"

    read -r -p "Remote type [onedrive]: " RCLONE_TYPE
    RCLONE_TYPE="${RCLONE_TYPE:-onedrive}"

    read -r -p "Region [global]: " RCLONE_REGION
    RCLONE_REGION="${RCLONE_REGION:-global}"

    read -r -p "Account kind, Personal or Business [Personal]: " RCLONE_ACCOUNT_KIND
    RCLONE_ACCOUNT_KIND="${RCLONE_ACCOUNT_KIND:-Personal}"

    read -r -p "Mount point [$HOME/OneDrive]: " RCLONE_MOUNT_POINT
    RCLONE_MOUNT_POINT="${RCLONE_MOUNT_POINT:-$HOME/OneDrive}"

    export RCLONE_REMOTE RCLONE_TYPE RCLONE_REGION RCLONE_ACCOUNT_KIND RCLONE_MOUNT_POINT
}

# Write the rclone.conf skeleton and the mount unit right after the binary
# installs, then enable the mount unattended — no prompt, TTY or not (#649).
# enable_rclone_mount_unit's own guards make that safe: an unauthenticated
# remote prints its refusal + `rclone config` hint and returns 1, which is
# swallowed here so the rest of the install carries on.
run_rclone_followups() {
    install_rclone_config
    install_rclone_mount_unit
    enable_rclone_mount_unit </dev/null \
        || print_status "warning" "rclone mount not enabled — fix the above, then run: make rclone_mount"
}

run_full_installation() {
    print_status "section" "FULL INSTALLATION MODE"

    local entry fn label
    for entry in "${INSTALL_REGISTRY[@]}"; do
        IFS=':' read -r fn label _ _ <<< "$entry"
        run_install "$fn" "$label"
        [ "$fn" = "install_rclone" ] && run_rclone_followups
    done

    print_status "section" "INSTALLATION COMPLETE"
    report_failures
    print_status "info" "Log file: $LOG_FILE"
}

run_custom_installation() {
    print_status "section" "CUSTOM INSTALLATION MODE"

    echo -e "\n${YELLOW}Select components to install (space-separated numbers, or 'all'):${NC}"
    local i entry _fn label
    for i in "${!INSTALL_REGISTRY[@]}"; do
        IFS=':' read -r _fn label _ _ <<< "${INSTALL_REGISTRY[$i]}"
        echo -e "  ${GREEN}$((i+1)))${NC} $label"
    done
    echo -e "\n${CYAN}Selection:${NC} "
    read -r selection

    if [[ "$selection" == "all" ]]; then
        run_full_installation
        return
    fi

    local num
    for num in $selection; do
        if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#INSTALL_REGISTRY[@]}" ]; then
            IFS=':' read -r fn label _ _ <<< "${INSTALL_REGISTRY[$((num-1))]}"
            [ "$fn" = "install_rclone" ] && prompt_rclone_choices
            run_install "$fn" "$label"
            [ "$fn" = "install_rclone" ] && run_rclone_followups
        fi
    done

    print_status "section" "CUSTOM INSTALLATION COMPLETE"
    report_failures
    print_status "info" "Log file: $LOG_FILE"

    if command_exists brew || command_exists asdf || command_exists ollama; then
        print_status "info" "Tools installed. Reload your shell:"
        print_status "config" "source ~/.bashrc"
    fi
}

main() {
    if [ "$EUID" -eq 0 ]; then
        print_status "error" "This script should NOT be run with sudo!"
        print_status "info" "Please run as: bash $0"
        exit 1
    fi

    detect_distro

    if ! check_internet; then
        print_status "error" "Internet connection required for installation"
        exit 1
    fi

    mkdir -p "$DOWNLOADS_DIR"

    while true; do
        show_menu
        read -r choice || { print_status "info" "No input (stdin closed); exiting."; exit 0; }
        case $choice in
            1) run_full_installation; break ;;
            2) run_custom_installation; break ;;
            3) print_status "info" "Installation cancelled"; exit 0 ;;
            *) print_status "error" "Invalid option. Please select 1, 2, or 3." ;;
        esac
    done
}

main "$@"
