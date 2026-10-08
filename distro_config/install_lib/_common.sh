#!/bin/bash
#
# distro_config/install_lib/_common.sh
#
# Install-system foundation. Sourced by install_programs.sh and install_coding.sh.
# Inherits shared utilities (print_status, color vars, command_exists,
# check_internet, run_or_echo) from lib/common.sh at repo root.
#
# This file owns the install-specific layer on top:
#   - Globals: LOG_FILE default, DOWNLOADS_DIR, DISTRO, PACKAGE_MANAGER, …
#   - detect_distro (+ fallback) and install_package
#   - setup_flatpak (shared because multiple categories depend on it)
#   - INSTALL_REGISTRY infrastructure: validate_registry, run_install,
#     report_failures, registry_desktop_file
#
# Sourcing contract:
#   1. Orchestrator may set LOG_FILE before sourcing (otherwise a default is used).
#   2. Orchestrator MUST call detect_distro before any install_* function.
#   3. Orchestrator declares INSTALL_REGISTRY=() before sourcing category files.

# Refuse to be executed directly
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "_common.sh is meant to be sourced, not executed." >&2
    exit 1
fi

# ----------------------------------------------------------------------------
# Inherit shared utilities from repo-root lib/common.sh.
# Path: this file is at distro_config/install_lib/_common.sh, so repo root
# is two levels up.
# ----------------------------------------------------------------------------
_this_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_repo_root="$(cd "$_this_dir/../.." && pwd)"
# Default LOG_FILE before sourcing lib/common.sh so it picks it up.
LOG_FILE="${LOG_FILE:-$HOME/setup_$(date +%Y%m%d_%H%M%S).log}"
# shellcheck source=../../lib/common.sh
source "$_repo_root/lib/common.sh"
unset _this_dir _repo_root

# ============================================================================
# INSTALL-SYSTEM GLOBALS (overridable from the orchestrator before sourcing)
# ============================================================================

DOWNLOADS_DIR="${DOWNLOADS_DIR:-$HOME/Downloads}"
DISTRO=""
PACKAGE_MANAGER=""
INSTALL_CMD=""
UPDATE_CMD=""
UPGRADE_CMD=""
UBUNTU_VERSION=""
UBUNTU_CODENAME=""

# INSTALL_REGISTRY entry format: "func:label:gnome_folder:desktop_file"
#   gnome_folder: "" | Sistema | Utilitarios | Media | Sharing | Code | Data |
#                 Infra | Design | Planning | Reading | Office | Ereader |
#                 IRPF | Seguranca | Social | Monitoring
#   desktop_file: explicit .desktop filename, or "" to derive as "${func#install_}.desktop"
INSTALL_REGISTRY=()
INSTALL_FAILURES=()

# ============================================================================
# DISTRO DETECTION
# ============================================================================

detect_distro() {
    print_status "info" "Detecting Linux distribution..."

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO=$ID
        UBUNTU_VERSION="$VERSION_ID"
        UBUNTU_CODENAME="$VERSION_CODENAME"

        case "$DISTRO" in
            ubuntu|debian|pop|linuxmint)
                PACKAGE_MANAGER="apt"
                INSTALL_CMD="sudo apt-get install -y"
                UPDATE_CMD="sudo apt update"
                UPGRADE_CMD="sudo apt upgrade -y"
                print_status "success" "Detected Debian-based system: $PRETTY_NAME"
                print_status "info" "Ubuntu Version: $UBUNTU_VERSION, Codename: $UBUNTU_CODENAME"
                ;;
            fedora|rhel|centos|rocky|almalinux)
                PACKAGE_MANAGER="dnf"
                INSTALL_CMD="sudo dnf install -y"
                UPDATE_CMD="sudo dnf check-update || true"
                UPGRADE_CMD="sudo dnf upgrade -y"
                print_status "success" "Detected Red Hat-based system: $PRETTY_NAME"
                ;;
            arch|manjaro|endeavouros)
                PACKAGE_MANAGER="pacman"
                INSTALL_CMD="sudo pacman -S --noconfirm"
                UPDATE_CMD="sudo pacman -Sy"
                UPGRADE_CMD="sudo pacman -Syu --noconfirm"
                print_status "success" "Detected Arch-based system: $PRETTY_NAME"
                ;;
            opensuse*|sles)
                PACKAGE_MANAGER="zypper"
                INSTALL_CMD="sudo zypper install -y"
                UPDATE_CMD="sudo zypper refresh"
                UPGRADE_CMD="sudo zypper update -y"
                print_status "success" "Detected openSUSE/SLES system: $PRETTY_NAME"
                ;;
            *)
                print_status "warning" "Unknown distribution: $DISTRO"
                print_status "warning" "Attempting to detect package manager..."
                detect_package_manager_fallback
                ;;
        esac
    else
        print_status "warning" "/etc/os-release not found"
        detect_package_manager_fallback
    fi

    {
        echo "DISTRO=$DISTRO"
        echo "PACKAGE_MANAGER=$PACKAGE_MANAGER"
        echo "UBUNTU_VERSION=$UBUNTU_VERSION"
        echo "UBUNTU_CODENAME=$UBUNTU_CODENAME"
    } >> "$LOG_FILE"

    # Honour DRY_RUN by prefixing the install/update/upgrade commands with
    # run_or_echo. Every `$INSTALL_CMD pkg` call site then becomes a preview
    # instead of a real install, without changing any caller.
    if [ "${DRY_RUN:-0}" = "1" ]; then
        INSTALL_CMD="run_or_echo $INSTALL_CMD"
        UPDATE_CMD="run_or_echo $UPDATE_CMD"
        UPGRADE_CMD="run_or_echo $UPGRADE_CMD"
        print_status "info" "DRY_RUN=1 — install/update/upgrade commands will be previewed, not executed."
    fi
}

detect_package_manager_fallback() {
    if command_exists apt-get; then
        PACKAGE_MANAGER="apt"
        INSTALL_CMD="sudo apt-get install -y"
        UPDATE_CMD="sudo apt update"
        UPGRADE_CMD="sudo apt upgrade -y"
        print_status "info" "Using apt package manager"
    elif command_exists dnf; then
        PACKAGE_MANAGER="dnf"
        INSTALL_CMD="sudo dnf install -y"
        UPDATE_CMD="sudo dnf check-update || true"
        UPGRADE_CMD="sudo dnf upgrade -y"
        print_status "info" "Using dnf package manager"
    elif command_exists yum; then
        PACKAGE_MANAGER="yum"
        INSTALL_CMD="sudo yum install -y"
        UPDATE_CMD="sudo yum check-update || true"
        UPGRADE_CMD="sudo yum upgrade -y"
        print_status "info" "Using yum package manager"
    elif command_exists pacman; then
        PACKAGE_MANAGER="pacman"
        INSTALL_CMD="sudo pacman -S --noconfirm"
        UPDATE_CMD="sudo pacman -Sy"
        UPGRADE_CMD="sudo pacman -Syu --noconfirm"
        print_status "info" "Using pacman package manager"
    elif command_exists zypper; then
        PACKAGE_MANAGER="zypper"
        INSTALL_CMD="sudo zypper install -y"
        UPDATE_CMD="sudo zypper refresh"
        UPGRADE_CMD="sudo zypper update -y"
        print_status "info" "Using zypper package manager"
    else
        print_status "error" "No supported package manager found!"
        print_status "error" "Supported: apt, dnf, yum, pacman, zypper"
        exit 1
    fi
}

# Install a package, optionally with distro-specific names.
# refresh_apt_keyring URL KEYRING [--dearmor]
# Compare-and-replace a third-party apt signing key on every run. Vendors rotate keys; a keyring
# imported "only if absent" (or behind an "already installed → return 0") stays stale, and apt
# then fails with EXPKEYSIG while silently keeping old package lists — measured with the GitHub
# CLI key 23F3D4EA75716059 in 2026-09 (#352, #353). No-op when the published key is unchanged;
# returns 1 on a failed download instead of keeping the old key quietly.
refresh_apt_keyring() {
    local url="$1" keyring="$2" mode="${3:-}"
    local out rc
    out=$(mktemp)
    if ! curl -fsSL "$url" -o "$out" 2>> "$LOG_FILE"; then
        rm -f "$out"
        print_status "error" "Could not download apt signing key: $url"
        return 1
    fi
    if [ "$mode" = "--dearmor" ]; then
        if ! gpg --batch --yes --dearmor -o "$out.gpg" "$out" 2>> "$LOG_FILE"; then
            rm -f "$out" "$out.gpg"
            print_status "error" "Could not dearmor apt signing key: $url"
            return 1
        fi
        mv "$out.gpg" "$out"
    fi
    if cmp -s "$out" "$keyring"; then
        rm -f "$out"
        return 0
    fi
    run_or_echo sudo install -D -m 644 "$out" "$keyring"
    rc=$?
    rm -f "$out"
    [ "$rc" -eq 0 ] && print_status "success" "apt signing key refreshed: $keyring"
    return "$rc"
}

# package_landed PKG — 0 when the package manager's own database lists PKG as installed.
package_landed() {
    case "$PACKAGE_MANAGER" in
        apt)            [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" == "install ok installed" ]] ;;
        dnf|yum|zypper) rpm -q "$1" &>/dev/null ;;
        pacman)         pacman -Q "$1" &>/dev/null ;;
        *)              return 1 ;;
    esac
}

# install_packages_verified PKG... — run $INSTALL_CMD, and trust the package database over its
# exit code. A pre-existing broken package (e.g. a kernel-module postinst failing) makes the
# manager exit non-zero on EVERY invocation even when the requested packages unpacked and
# configured fine (#632). Non-zero exit + every PKG present = success with a warning;
# any PKG missing = the original failure.
install_packages_verified() {
    local rc=0 pkg
    $INSTALL_CMD "$@" || rc=$?
    [ "$rc" -eq 0 ] && return 0
    for pkg in "$@"; do
        package_landed "$pkg" || return "$rc"
    done
    print_status "warning" "$INSTALL_CMD exited $rc but all requested packages are installed: $*"
    print_status "warning" "Unrelated broken package state remains — check 'dpkg --audit' or the package manager."
    return 0
}

install_package() {
    local package_name="$1"
    local debian_name="${2:-$package_name}"
    local fedora_name="${3:-$package_name}"
    local arch_name="${4:-$package_name}"

    case "$PACKAGE_MANAGER" in
        apt)        install_packages_verified "$debian_name" ;;
        dnf|yum)    install_packages_verified "$fedora_name" ;;
        pacman)     install_packages_verified "$arch_name" ;;
        zypper)     install_packages_verified "$debian_name" ;;
    esac
}

# ============================================================================
# FLATPAK (shared because multiple categories depend on it)
# ============================================================================

setup_flatpak() {
    # Idempotent — safe to call multiple times.
    if ! command_exists flatpak; then
        print_status "section" "FLATPAK SETUP"
        print_status "info" "Installing Flatpak..."
        install_package "flatpak" "flatpak" "flatpak" "flatpak"

        case "$PACKAGE_MANAGER" in
            apt)
                $INSTALL_CMD gnome-software-plugin-flatpak \
                    || print_status "info" "GNOME Software plugin not available"
                ;;
        esac
    fi

    print_status "info" "Adding Flathub repository..."
    run_or_echo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

    if ! flatpak list 2>/dev/null | grep -q com.github.tchx84.Flatseal; then
        print_status "info" "Installing Flatseal (Flatpak permissions manager)..."
        run_or_echo flatpak install -y flathub com.github.tchx84.Flatseal
    fi
}

# ============================================================================
# CHROME PWA (shared by every --app= web wrapper)
# ============================================================================

# Wrap a website as a Chrome PWA with its own launcher entry.
#   install_chrome_pwa <label> <url> <desktop-basename> <icon-asset> <categories> <icon-px>
#
# <icon-asset> is a filename under assets/; <icon-px> is the hicolor bucket it is
# copied into (pick the nearest standard size at or below the asset's real height,
# GNOME scales from there). The icon is copied out of the repo into the user's
# icon theme so the launcher survives the repo being moved or deleted.
install_chrome_pwa() {
    local label="$1" url="$2" desktop_name="$3" icon_asset="$4" categories="$5" icon_px="$6"

    if ! command_exists google-chrome; then
        print_status "error" "Google Chrome not found. The $label PWA requires Chrome."
        print_status "info" "Install Chrome first and re-run this step."
        return 1
    fi

    local desktop_dir="$HOME/.local/share/applications"
    local desktop_file="$desktop_dir/${desktop_name}.desktop"

    local repo_root
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || return 1

    local icon_src="$repo_root/assets/$icon_asset"
    local icon_theme_dir="$HOME/.local/share/icons/hicolor/${icon_px}x${icon_px}/apps"
    local icon_value="$desktop_name"

    if [ -f "$desktop_file" ]; then
        print_status "info" "$label desktop entry already exists, updating"
    fi

    print_status "info" "Creating $label desktop entry..."
    run_or_echo mkdir -p "$desktop_dir"

    if [ -f "$icon_src" ]; then
        print_status "info" "Installing $label icon..."
        run_or_echo mkdir -p "$icon_theme_dir"
        cp "$icon_src" "$icon_theme_dir/${desktop_name}.png"
        if command_exists gtk-update-icon-cache; then
            run_or_echo gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
        fi
    else
        print_status "warning" "$label icon not found at $icon_src. Using default icon."
        icon_value="applications-internet"
    fi

    cat > "$desktop_file" << EOF
[Desktop Entry]
Name=${label}
Exec=google-chrome --app=${url}
Terminal=false
Type=Application
Icon=${icon_value}
Categories=${categories}
EOF
    run_or_echo chmod +x "$desktop_file"

    if command_exists update-desktop-database; then
        run_or_echo update-desktop-database "$desktop_dir" 2>/dev/null || true
    fi

    print_status "success" "$label desktop entry created"
    print_status "info" "$label: Chrome PWA for $url"
}

# ============================================================================
# INSTALL_REGISTRY INFRASTRUCTURE
# ============================================================================

# Strict validation: every function named in INSTALL_REGISTRY must exist.
# Called by the orchestrator BEFORE any install runs, so typos surface early.
validate_registry() {
    local missing=()
    local entry fn _label _folder _desktop

    for entry in "${INSTALL_REGISTRY[@]}"; do
        IFS=':' read -r fn _label _folder _desktop <<< "$entry"
        if ! declare -F "$fn" >/dev/null; then
            missing+=("$fn")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        print_status "error" "INSTALL_REGISTRY references ${#missing[@]} undefined function(s):"
        local m
        for m in "${missing[@]}"; do
            print_status "error" "  - $m"
        done
        print_status "error" "Check that the right install_lib/*.sh files are sourced, or fix the typo."
        exit 1
    fi
}

# Run a single install entry in a subshell so a failure does not abort
# the orchestrator. Failures are collected for end-of-run reporting.
#
# Subshell rationale: existing install_* functions assume `set -e`, so a
# failing command inside them must terminate the function — but we want that
# failure to be CAUGHT here, not propagated up. A subshell gives us both:
# `set -e` semantics inside, and the option to ignore the exit code outside.
run_install() {
    local fn="$1"
    local label="$2"

    if ( set -e; "$fn" ); then
        return 0
    else
        local rc=$?
        INSTALL_FAILURES+=("$label")
        print_status "warning" "Failed: $label (exit code $rc) — continuing"
        return 0
    fi
}

# Print a summary of any installs that failed during this run.
report_failures() {
    if [ ${#INSTALL_FAILURES[@]} -eq 0 ]; then
        print_status "success" "All installs completed without errors"
        return 0
    fi

    print_status "section" "INSTALL FAILURES"
    print_status "warning" "${#INSTALL_FAILURES[@]} install step(s) failed:"
    local f
    for f in "${INSTALL_FAILURES[@]}"; do
        print_status "error" "  - $f"
    done
    print_status "info" "See log file for details: $LOG_FILE"
}

# Resolve a registry entry's .desktop filename.
# If the explicit desktop_file field is set, use it. Otherwise derive from
# the function name: install_pinta -> pinta.desktop.
registry_desktop_file() {
    local entry="$1"
    local fn _label _folder desktop

    IFS=':' read -r fn _label _folder desktop <<< "$entry"
    if [ -n "$desktop" ]; then
        echo "$desktop"
    else
        echo "${fn#install_}.desktop"
    fi
}
