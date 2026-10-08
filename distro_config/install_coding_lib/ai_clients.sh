#!/bin/bash
#
# distro_config/install_coding_lib/ai_clients.sh
#
# AI coding CLIs, local AI runtimes, and developer-facing AI tooling.
# Sourced by install_coding.sh. Depends on Node.js for npm-based installs.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "ai_clients.sh is meant to be sourced, not executed." >&2
    exit 1
fi

# ============================================================================
# OLLAMA (+ distro-specific helpers)
# ============================================================================

install_ollama() {
    print_status "section" "OLLAMA AI PLATFORM"

    if command_exists ollama; then
        local current_version
        current_version=$(ollama --version 2>/dev/null || echo "unknown")
        print_status "info" "Ollama already installed (version: $current_version)"
        return 0
    fi

    print_status "info" "Installing Ollama - Local AI platform..."

    case "$PACKAGE_MANAGER" in
        apt)        install_ollama_debian ;;
        dnf|yum)    install_ollama_rpm ;;
        pacman)     install_ollama_arch ;;
        zypper)     install_ollama_opensuse ;;
        *)
            print_status "warning" "Unsupported package manager, using curl installation method"
            install_ollama_curl
            ;;
    esac

    if command_exists ollama; then
        local version
        version=$(ollama --version 2>/dev/null || echo "unknown")
        print_status "success" "Ollama installed successfully (version: $version)"
        configure_ollama_service
        show_ollama_info
    else
        print_status "error" "Ollama installation failed"
        return 1
    fi
}

install_ollama_debian() {
    print_status "info" "Installing Ollama on Debian-based system..."
    print_status "info" "Installing dependencies..."
    $INSTALL_CMD curl

    cd "$DOWNLOADS_DIR" || return 1
    print_status "info" "Downloading Ollama installer..."

    if curl -fsSL https://ollama.ai/install.sh | sh 2>&1 | tee -a "$LOG_FILE"; then
        print_status "success" "Ollama installed via official script"
    else
        print_status "warning" "Official installer failed, trying alternative method..."
        install_ollama_curl
    fi

    cd - > /dev/null || return 1
}

install_ollama_rpm() {
    print_status "info" "Installing Ollama on RPM-based system..."
    print_status "info" "Installing dependencies..."
    $INSTALL_CMD curl

    cd "$DOWNLOADS_DIR" || return 1
    print_status "info" "Downloading Ollama installer..."

    if curl -fsSL https://ollama.ai/install.sh | sh 2>&1 | tee -a "$LOG_FILE"; then
        print_status "success" "Ollama installed via official script"
    else
        print_status "warning" "Official installer failed, trying alternative method..."
        install_ollama_curl
    fi

    cd - > /dev/null || return 1
}

install_ollama_arch() {
    print_status "info" "Installing Ollama on Arch Linux..."

    if command_exists yay; then
        print_status "info" "Installing Ollama from AUR..."
        if yay -S --noconfirm ollama 2>&1 | tee -a "$LOG_FILE"; then
            print_status "success" "Ollama installed from AUR"
            return 0
        else
            print_status "warning" "AUR installation failed, trying official installer..."
        fi
    fi

    $INSTALL_CMD curl
    cd "$DOWNLOADS_DIR" || return 1

    if curl -fsSL https://ollama.ai/install.sh | sh 2>&1 | tee -a "$LOG_FILE"; then
        print_status "success" "Ollama installed via official script"
    else
        print_status "error" "All installation methods failed"
        return 1
    fi

    cd - > /dev/null || return 1
}

install_ollama_opensuse() {
    print_status "info" "Installing Ollama on openSUSE..."
    print_status "info" "Installing dependencies..."
    $INSTALL_CMD curl

    cd "$DOWNLOADS_DIR" || return 1
    print_status "info" "Downloading Ollama installer..."

    if curl -fsSL https://ollama.ai/install.sh | sh 2>&1 | tee -a "$LOG_FILE"; then
        print_status "success" "Ollama installed via official script"
    else
        print_status "warning" "Official installer failed, trying binary installation..."
        install_ollama_curl
    fi

    cd - > /dev/null || return 1
}

install_ollama_curl() {
    print_status "info" "Installing Ollama using binary download..."

    cd "$DOWNLOADS_DIR" || return 1

    local ollama_url="https://ollama.ai/download/ollama-linux-amd64"
    local ollama_bin="$DOWNLOADS_DIR/ollama"

    print_status "info" "Downloading Ollama binary..."
    if curl -L -o "$ollama_bin" "$ollama_url" 2>&1 | tee -a "$LOG_FILE"; then
        run_or_echo chmod +x "$ollama_bin"
        run_or_echo sudo cp "$ollama_bin" /usr/local/bin/ollama
        print_status "success" "Ollama binary installed to /usr/local/bin/ollama"
    else
        print_status "error" "Failed to download Ollama binary"
        cd - > /dev/null || return 1
        return 1
    fi

    cd - > /dev/null || return 1
}

configure_ollama_service() {
    print_status "info" "Configuring Ollama service..."

    if ! command_exists systemctl; then
        print_status "warning" "systemd not available, cannot configure service"
        return 0
    fi

    if run_or_echo sudo systemctl enable ollama 2>/dev/null; then
        print_status "success" "Ollama service enabled"
    fi

    if run_or_echo sudo systemctl start ollama 2>/dev/null; then
        print_status "success" "Ollama service started"
    else
        print_status "warning" "Could not start Ollama service automatically"
        print_status "info" "You can start it manually with: ollama serve"
    fi
}

show_ollama_info() {
    print_status "info" "Ollama usage examples:"
    print_status "config" "  Start Ollama server: ollama serve"
    print_status "config" "  Pull a model: ollama pull llama2"
    print_status "config" "  Run a model: ollama run llama2"
    print_status "config" "  List models: ollama list"
    print_status "config" "  Available models: llama2, codellama, mistral, phi, etc."

    if command_exists systemctl && systemctl is-active ollama &>/dev/null; then
        print_status "success" "Ollama service is running"
        print_status "info" "Ollama API available at: http://localhost:11434"
    fi
}

# ============================================================================
# CLAUDE CODE
# ============================================================================

install_claude_code() {
    print_status "section" "CLAUDE CODE INSTALLATION"

    if ! is_tool_installed "nodejs"; then
        print_status "info" "Node.js is not installed; installing it first (Claude Code requires it)"
        install_nodejs
    fi

    if ! command_exists npm; then
        print_status "error" "npm is not available. Please ensure Node.js is properly installed."
        return 1
    fi

    print_status "info" "Checking for existing Claude Code installation..."

    local claude_version=""
    if command_exists claude; then
        claude_version=$(timeout 10 claude --version 2>/dev/null | head -n1 || echo "")
    fi

    if [ -n "$claude_version" ]; then
        print_status "info" "Claude Code is already installed ($claude_version) — updating to latest"
    fi

    print_status "info" "Running: npm install -g @anthropic-ai/claude-code"
    print_status "warning" "This may take a moment..."

    npm_install_global "@anthropic-ai/claude-code" || {
        print_status "error" "Failed to install Claude Code"
        return 1
    }

    print_status "success" "Claude Code package installed successfully"

    print_status "info" "Verifying Claude Code installation..."
    if command_exists claude; then
        print_status "success" "Claude Code command is available: $(timeout 10 claude --version 2>/dev/null | head -n1 || echo 'Not available')"
    else
        print_status "warning" "Claude command not found in PATH"
        local npm_prefix
        npm_prefix=$(npm config get prefix 2>/dev/null || echo "")
        if [ -n "$npm_prefix" ]; then
            print_status "info" "npm global prefix detected: $npm_prefix"
            print_status "config" "If needed, add to PATH: export PATH=\"$npm_prefix/bin:\$PATH\""
        fi
    fi

    # Never auto-launch the OAuth flow: it is interactive by nature and this installer runs
    # unattended inside the `make run` chain (#339).
    print_status "info" "You can login later with: claude login"
    print_status "info" "Or set API key manually: export ANTHROPIC_API_KEY=\"your_key_here\""

    echo ""
    print_status "info" "Claude Code usage:"
    print_status "config" "  Check version: claude --version"
    print_status "config" "  Login: claude login"
    print_status "config" "  Update (current version): npm update -g @anthropic-ai/claude-code"
    print_status "config" "  Update all nvm versions: re-run this installer and choose 'all'"
    print_status "config" "  Run in project: cd /path/to/project && claude"
}

# ============================================================================
# GITHUB COPILOT CLI
# ============================================================================

install_github_copilot_cli() {
    print_status "section" "GITHUB COPILOT CLI INSTALLATION"

    if ! is_tool_installed "nodejs"; then
        print_status "info" "Node.js is not installed; installing it first (Copilot CLI requires it)"
        install_nodejs
    fi

    if ! command_exists npm; then
        print_status "error" "npm is not available. Please ensure Node.js is properly installed."
        return 1
    fi

    print_status "info" "Checking for existing GitHub Copilot CLI installation..."

    local copilot_version=""
    if command_exists copilot; then
        copilot_version=$(timeout 10 copilot --version 2>/dev/null | head -n1 | sed 's/.*v//' || echo "")
    fi

    if [ -n "$copilot_version" ]; then
        print_status "info" "GitHub Copilot CLI is already installed (version: $copilot_version) — updating to latest"
    fi

    # npm is the recommended method and the only one every supported distro has after
    # bootstrapping, and stable is the channel a setup run wants. Both were prompts that
    # were always answered the same way (#339) -- the registry menu is already the consent.
    local package_name="@github/copilot"
    print_status "info" "Installing GitHub Copilot CLI stable version via npm..."
    print_status "warning" "This may take a moment..."

    local install_ok=true
    npm_install_global "$package_name" || install_ok=false

    if $install_ok; then
        copilot_version=$(timeout 5 copilot --version 2>/dev/null | head -n1 | sed 's/.*v//' || echo "")

        if [ -n "$copilot_version" ]; then
            print_status "success" "GitHub Copilot CLI $copilot_version installed successfully"
        else
            print_status "success" "GitHub Copilot CLI installed successfully"
        fi

        local update_cmd="npm update -g $package_name"

        print_status "info" "Verifying installation..."
        if command_exists copilot; then
            print_status "info" "GitHub Copilot CLI version: $(timeout 5 copilot --version 2>/dev/null | head -n1 || echo 'Not available')"
        else
            print_status "warning" "GitHub Copilot CLI command not found. You may need to reload your shell."
        fi

        echo ""
        print_status "info" "GitHub Copilot CLI usage:"
        print_status "config" "  Launch CLI: copilot"
        print_status "config" "  Check version: copilot --version"
        print_status "config" "  Update: $update_cmd"
        print_status "config" "  Note: Requires GitHub CLI authentication for full functionality"
        print_status "config" "  Authenticate with: gh auth login"
    else
        print_status "error" "Failed to install GitHub Copilot CLI"
        return 1
    fi
}

# ============================================================================
# QWEN CODE
# ============================================================================

install_qwen() {
    print_status "section" "QWEN CODE INSTALLATION"

    local qwen_version=""
    if command_exists qwen; then
        qwen_version=$(timeout 10 qwen --version 2>/dev/null | head -n1 || echo "")
    fi

    if [ -n "$qwen_version" ]; then
        print_status "info" "Qwen Code is already installed ($qwen_version) — reinstalling to latest"
    fi

    if ! command_exists curl; then
        print_status "error" "curl is not available. Please install curl first."
        return 1
    fi

    print_status "info" "Downloading and running Qwen Code installer..."
    print_status "warning" "This may take a moment..."

    # The vendor installer ends in an unconditional `exec qwen`, which replaces itself with
    # the interactive TUI and stops the whole `make run` chain until someone quits it (#339).
    # Its argument parser exits 1 on any flag but -s/--source and -h/--help, so there is no
    # opt-out to pass -- redirecting stdin is the only lever on our side of the boundary, and
    # `qwen` with stdin at EOF exits immediately instead of waiting.
    #
    # That same `exec` is why the pipeline's status is not the install's: it reports the TUI's
    # exit code (1 on the EOF path), and `| tee` would report tee's 0 regardless. So success
    # is taken from the verification below, which is what actually answers the question.
    bash -c "$(curl -fsSL https://qwen-code-assets.oss-cn-hangzhou.aliyuncs.com/installation/install-qwen.sh)" \
        -s --source qwenchat < /dev/null 2>&1 | tee -a "$LOG_FILE"

    export PATH="$HOME/.local/bin:$HOME/bin:$PATH"

    print_status "info" "Verifying Qwen Code installation..."
    if ! command_exists qwen; then
        print_status "error" "Failed to install Qwen Code — qwen not found in PATH"
        return 1
    fi

    print_status "success" "Qwen Code is available: $(timeout 10 qwen --version 2>/dev/null | head -n1 || echo 'Not available')"

    echo ""
    print_status "info" "Qwen Code usage:"
    print_status "config" "  Check version: qwen --version"
    print_status "config" "  Run in project: cd /path/to/project && qwen"
    print_status "config" "  Update: re-run the installer script"
}

# ============================================================================
# OPENAI CODEX CLI
# ============================================================================

install_codex() {
    print_status "section" "OPENAI CODEX CLI INSTALLATION"

    if command_exists codex; then
        print_status "info" "OpenAI Codex CLI is already installed ($(timeout 10 codex --version 2>/dev/null | head -n1 || echo "unknown"))"

        print_status "info" "Reinstalling OpenAI Codex CLI to the latest version"
    fi

    if ! command_exists npm; then
        print_status "error" "npm is not available. Please ensure Node.js is properly installed."
        return 1
    fi

    print_status "info" "Installing @openai/codex globally via npm..."
    run_or_echo npm install -g @openai/codex &>> "$LOG_FILE"

    print_status "info" "Verifying OpenAI Codex CLI installation..."
    if command_exists codex; then
        print_status "success" "OpenAI Codex CLI installed successfully"
        print_status "success" "Codex version: $(timeout 10 codex --version 2>/dev/null | head -n1 || echo "Not available")"

        echo ""
        print_status "info" "OpenAI Codex CLI usage:"
        print_status "config" "  Login: codex login"
        print_status "config" "  Run in project: cd /path/to/project && codex"
        print_status "config" "  Update: npm update -g @openai/codex"
    else
        print_status "error" "OpenAI Codex CLI installation failed — check $LOG_FILE"
        return 1
    fi
}

# ============================================================================
# KIMI CODE CLI (Moonshot AI)
# ============================================================================

# Channel verified 2026-09-08 (dotfiles-linux-dev#149): official Moonshot AI package
# @moonshot-ai/kimi-code on the public npm registry (author "Moonshot AI",
# https://registry.npmjs.org/@moonshot-ai/kimi-code, latest 0.41.0 at time of
# writing). Docs: https://platform.kimi.ai/docs/guide/claude-code-kimi and
# https://kimi.com/code/docs/. Installs a `kimi` binary; needs Node.js
# 22.19.0+. Not to be confused with the legacy Python `kimi-cli` (PyPI
# package `kimi-code` is an unrelated meta-package for that legacy tool) or
# any third-party `kimi-cli`/`kimiai-cli` packages — those are different
# projects with the same name and were deliberately not chosen here.
install_kimi() {
    print_status "section" "KIMI CODE CLI INSTALLATION (Moonshot AI)"

    if command_exists kimi; then
        print_status "info" "Kimi Code CLI is already installed ($(timeout 10 kimi --version 2>/dev/null | head -n1 || echo "unknown"))"

        print_status "info" "Reinstalling Kimi Code CLI to the latest version"
    fi

    if ! command_exists npm; then
        print_status "error" "npm is not available. Please ensure Node.js is properly installed."
        return 1
    fi

    print_status "info" "Installing @moonshot-ai/kimi-code globally via npm..."
    run_or_echo npm install -g @moonshot-ai/kimi-code &>> "$LOG_FILE"

    print_status "info" "Verifying Kimi Code CLI installation..."
    if command_exists kimi; then
        print_status "success" "Kimi Code CLI installed successfully"
        print_status "success" "Kimi version: $(timeout 10 kimi --version 2>/dev/null | head -n1 || echo "Not available")"

        echo ""
        print_status "info" "Kimi Code CLI usage:"
        print_status "config" "  Login: kimi, then /login (Kimi Code OAuth or a Moonshot API key — never store the key in this repo)"
        print_status "config" "  Run in project: cd /path/to/project && kimi"
        print_status "config" "  Update: npm update -g @moonshot-ai/kimi-code"
    else
        print_status "error" "Kimi Code CLI installation failed — check $LOG_FILE"
        return 1
    fi
}

# ============================================================================
# CODEXBAR (Codex/Claude usage & spend tray — Swift CLI + Qt 6 desktop)
# ============================================================================

# _codexbar_version_ge CANDIDATE FLOOR
# True if CANDIDATE >= FLOOR, compared as dotted version numbers.
_codexbar_version_ge() {
    local candidate="$1" floor="$2"
    [ "$(printf '%s\n%s\n' "$candidate" "$floor" | sort -V | head -n1)" = "$floor" ]
}

# _codexbar_installed_qt_version
# Reads the installed Qt 6 core library version straight from the package
# manager — the only way to know the REAL floor without a qmake6/qtpaths6
# dev tool, which the runtime-only package set below does not install.
_codexbar_installed_qt_version() {
    case "$PACKAGE_MANAGER" in
        apt)
            dpkg-query -W -f='${Version}' libqt6core6t64 2>/dev/null \
                || dpkg-query -W -f='${Version}' libqt6core6 2>/dev/null
            ;;
        dnf | yum)
            rpm -q --qf '%{VERSION}\n' qt6-qtbase-common 2>/dev/null \
                || rpm -q --qf '%{VERSION}\n' qt6-qtbase 2>/dev/null
            ;;
        pacman)
            pacman -Q qt6-base 2>/dev/null | awk '{print $2}'
            ;;
    esac
}

# Installs the Qt 6 / QML runtime set CodexBar needs. install_package takes one
# name per family; Debian/Ubuntu split the QML modules into several packages
# that shape cannot express, and the widgets package name itself differs
# between Ubuntu 24.04 (libqt6widgets6t64) and Debian 13 (libqt6widgets6) — so
# this is a deliberate local case block, not a repeated install_package call.
_codexbar_install_qt_runtime() {
    case "$PACKAGE_MANAGER" in
        apt)
            local widgets_pkg="libqt6widgets6t64"
            apt-cache show libqt6widgets6t64 &>/dev/null || widgets_pkg="libqt6widgets6"
            $INSTALL_CMD qml6-module-qtquick qml6-module-qtquick-controls \
                qml6-module-qtquick-layouts qml6-module-qtquick-templates \
                qml6-module-qtquick-window qml6-module-qtqml-workerscript \
                "$widgets_pkg" libqt6svg6 qt6-wayland
            ;;
        dnf | yum)
            $INSTALL_CMD qt6-qtbase qt6-qtdeclarative qt6-qtsvg qt6-qtwayland
            ;;
        pacman)
            $INSTALL_CMD qt6-base qt6-declarative qt6-svg qt6-wayland
            ;;
        *)
            print_status "error" "No known Qt 6/QML runtime package set for package manager: $PACKAGE_MANAGER"
            return 1
            ;;
    esac
}

# Downloads both CodexBar release archives (+ .sha256 files) for ARCH into
# DEST_DIR. Prefers `gh release download` — the documented fallback for the
# unauthenticated GitHub API's rate limit, and `gh` is already installed by
# install_github_cli — falling back to curl + the releases API otherwise.
_codexbar_download_release() {
    local arch="$1" dest_dir="$2"

    if command_exists gh; then
        print_status "info" "Downloading CodexBar release archives via gh (avoids anonymous API rate limits)..."
        gh release download --repo steipete/CodexBar \
            --pattern "CodexBar*-linux-${arch}.tar.gz*" \
            --dir "$dest_dir" --clobber 2>>"$LOG_FILE"
        return $?
    fi

    print_status "info" "gh not found — downloading CodexBar release archives via curl..."
    local api="https://api.github.com/repos/steipete/CodexBar/releases/latest"
    curl -fsSL "$api" -o "$dest_dir/release.json" 2>>"$LOG_FILE" || return 1

    local version
    version=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag_name"])' \
        "$dest_dir/release.json" 2>/dev/null)
    [ -n "$version" ] || return 1

    local base="https://github.com/steipete/CodexBar/releases/download/$version"
    local name
    for name in "CodexBarCLI-$version-linux-$arch.tar.gz" "CodexBarDesktop-$version-linux-$arch.tar.gz"; do
        curl -fSL "$base/$name" -o "$dest_dir/$name" 2>>"$LOG_FILE" || return 1
        curl -fSL "$base/$name.sha256" -o "$dest_dir/$name.sha256" 2>>"$LOG_FILE" || return 1
    done
}

install_codexbar() {
    print_status "section" "CODEXBAR (CODEX USAGE & SPEND TRAY)"

    if command_exists codexbar-linux; then
        print_status "info" "CodexBar is already installed ($(timeout 10 codexbar-linux --version 2>/dev/null | head -n1 || echo "unknown"))"
        print_status "info" "Re-running the installer to update to the latest release"
    fi

    # Release archives are published for x86_64/aarch64 only (upstream README).
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64 | aarch64) ;;
        *)
            print_status "error" "CodexBar release archives support x86_64/aarch64 only — unsupported architecture: $arch"
            return 1
            ;;
    esac

    # Release binaries require glibc 2.39+; older systems need a source build
    # (upstream README). getconf reads it directly, no ldd output to parse.
    local glibc_version
    glibc_version=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')
    if [ -z "$glibc_version" ] || ! _codexbar_version_ge "$glibc_version" "2.39"; then
        print_status "error" "CodexBar requires glibc 2.39+ (detected: ${glibc_version:-unknown}) — build from source instead"
        return 1
    fi

    if ! command_exists curl; then
        print_status "error" "curl is not available. Please install curl first."
        return 1
    fi

    print_status "info" "Installing Qt 6 / QML runtime packages..."
    install_package "python3" "python3" "python3" "python3"
    _codexbar_install_qt_runtime || return 1

    # Verify the floor against what actually landed, not what was requested —
    # Qt below 6.4 installs cleanly and then the binary fails to start (#563).
    local qt_version
    qt_version="$(_codexbar_installed_qt_version)"
    qt_version="${qt_version%%[-+~]*}"
    if [ -z "$qt_version" ] || ! _codexbar_version_ge "$qt_version" "6.4"; then
        print_status "error" "CodexBar requires Qt 6.4+ (detected: ${qt_version:-unknown})"
        return 1
    fi

    local work_dir
    work_dir=$(mktemp -d)
    # shellcheck disable=SC2064  # intentional immediate expansion of work_dir
    trap "rm -rf '$work_dir'" RETURN

    if ! _codexbar_download_release "$arch" "$work_dir"; then
        print_status "error" "Failed to download CodexBar release archives — check $LOG_FILE"
        return 1
    fi

    local cli_archive desktop_archive
    cli_archive=$(find "$work_dir" -maxdepth 1 -name "CodexBarCLI-*-linux-${arch}.tar.gz" -print -quit)
    desktop_archive=$(find "$work_dir" -maxdepth 1 -name "CodexBarDesktop-*-linux-${arch}.tar.gz" -print -quit)

    # Verify BOTH checksums before extracting EITHER archive — upstream's own
    # ordering, preserved deliberately (#563).
    local archive
    for archive in "$cli_archive" "$desktop_archive"; do
        if [ -z "$archive" ] || [ ! -f "$archive" ] || [ ! -f "$archive.sha256" ]; then
            print_status "error" "Missing a CodexBar release archive or checksum for $arch — check $LOG_FILE"
            return 1
        fi
        if ! (cd "$(dirname "$archive")" && sha256sum -c "$(basename "$archive").sha256") &>>"$LOG_FILE"; then
            print_status "error" "Checksum verification failed for $(basename "$archive") — check $LOG_FILE"
            return 1
        fi
    done
    print_status "success" "Checksums verified for both CodexBar archives"

    local cli_dir="$HOME/.local/lib/codexbar-cli"
    mkdir -p "$cli_dir" "$HOME/.local/bin"
    tar -xzf "$cli_archive" -C "$cli_dir"
    ln -sfn "$cli_dir/codexbar" "$HOME/.local/bin/codexbar"
    export PATH="$HOME/.local/bin:$PATH"

    if ! "$HOME/.local/bin/codexbar" --version &>>"$LOG_FILE"; then
        print_status "error" "CodexBar CLI failed to run after install — check $LOG_FILE"
        return 1
    fi

    tar -xzf "$desktop_archive" -C "$work_dir"
    local desktop_dir
    desktop_dir=$(find "$work_dir" -maxdepth 1 -type d -name 'CodexBarDesktop-*' -print -quit)
    if [ -z "$desktop_dir" ]; then
        print_status "error" "Could not locate the extracted CodexBarDesktop directory — check $LOG_FILE"
        return 1
    fi

    # Calling upstream's own installer, not replicating it: it owns the
    # .desktop entry, autostart, and the adapter socket, so reimplementing
    # that here would be drift waiting to happen (#563).
    print_status "info" "Running upstream's Integrations/Linux/install.py..."
    if ! (cd "$desktop_dir" && python3 Integrations/Linux/install.py --cli "$HOME/.local/bin/codexbar") &>>"$LOG_FILE"; then
        print_status "error" "CodexBar desktop installer failed — check $LOG_FILE"
        return 1
    fi

    if command_exists codexbar-linux; then
        print_status "success" "CodexBar installed successfully"
    else
        print_status "error" "CodexBar installed but codexbar-linux is not on PATH — check $LOG_FILE"
        return 1
    fi

    echo ""
    print_status "info" "CodexBar usage:"
    print_status "config" "  Open settings: codexbar-linux --settings"
    print_status "config" "  Sign in/out: use the Codex/Claude CLI (codexbar-linux opens it for you)"
    print_status "config" "  Update: quit CodexBar, re-run this installer entry, then reopen it"
    print_status "config" "    (preferences and disabled autostart survive; no auto-updater yet)"
}

# ============================================================================
# CLAUDESTATUS (+ display/api/cli patches)
# ============================================================================

install_claudestatus() {
    print_status "section" "CLAUDESTATUS — CLAUDE USAGE DASHBOARD"

    if command_exists claudestatus; then
        print_status "info" "claudestatus already installed"
        return 0
    fi

    if ! command_exists npm; then
        print_status "error" "npm not found — install Node.js first"
        return 1
    fi

    print_status "info" "Installing @howells/claudestatus globally via npm..."
    run_or_echo npm install -g @howells/claudestatus &>> "$LOG_FILE"

    if command_exists claudestatus; then
        print_status "success" "claudestatus installed successfully"
        print_status "config" "Add accounts: claudestatus add <alias>"
        print_status "config" "View dashboard: claudestatus"
        _claudestatus_patch_display
    else
        print_status "error" "claudestatus installation failed — check $LOG_FILE"
        return 1
    fi
}

# Patches the claudestatus display.js to show Status, Session, and Weekly columns.
_claudestatus_patch_display() {
    local npm_root
    npm_root="$(npm root -g 2>/dev/null)" || return 0
    local display_js="${npm_root}/@howells/claudestatus/dist/display.js"
    [[ -f "$display_js" ]] || return 0

    print_status "info" "Patching claudestatus display with enhanced columns..."
    cat > "$display_js" << 'DISPLAY_EOF'
import chalk from "chalk";
import Table from "cli-table3";

function formatResetTime(isoString) {
    const date = new Date(isoString);
    const now = new Date();
    const diffMs = date.getTime() - now.getTime();
    if (diffMs < 0) return "now";
    const diffMins = Math.floor(diffMs / 60000);
    const diffHours = Math.floor(diffMins / 60);
    const diffDays = Math.floor(diffHours / 24);
    if (diffMins < 60) {
        return `${diffMins}m`;
    } else if (diffHours < 24) {
        const mins = diffMins % 60;
        return mins > 0 ? `${diffHours}h ${mins}m` : `${diffHours}h`;
    } else {
        const hours = diffHours % 24;
        return hours > 0 ? `${diffDays}d ${hours}h` : `${diffDays}d`;
    }
}

function usageBar(percent, width = 8) {
    const filled = Math.round((percent / 100) * width);
    const empty = width - filled;
    let color = chalk.green;
    if (percent >= 90) color = chalk.red;
    else if (percent >= 70) color = chalk.yellow;
    return color("█".repeat(filled)) + chalk.gray("░".repeat(empty));
}

function formatUsageCell(limit) {
    if (!limit) return chalk.gray("—");
    const bar = usageBar(limit.utilization);
    const pct = limit.utilization.toString().padStart(3) + "%";
    const reset = chalk.gray("   ↻" + formatResetTime(limit.resets_at));
    return `${bar} ${pct}${reset}`;
}

function planLabel(plan) {
    if (plan === "max") return chalk.magenta("Max");
    if (plan === "team") return chalk.blue("Team");
    if (plan === "free") return chalk.red("Free");
    if (plan === "pro") return chalk.cyan("Pro");
    return chalk.gray("—");
}

function formatStatusCell(account) {
    if (account.error) return chalk.red("✗ Error");
    if (account.plan === "free") return chalk.red("✗ Free");
    if (account.plan === "unknown") return chalk.yellow("? Unknown");
    return chalk.green("✓ Active");
}

function getAvailability(account) {
    if (account.error) {
        return { status: "error", waitLabel: account.error, waitMs: Number.POSITIVE_INFINITY, reason: "none" };
    }
    // A Free account cannot run Claude Code work — never recommend it.
    if (account.plan === "free") {
        return { status: "unusable", waitLabel: "Upgrade", waitMs: Number.POSITIVE_INFINITY, reason: "free" };
    }
    const weekly = account.usage.seven_day;
    const session = account.usage.five_hour;
    if (weekly && weekly.utilization >= 100) {
        const waitMs = Math.max(0, new Date(weekly.resets_at).getTime() - Date.now());
        return { status: waitMs <= 0 ? "available" : "wait", waitLabel: formatResetTime(weekly.resets_at), waitMs, reason: "weekly" };
    }
    if (session && session.utilization >= 100) {
        const waitMs = Math.max(0, new Date(session.resets_at).getTime() - Date.now());
        return { status: waitMs <= 0 ? "available" : "wait", waitLabel: formatResetTime(session.resets_at), waitMs, reason: "session" };
    }
    return { status: "available", waitLabel: "now", waitMs: 0, reason: "none" };
}

function formatNextUseLabel(availability) {
    if (availability.status === "unusable") return chalk.red("Upgrade req.");
    if (availability.status === "available" || availability.waitLabel === "now") return chalk.green("Use now");
    if (availability.reason === "weekly") return chalk.yellow(`Wait until ${availability.waitLabel}`);
    return chalk.yellow(`Wait ${availability.waitLabel}`);
}

function pickNextAccount(accounts) {
    // Exclude error rows and Free accounts (Free cannot be used for Pro work).
    const available = accounts.filter((a) => !a.error && a.plan !== "free");
    if (available.length === 0) return null;
    const scored = available.map((account) => ({
        account,
        availability: getAvailability(account),
        score: (account.usage.five_hour?.utilization ?? 0) + (account.usage.seven_day?.utilization ?? 0),
    }));
    const usable = scored.filter((entry) => entry.availability.status === "available");
    if (usable.length > 0) return usable.reduce((a, b) => (a.score <= b.score ? a : b));
    return scored.reduce((a, b) => {
        if (a.availability.waitMs === b.availability.waitMs) return a.score <= b.score ? a : b;
        return a.availability.waitMs <= b.availability.waitMs ? a : b;
    });
}

export function displayUsageTable(accounts) {
    console.log();
    console.log(chalk.bold("  Claude Usage Dashboard"));
    console.log(chalk.gray("  Note: 'Days left' shows rate-limit window resets, not billing renewal dates."));
    console.log();
    const table = new Table({
        head: [chalk.bold("Account"), chalk.bold("Plan"), chalk.bold("Status"), chalk.bold("Session (5h)"), chalk.bold("Weekly (7d)"), chalk.bold("Next Use")],
        style: { head: [], border: [] },
        colWidths: [14, 6, 12, 30, 30, 20],
    });
    for (const account of accounts) {
        const availability = getAvailability(account);
        if (account.error) {
            table.push([chalk.yellow(account.name), chalk.gray("—"), chalk.red("✗ Error"), chalk.gray("—"), chalk.gray("—"), chalk.red(account.error.split(".")[0])]);
            continue;
        }
        table.push([
            account.name,
            planLabel(account.plan),
            formatStatusCell(account),
            formatUsageCell(account.usage.five_hour),
            formatUsageCell(account.usage.seven_day),
            formatNextUseLabel(availability),
        ]);
    }
    console.log(table.toString());
    console.log();
    const next = pickNextAccount(accounts);
    if (next) {
        const nextUseLabel = next.availability.status === "available" ? "Use now" : `Wait ${next.availability.waitLabel}`;
        console.log(chalk.cyan("  💡 Recommendation: ") + chalk.bold(next.account.name) + chalk.gray(` (${nextUseLabel})`));
        console.log();
    }
}

export function displayBillingTable(billingData) {
    console.log(chalk.bold("  Billing Status"));
    console.log();
    const table = new Table({
        head: [chalk.bold("Account"), chalk.bold("Plan"), chalk.bold("Paid"), chalk.bold("Renewal"), chalk.bold("Auto-Renew")],
        style: { head: [], border: [] },
        colWidths: [14, 8, 9, 21, 13],
    });
    for (const b of billingData) {
        const paidLabel = b.paid === true ? chalk.green("✓ Paid") : b.paid === false ? chalk.gray("Free") : chalk.gray("—");
        let renewal = chalk.gray("—");
        if (b.billingDate) {
            const d = new Date(b.billingDate);
            const days = b.daysLeft != null ? b.daysLeft : Math.ceil((d.getTime() - Date.now()) / 86400000);
            const dateStr = d.toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" });
            renewal = `${days <= 0 ? chalk.red("expired") : days + "d"} · ${dateStr}`;
        } else if (b.daysLeft != null) {
            renewal = b.daysLeft <= 0 ? chalk.red("expired") : `~${b.daysLeft}d`;
        } else if (b.error) {
            renewal = chalk.yellow(b.error.split("—")[0].trim());
        }
        const autoRenewLabel = b.autoRenew === true ? chalk.green("✓ Auto") : b.autoRenew === false ? chalk.red("✗ Expires") : chalk.gray("—");
        table.push([b.name, planLabel(b.plan), paidLabel, renewal, autoRenewLabel]);
    }
    console.log(table.toString());
    console.log();
}

export function displayQuickRecommendation(accounts) {
    const next = pickNextAccount(accounts);
    if (!next) {
        console.log(chalk.red("No accounts available. Run: claudestatus add <name>"));
        return;
    }
    const nextUseLabel = next.availability.status === "available" ? "Use now" : `Wait ${next.availability.waitLabel}`;
    console.log(`${next.account.name} (${nextUseLabel})`);
}
DISPLAY_EOF

    local api_js="${npm_root}/@howells/claudestatus/dist/api.js"
    [[ -f "$api_js" ]] && _claudestatus_patch_api "$api_js"

    local cli_js="${npm_root}/@howells/claudestatus/dist/cli.js"
    [[ -f "$cli_js" ]] && _claudestatus_patch_cli "$cli_js"

    print_status "success" "claudestatus patched (display + billing scraper)"
}

_claudestatus_patch_api() {
    local api_js="$1"
    # Rewrite the usage-path plan snippets to classifyPlan() (free/pro/max/team).
    python3 - "$api_js" <<'PLAN_EOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = ('        const plan = org.capabilities.includes("claude_max")\n'
       '            ? "max"\n'
       '            : org.capabilities.includes("chat")\n'
       '                ? "pro"\n'
       '                : "unknown";')
s2 = s.replace(old, '        const plan = classifyPlan(org.capabilities);')
if s2 != s:
    p.write_text(s2)
PLAN_EOF
    grep -q "fetchBillingForAccount" "$api_js" && return 0
    cat >> "$api_js" << 'API_EOF'
function classifyPlan(capabilities) {
    const c = capabilities || [];
    if (c.includes("claude_max")) return "max";
    if (c.includes("claude_pro")) return "pro";
    if (c.includes("raven")) return "team";
    if (c.includes("chat")) return "free";
    return "unknown";
}
const PT_MONTHS = { jan: 0, fev: 1, mar: 2, abr: 3, mai: 4, jun: 5, jul: 6, ago: 7, set: 8, out: 9, nov: 10, dez: 11 };
const EN_MONTHS = { jan: 0, feb: 1, mar: 2, apr: 3, may: 4, jun: 5, jul: 6, aug: 7, sep: 8, oct: 9, nov: 10, dec: 11 };
function parseBillingDate(day, monthStr, year, locale) {
    const table = locale === "pt" ? PT_MONTHS : EN_MONTHS;
    const m = table[monthStr.slice(0, 3).toLowerCase()];
    if (m === undefined)
        return null;
    return new Date(parseInt(year, 10), m, parseInt(day, 10));
}
function parseBillingText(text) {
    let period = "unknown";
    let autoRenew = null;
    let billingDate = null;
    let daysLeft = null;
    // Relative day counters from the plan banner (PT: "termina em 12 dias").
    const relPt = text.match(/termina em (\d+)\s+dias?/i);
    if (relPt)
        daysLeft = parseInt(relPt[1], 10);
    const relEn = text.match(/ends?\s+in\s+(\d+)\s+days?/i);
    if (daysLeft === null && relEn)
        daysLeft = parseInt(relEn[1], 10);
    // Auto-renew signals. "Reassinar" / "Fazer Upgrade" mean the plan is lapsing.
    if (/reassinar|fazer upgrade|resubscribe/i.test(text))
        autoRenew = false;
    else if (/renova(?:ção)?\s+autom|renews automatically|próxima cobran|next billing/i.test(text))
        autoRenew = true;
    if (/mensal|monthly/i.test(text))
        period = "monthly";
    else if (/anual|annual|yearly/i.test(text))
        period = "annual";
    // Absolute-date fallbacks.
    const cancelPt = text.match(/será cancelada em (\d+) de (\w+)\.?\s*de (\d{4})/i);
    const renewPt = text.match(/(?:será renovada(?: automaticamente)?|próxima cobrança)\s+em\s+(\d+) de (\w+)\.?\s*de (\d{4})/i);
    const cancelEn = text.match(/(?:will\s+be\s+cancell?ed|(?:subscription\s+)?cancels)\s+on\s+(\w+)\s+(\d{1,2}),?\s+(\d{4})/i);
    const renewEn = text.match(/(?:(?:will\s+)?renews?(?: automatically)?|next\s+(?:billing|renewal))\s+(?:on\s+)?(\w+)\s+(\d{1,2}),?\s+(\d{4})/i);
    if (cancelPt) {
        autoRenew = false;
        billingDate = parseBillingDate(cancelPt[1], cancelPt[2], cancelPt[3], "pt");
    }
    else if (renewPt) {
        if (autoRenew === null)
            autoRenew = true;
        billingDate = parseBillingDate(renewPt[1], renewPt[2], renewPt[3], "pt");
    }
    else if (cancelEn) {
        autoRenew = false;
        billingDate = parseBillingDate(cancelEn[2], cancelEn[1], cancelEn[3], "en");
    }
    else if (renewEn) {
        if (autoRenew === null)
            autoRenew = true;
        billingDate = parseBillingDate(renewEn[2], renewEn[1], renewEn[3], "en");
    }
    if (!billingDate && daysLeft !== null)
        billingDate = new Date(Date.now() + daysLeft * 86400000);
    return { period, autoRenew, billingDate, daysLeft };
}
// Cloudflare-free: read plan + paid status straight from the JSON API.
async function fetchBillingMetaViaApi(storagePath) {
    if (!fs.existsSync(storagePath))
        return { plan: "unknown", paid: null };
    const api = await request.newContext({
        baseURL: CLAUDE_URL,
        storageState: storagePath,
        extraHTTPHeaders: { "User-Agent": USER_AGENT, Accept: "application/json" },
    });
    try {
        const orgsRes = await api.get("/api/organizations");
        if (!orgsRes.ok())
            return { plan: "unknown", paid: null };
        const orgs = await orgsRes.json();
        const org = orgs.find((o) => o.capabilities?.includes("chat")) || orgs[0];
        const plan = classifyPlan(org?.capabilities);
        let paid = plan === "free" ? false : null;
        if (org?.uuid) {
            const detail = await api.get(`/api/organizations/${org.uuid}`);
            if (detail.ok()) {
                const d = await detail.json();
                if (typeof d.billing_type === "string")
                    paid = d.billing_type !== "none";
            }
        }
        return { plan, paid };
    }
    catch {
        return { plan: "unknown", paid: null };
    }
    finally {
        await api.dispose();
    }
}
export async function fetchBillingForAccount(name) {
    const profileDir = getProfileDir(name);
    const storagePath = getStorageStatePath(name);
    if (!fs.existsSync(profileDir) && !fs.existsSync(storagePath)) {
        return { plan: "unknown", paid: null, period: "unknown", autoRenew: null, billingDate: null, daysLeft: null };
    }
    // 1) API-first (no Cloudflare): plan + paid/free.
    const meta = await fetchBillingMetaViaApi(storagePath);
    const base = { plan: meta.plan, paid: meta.paid, period: "unknown", autoRenew: null, billingDate: null, daysLeft: null };
    // Free accounts have no subscription to scrape — done, no browser needed.
    if (meta.plan === "free" || meta.paid === false) {
        return { ...base, paid: false, period: "free" };
    }
    // 2) Best-effort: scrape the plan banner for the renewal date (PT-aware). On a
    //    Cloudflare/parse failure, return the API plan + paid so the row shows the
    //    plan instead of a bare "Cloudflare block".
    const contextOpts = {
        headless: false,
        channel: "chrome",
        args: [
            "--disable-blink-features=AutomationControlled",
            "--disable-extensions",
            "--window-size=800,600",
            "--window-position=-32000,-32000",
        ],
        ignoreDefaultArgs: ["--enable-automation"],
        viewport: { width: 800, height: 600 },
    };
    if (fs.existsSync(storagePath))
        contextOpts.storageState = storagePath;
    const context = await chromium.launchPersistentContext(profileDir, contextOpts);
    const page = context.pages()[0] || (await context.newPage());
    try {
        await page.goto(CLAUDE_URL, { waitUntil: "domcontentloaded", timeout: 30000 });
        await page.waitForTimeout(2000);
        await page.goto(`${CLAUDE_URL}/settings/billing`, { waitUntil: "domcontentloaded", timeout: 30000 });
        try {
            await page.getByRole("button", { name: /reject all|accept all/i }).first().click({ timeout: 3000 });
        }
        catch {
            // No cookie banner shown.
        }
        try {
            await page.waitForFunction(() => {
                const t = document.body.innerText || "";
                if (/just a moment/i.test(t))
                    return false;
                if (/^\s*loading/i.test(t))
                    return false;
                return /(termina em|renova|próxima cobran|reassinar|monthly|annual|mensal|anual|renew|cancel|plano|plan)/i.test(t);
            }, { timeout: 20000 });
        }
        catch {
            // Timed out — parse whatever rendered below.
        }
        const text = await page.evaluate(() => document.body.innerText);
        // Read-only flow — never persist storageState (would clobber the session).
        await context.close();
        const parsed = parseBillingText(text);
        if (parsed.billingDate || parsed.daysLeft !== null || parsed.period !== "unknown" || parsed.autoRenew !== null) {
            return { ...base, ...parsed, paid: true };
        }
        fs.writeFileSync(`/tmp/claudestatus_billing_${name}.txt`, text);
        return { ...base, paid: true };
    }
    catch {
        await context.close().catch(() => { });
        // Cloudflare / navigation error — still report the API-derived plan + paid.
        return { ...base, paid: meta.paid === null ? true : meta.paid };
    }
}
export async function fetchAllBilling(accountNames) {
    const results = [];
    for (const name of accountNames) {
        process.stdout.write(`  Billing ${name}...`);
        const billing = await fetchBillingForAccount(name);
        console.log(" done");
        results.push({ name, ...billing });
    }
    return results;
}
API_EOF
}

_claudestatus_patch_cli() {
    local cli_js="$1"
    grep -q "fetchAllBilling" "$cli_js" && return 0
    sed -i \
        's|import { addAccount, fetchAllUsage } from "./api.js";|import { addAccount, fetchAllUsage, fetchAllBilling } from "./api.js";|' \
        "$cli_js"
    sed -i \
        's|import { displayUsageTable, displayQuickRecommendation } from "./display.js";|import { displayUsageTable, displayBillingTable, displayQuickRecommendation } from "./display.js";|' \
        "$cli_js"
    sed -i \
        's|const usage = await fetchAllUsage(accounts.map((a) => a.name));|const names = accounts.map((a) => a.name); const usage = await fetchAllUsage(names);|' \
        "$cli_js"
    sed -i \
        's|if (options.quick) {|if (options.quick) { displayQuickRecommendation(usage); return; } displayUsageTable(usage); console.log(chalk.gray("\\nFetching billing data (browser windows will flash briefly)...\\n")); const billing = await fetchAllBilling(names); displayBillingTable(billing); if (false) {|' \
        "$cli_js"
}

# ============================================================================
# RTK (Rust Token Killer)
# ============================================================================

install_rtk() {
    print_status "section" "RTK (RUST TOKEN KILLER)"

    if ! command_exists rtk; then
        if ! command_exists brew; then
            print_status "error" "Homebrew not found — install Homebrew first"
            return 1
        fi

        print_status "info" "Installing rtk via Homebrew..."
        if run_or_echo brew install rtk &>> "$LOG_FILE"; then
            print_status "success" "rtk installed successfully"
        else
            print_status "error" "rtk installation failed — check $LOG_FILE"
            return 1
        fi
    else
        print_status "info" "rtk already installed"
    fi

    # The PreToolUse hook is owned by ai_clients/claude/settings.json (wired through
    # rtk_worktree_passthrough.sh, #417); --no-patch keeps rtk from appending a direct
    # hook that revives that deadlock. stdin is closed so rtk's telemetry prompt cannot
    # block the run behind the log redirect (#633). Guard on RTK.md, rtk's own artifact.
    # rtk init -g exits 1 and writes nothing when ~/.claude is absent (measured), which is
    # the fresh-machine case: install_rtk runs before make ai_clients creates it.
    if [ ! -f "$HOME/.claude/RTK.md" ]; then
        print_status "info" "Initializing RTK for Claude Code..."
        mkdir -p "$HOME/.claude"
        if rtk init -g --no-patch </dev/null &>> "$LOG_FILE"; then
            print_status "success" "RTK initialized (hook is deployed by make ai_clients)"
        else
            print_status "warning" "RTK init failed — run manually: rtk init -g --no-patch"
        fi
    else
        print_status "info" "RTK already initialized"
    fi

    print_status "config" "Usage: rtk <command> (e.g. rtk git status, rtk tree)"
}

# ============================================================================
# FASTER-WHISPER (local speech-to-text)
# ============================================================================

install_faster_whisper() {
    print_status "section" "FASTER-WHISPER (SPEECH-TO-TEXT)"

    # faster-whisper is a Python *library* (CTranslate2 backend, ~4x faster than
    # openai-whisper) with no CLI of its own. whisper-ctranslate2 is the
    # maintained command-line frontend built directly on it, so installing it
    # yields both the engine and a usable `whisper-ctranslate2` command. Audio is
    # decoded via PyAV (bundled ffmpeg), so no system ffmpeg package is required.
    if command_exists whisper-ctranslate2; then
        print_status "info" "whisper-ctranslate2 already installed"
        return 0
    fi

    if ! command_exists pipx; then
        print_status "error" "pipx not found — run install_pipx first"
        return 1
    fi

    # ctranslate2 ships no wheels for Python 3.14; pin to the pyenv 3.12.8 that
    # install_pyenv provisions so the isolated venv is built on a supported
    # interpreter regardless of the system default.
    local python_bin="$HOME/.pyenv/versions/3.12.8/bin/python"
    if [ ! -x "$python_bin" ]; then
        print_status "error" "Python 3.12.8 not found at $python_bin — run install_pyenv first"
        return 1
    fi

    print_status "info" "Installing whisper-ctranslate2 (faster-whisper CLI) via pipx..."
    if run_or_echo pipx install --python "$python_bin" whisper-ctranslate2 &>> "$LOG_FILE"; then
        print_status "success" "faster-whisper installed (command: whisper-ctranslate2)"
        # --device auto probes CUDA and fails without libcublas; cpu is the
        # portable default. Drop --device for GPU once CUDA libs are present.
        print_status "config" "Usage: whisper-ctranslate2 audio.m4a --language pt --model small --device cpu --compute_type int8"
    else
        print_status "error" "whisper-ctranslate2 installation failed — check $LOG_FILE"
        return 1
    fi
}

# ============================================================================
# HEADROOM (CONTEXT COMPRESSION FOR AI AGENTS)
# ============================================================================

install_headroom() {
    print_status "section" "HEADROOM (AI CONTEXT COMPRESSION)"

    # Headroom's core is Rust, but the `headroom` CLI ships inside the Python
    # distribution, so pipx yields the command in its own isolated venv.
    # Upstream recommends `uv tool install`; pipx does the same job and is
    # already a bootstrapper here (install_pipx), so no second tool manager.
    if command_exists headroom; then
        print_status "info" "headroom already installed"
        return 0
    fi

    if ! command_exists pipx; then
        print_status "error" "pipx not found — run install_pipx first"
        return 1
    fi

    # ponytail: no --python pin, unlike install_faster_whisper. The [all] extra
    # pulls prebuilt wheels; pin to a pyenv interpreter here if a future system
    # Python ever ships without them (upstream builds against 3.13).
    print_status "info" "Installing headroom-ai[all] via pipx..."
    if run_or_echo pipx install "headroom-ai[all]" &>> "$LOG_FILE"; then
        print_status "success" "headroom installed (command: headroom)"
        print_status "config" "Run 'headroom --help'; docs: https://github.com/headroomlabs-ai/headroom"
    else
        print_status "error" "headroom installation failed — check $LOG_FILE"
        return 1
    fi
}

INSTALL_REGISTRY+=(
    "install_ollama:Ollama AI Platform::"
    "install_claude_code:Claude Code::"
    "install_github_copilot_cli:GitHub Copilot CLI::"
    "install_qwen:Qwen Code::"
    "install_codex:OpenAI Codex CLI::"
    "install_kimi:Kimi Code CLI (Moonshot AI)::"
    "install_codexbar:CodexBar (Codex Usage & Spend tray):Utilitarios:com.steipete.CodexBar.desktop"
    "install_claudestatus:claudestatus (Claude Usage Dashboard)::"
    "install_rtk:RTK (Rust Token Killer)::"
    "install_faster_whisper:faster-whisper (Speech-to-Text CLI)::"
    "install_headroom:Headroom (AI Context Compression)::"
)
