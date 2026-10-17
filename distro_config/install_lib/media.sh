#!/bin/bash
#
# distro_config/install_lib/media.sh
#
# Media tools: video downloaders, CD/DVD ripping. Sourced by install_programs.sh.
# Depends on: print_status, command_exists, install_package, $PACKAGE_MANAGER,
#             $INSTALL_CMD, $LOG_FILE

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "media.sh is meant to be sourced, not executed." >&2
    exit 1
fi

# ============================================================================
# INSTALL FUNCTIONS
# ============================================================================

install_4k_video_downloader() {
    if dpkg -l 4kvideodownloaderplus 2>/dev/null | grep -q '^ii'; then
        print_status "info" "4K Video Downloader Plus already installed"
        return 0
    fi

    if [ "$PACKAGE_MANAGER" != "apt" ]; then
        print_status "warning" "4K Video Downloader Plus: manual install required for non-apt distros"
        print_status "config" "  Download from: https://www.4kdownload.com/downloads"
        return 1
    fi

    print_status "info" "Installing 4K Video Downloader Plus..."

    local fallback_url="https://dl.4kdownload.com/app/4kvideodownloaderplus_26.1.0-1_amd64.deb"
    local deb_url

    deb_url=$(curl -fsSL --max-time 10 "https://www.4kdownload.com/downloads" 2>/dev/null \
        | grep -oP 'https://dl\.4kdownload\.com/app/4kvideodownloaderplus_[\d.]+-1_amd64\.deb' \
        | head -1)

    if [ -z "$deb_url" ]; then
        print_status "warning" "Could not scrape latest version, using fallback: $fallback_url"
        deb_url="$fallback_url"
    else
        print_status "info" "Latest version URL: $deb_url"
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d)

    if wget -O "$tmp_dir/4kvideodownloaderplus.deb" "$deb_url" 2>>"$LOG_FILE" || \
       run_or_echo curl -L -o "$tmp_dir/4kvideodownloaderplus.deb" "$deb_url" 2>>"$LOG_FILE"; then
        if run_or_echo sudo apt-get install -y "$tmp_dir/4kvideodownloaderplus.deb"; then
            rm -rf "$tmp_dir"
            if dpkg -l 4kvideodownloaderplus 2>/dev/null | grep -q '^ii'; then
                print_status "success" "4K Video Downloader Plus is ready"
            else
                print_status "warning" "4K Video Downloader Plus installed but could not be verified"
            fi
        else
            rm -rf "$tmp_dir"
            print_status "error" "4K Video Downloader Plus installation failed"
            return 1
        fi
    else
        rm -rf "$tmp_dir"
        print_status "error" "Failed to download 4K Video Downloader Plus from: $deb_url"
        return 1
    fi
}

install_asunder() {
    print_status "section" "ASUNDER CD RIPPER"

    if command_exists asunder || dpkg -l 2>/dev/null | grep -q "^ii  asunder "; then
        print_status "info" "Asunder already installed"
        return 0
    fi

    print_status "info" "Installing Asunder CD ripper..."

    if install_package "asunder" "asunder" "asunder" "asunder"; then
        print_status "success" "Asunder installed"
    else
        print_status "error" "Could not install Asunder. Please install manually."
        return 1
    fi

    if command_exists asunder; then
        print_status "success" "Asunder is ready to use"
        print_status "info" "Asunder: CD ripper and encoder"
    else
        print_status "warning" "Asunder installation could not be verified"
        return 1
    fi
}

install_handbrake() {
    print_status "section" "HANDBRAKE DVD RIPPER"

    if command_exists handbrake-gtk || command_exists ghb || \
       flatpak list 2>/dev/null | grep -q "fr.handbrake.ghb" || \
       dpkg -l 2>/dev/null | grep -q "^ii  handbrake "; then
        print_status "info" "HandBrake already installed"
        return 0
    fi

    print_status "info" "Installing HandBrake..."

    case "$PACKAGE_MANAGER" in
        apt)
            print_status "info" "Installing DVD decryption support (libdvd-pkg)..."
            if run_or_echo sudo apt-get install -y libdvd-pkg 2>>"$LOG_FILE"; then
                sudo DEBIAN_FRONTEND=noninteractive dpkg-reconfigure libdvd-pkg 2>>"$LOG_FILE" || true
                print_status "success" "DVD decryption support installed"
            else
                print_status "warning" "libdvd-pkg not available; encrypted DVDs may not play"
            fi

            if command_exists flatpak; then
                run_or_echo flatpak install -y flathub fr.handbrake.ghb 2>>"$LOG_FILE" && \
                    print_status "success" "HandBrake installed via Flatpak" && return 0
            fi

            install_package "HandBrake" "handbrake" "handbrake" "handbrake" || {
                print_status "error" "Could not install HandBrake. Please install manually."
                return 1
            }
            ;;
        dnf|yum|pacman|zypper)
            if command_exists flatpak; then
                run_or_echo flatpak install -y flathub fr.handbrake.ghb 2>>"$LOG_FILE" && \
                    print_status "success" "HandBrake installed via Flatpak" && return 0
            fi
            install_package "HandBrake" "handbrake" "handbrake" "handbrake" || \
                print_status "warning" "HandBrake not available; try: flatpak install flathub fr.handbrake.ghb"
            ;;
    esac

    if command_exists handbrake-gtk || command_exists ghb || \
       flatpak list 2>/dev/null | grep -q "fr.handbrake.ghb"; then
        print_status "success" "HandBrake is ready to use"
        print_status "info" "HandBrake: DVD and video transcoder"
        print_status "config" "Supports MP4/MKV output, subtitle and audio track selection"
    else
        print_status "warning" "HandBrake installation could not be verified"
        return 1
    fi
}

install_soundcloud() {
    print_status "section" "SOUNDCLOUD"

    # SoundCloud ships no native Linux client, and every third-party desktop client
    # (Soundnode, Auryo) is archived and pinned to the retired v1 API. The web player
    # is the only maintained surface — wrap it as a Chrome PWA.
    install_chrome_pwa "SoundCloud" "https://soundcloud.com" "soundcloud" \
        "soundcloud_app.png" "AudioVideo;Audio;Player;" 512 || return 1

    print_status "config" "Pinned to the dock beside Spotify by ubuntu_workspace.sh"
}

install_obs() {
    print_status "section" "OBS STUDIO"

    if command_exists obs || \
       flatpak list 2>/dev/null | grep -q "com.obsproject.Studio"; then
        print_status "info" "OBS Studio already installed"
        return 0
    fi

    setup_flatpak

    print_status "info" "Installing OBS Studio via Flatpak..."
    if run_or_echo flatpak install -y flathub com.obsproject.Studio 2>>"$LOG_FILE"; then
        print_status "success" "OBS Studio installed via Flatpak"
        print_status "info" "OBS Studio: open-source screen recording and live streaming"
        print_status "config" "Launch: flatpak run com.obsproject.Studio"
    else
        print_status "error" "Could not install OBS Studio. Try: flatpak install flathub com.obsproject.Studio"
        return 1
    fi
}

_openwhispr_installed() {
    package_landed open-whispr
}

install_openwhispr() {
    print_status "section" "OPENWHISPR (voice dictation)"

    if _openwhispr_installed; then
        print_status "info" "OpenWhispr already installed"
        return 0
    fi

    # Upstream ships a .deb for amd64 only (plus rpm/AppImage/tar.gz); the .deb is preferred.
    if [ "$PACKAGE_MANAGER" != "apt" ] || [ "$(dpkg --print-architecture 2>/dev/null)" != "amd64" ]; then
        print_status "warning" "OpenWhispr: the .deb needs apt on amd64; install manually"
        print_status "config" "  Download from: https://github.com/HeroTools/open-whispr/releases/latest"
        return 1
    fi

    command_exists curl || install_package curl curl curl curl
    if ! command_exists curl; then
        print_status "error" "curl is required to look up the latest OpenWhispr release"
        return 1
    fi

    print_status "info" "Fetching latest OpenWhispr release..."
    local release_json curl_rc=0 deb_url
    release_json=$(curl -fsSL --max-time 15 \
        "https://api.github.com/repos/HeroTools/open-whispr/releases/latest" 2>>"${LOG_FILE:-/dev/null}") || curl_rc=$?
    if [ "$curl_rc" -ne 0 ]; then
        print_status "error" "Could not query the OpenWhispr release API (curl exit $curl_rc: rate limit, DNS or timeout)"
        return 1
    fi
    deb_url=$(printf '%s' "$release_json" \
        | grep -oE '"browser_download_url": *"[^"]*linux-amd64\.deb"' | head -1 | cut -d '"' -f 4)

    if [ -z "$deb_url" ]; then
        print_status "error" "No linux-amd64 .deb asset found in the latest OpenWhispr release"
        return 1
    fi
    print_status "config" "URL: $deb_url"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    # RETURN fires on every return path of this function; it deletes itself so it
    # does not linger in the sourcing shell. A Ctrl-C kills the shell outright and
    # skips it, so an interrupted download can still leave a file in /tmp.
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp_dir'; trap - RETURN" RETURN
    print_status "info" "Downloading OpenWhispr (~450 MB)..."
    if ! run_or_echo curl -fL --retry 3 --max-time 1800 -o "$tmp_dir/open-whispr.deb" "$deb_url" 2>>"${LOG_FILE:-/dev/null}"; then
        print_status "error" "Failed to download OpenWhispr from: $deb_url"
        return 1
    fi

    # electron-builder publishes latest-linux.yml next to the assets with a base64
    # sha512 per file, the .deb included.
    if [ "${DRY_RUN:-0}" != "1" ]; then
        local want got
        want=$(curl -fsSL --max-time 30 "${deb_url%/*}/latest-linux.yml" 2>>"${LOG_FILE:-/dev/null}" \
            | awk -v f="${deb_url##*/}" '$1=="-"&&$2=="url:"{hit=($3==f)} hit&&$1=="sha512:"{print $2; exit}')
        got=$(openssl dgst -sha512 -binary "$tmp_dir/open-whispr.deb" | base64 -w0)
        if [ -z "$want" ] || [ "$want" != "$got" ]; then
            print_status "error" "OpenWhispr .deb checksum missing or mismatched against latest-linux.yml; not installing"
            return 1
        fi
    fi

    # The .deb Depends on ydotool (auto-paste on Wayland); apt pulls it in from the archive.
    # Trust the package database over apt's exit code (#632): an unrelated broken package
    # makes apt exit non-zero even when open-whispr configured fine.
    local rc=0
    run_or_echo sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$tmp_dir/open-whispr.deb" || rc=$?
    if [ "$rc" -ne 0 ]; then
        if ! package_landed open-whispr; then
            print_status "error" "OpenWhispr installation failed"
            return 1
        fi
        print_status "warning" "apt-get exited $rc but open-whispr is installed; check 'dpkg --audit'"
    fi

    [ "${DRY_RUN:-0}" = "1" ] && return 0

    if ! _openwhispr_installed; then
        print_status "warning" "OpenWhispr installed but could not be verified"
        return 1
    fi
    print_status "success" "OpenWhispr installed"
    # The .deb's postinst adds $SUDO_USER (else logname) to 'input'; skipped when neither
    # resolves, e.g. a bare root shell. Say which case this is instead of assuming.
    if getent group input | cut -d: -f4 | tr ',' '\n' | grep -qx "${USER:-}"; then
        print_status "config" "Auto-paste on Wayland uses ydotool: log out and in once so the 'input' group applies"
    else
        print_status "warning" "Auto-paste on Wayland needs the 'input' group: run 'sudo usermod -aG input \$USER', then log out and in"
    fi
}

uninstall_openwhispr() {
    print_status "section" "UNINSTALL OPENWHISPR"

    if ! _openwhispr_installed; then
        print_status "info" "OpenWhispr not installed"
        return 0
    fi

    # remove, not purge: the package's postrm already drops the cached models;
    # ydotool (a dependency) and ~/.config/OpenWhispr are left in place.
    run_or_echo sudo env DEBIAN_FRONTEND=noninteractive apt-get remove -y open-whispr || {
        print_status "error" "OpenWhispr removal failed"
        return 1
    }
    print_status "success" "OpenWhispr removed"
}

# ============================================================================
# REGISTRY
# ============================================================================

INSTALL_REGISTRY+=(
    "install_4k_video_downloader:4K Video Downloader Plus:Media:com.4kdownload.4kvideodownloaderplus.desktop"
    "install_asunder:Asunder CD Ripper:Media:asunder.desktop"
    "install_handbrake:HandBrake DVD Ripper:Media:fr.handbrake.ghb.desktop"
    "install_obs:OBS Studio:Media:com.obsproject.Studio.desktop"
    "install_openwhispr:OpenWhispr (Voice Dictation):Media:open-whispr.desktop"
    "install_soundcloud:SoundCloud:Media:soundcloud.desktop"
)
