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
# HOSTED-REVIEWER CLI: Greptile (dotfiles-linux-dev#713)
# ============================================================================

# Installers only install. Authentication is a manual, per-user step the
# installer prints as a hint — a token is never embedded, requested, or logged.
# (CodeRabbit and Graphite are GitHub-workflow tools: install_coding_lib/vcs.sh.)
install_greptile() {
    print_status "section" "GREPTILE CLI INSTALLATION"

    if command_exists greptile; then
        print_status "info" "Greptile CLI is already installed ($(timeout 10 greptile --version 2>/dev/null | head -n1 || echo "unknown"))"
        print_status "config" "  Login (manual, if signed out, opens a browser): greptile login"
        return 0
    fi

    if ! command_exists npm; then
        print_status "error" "npm is not available. Please ensure Node.js is properly installed."
        return 1
    fi

    # The greptile package needs Node >= 22.
    local node_major
    node_major=$(node --version 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/')
    if [[ ! "$node_major" =~ ^[0-9]+$ ]] || [ "$node_major" -lt 22 ]; then
        print_status "error" "Greptile CLI needs Node.js >= 22 (found: ${node_major:-none})"
        return 1
    fi

    print_status "info" "Installing greptile globally via npm..."
    run_or_echo npm install -g greptile@latest &>> "$LOG_FILE"

    # A DRY_RUN preview installs nothing, so the binary check below would be a false failure.
    if [ "${DRY_RUN:-0}" = "1" ]; then
        print_status "info" "DRY_RUN: would install greptile; skipping verification"
        return 0
    fi

    if command_exists greptile; then
        print_status "success" "Greptile CLI installed (command: greptile)"
        print_status "success" "greptile version: $(timeout 10 greptile --version 2>/dev/null | head -n1 || echo "Not available")"
        print_status "config" "  Login (manual, opens a browser): greptile login"
        print_status "config" "  Update: npm update -g greptile"
    else
        print_status "error" "Greptile CLI installation failed — check $LOG_FILE"
        return 1
    fi
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

# Delegates to ai_clients/claude/lib/patch_claudestatus.sh, the single patcher (api.js billing
# block, display.js, cli.js, billing_cache.js). Re-run it by hand after any npm reinstall.
_claudestatus_patch_display() {
    local patcher
    patcher="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/ai_clients/claude/lib/patch_claudestatus.sh"
    if [[ ! -f "$patcher" ]]; then
        print_status "warning" "claudestatus patcher not found at $patcher — skipping patch"
        return 0
    fi

    print_status "info" "Patching claudestatus (display + cached billing scraper)..."
    if bash "$patcher" &>> "$LOG_FILE"; then
        print_status "success" "claudestatus patched (display + billing scraper)"
    else
        print_status "error" "claudestatus patch failed — check $LOG_FILE"
        return 1
    fi
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
    "install_greptile:Greptile CLI::"
    "install_claudestatus:claudestatus (Claude Usage Dashboard)::"
    "install_rtk:RTK (Rust Token Killer)::"
    "install_faster_whisper:faster-whisper (Speech-to-Text CLI)::"
    "install_headroom:Headroom (AI Context Compression)::"
)
