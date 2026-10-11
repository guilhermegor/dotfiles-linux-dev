#!/bin/bash
#
# distro_config/install_coding_lib/vcs.sh
#
# Version control + GitHub workflow tools. Sourced by install_coding.sh.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "vcs.sh is meant to be sourced, not executed." >&2
    exit 1
fi

# GitHub rotates the gh apt signing key: 23F3D4EA75716059 expired in 2026-09 and the published
# keyring now also carries 5612B36462313325. apt then fails with EXPKEYSIG and silently keeps
# stale package lists. Re-fetching on every run, not only on first install, is what survives a
# rotation. No-op when the published keyring is byte-identical to the installed one.
refresh_github_cli_keyring() {
    refresh_apt_keyring https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        "${GITHUB_CLI_KEYRING:-/etc/apt/keyrings/githubcli-archive-keyring.gpg}"
}

install_github_cli() {
    print_status "section" "GITHUB CLI"

    if command_exists gh; then
        print_status "info" "GitHub CLI already installed"
        # Only a gh installed from the apt repo reads that keyring.
        if [ -f /etc/apt/sources.list.d/github-cli.list ]; then
            refresh_github_cli_keyring || return 1
        fi
        return 0
    fi

    print_status "info" "Adding GitHub CLI repository..."
    if ! { refresh_github_cli_keyring \
        && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | run_or_echo sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
        && run_or_echo sudo apt update \
        && run_or_echo sudo apt install -y gh; }; then
        print_status "error" "GitHub CLI install failed — check $LOG_FILE"
        return 1
    fi

    gh --version >> "$LOG_FILE"
    print_status "success" "GitHub CLI installed"
}

install_act() {
    print_status "section" "ACT (RUN GITHUB ACTIONS LOCALLY)"

    if command_exists act; then
        print_status "info" "act already installed"
        return 0
    fi

    if command_exists brew; then
        print_status "info" "Installing act via Homebrew..."
        if run_or_echo brew install act &>> "$LOG_FILE"; then
            print_status "success" "act installed via Homebrew"
            return 0
        fi
        print_status "warning" "Homebrew install failed, falling back to GitHub release..."
    fi

    local arch download_arch tmp_dir tarball_url

    arch=$(uname -m)
    case "$arch" in
        x86_64)  download_arch="x86_64" ;;
        aarch64) download_arch="arm64" ;;
        armv7l)  download_arch="armv7" ;;
        *)
            print_status "warning" "Unsupported architecture for act: $arch"
            return 1
            ;;
    esac

    tmp_dir=$(mktemp -d)
    tarball_url="https://github.com/nektos/act/releases/latest/download/act_Linux_${download_arch}.tar.gz"

    print_status "info" "Downloading act from GitHub releases..."
    if wget -O "$tmp_dir/act.tar.gz" "$tarball_url" 2>>"$LOG_FILE" || \
       run_or_echo curl -L -o "$tmp_dir/act.tar.gz" "$tarball_url" 2>>"$LOG_FILE"; then
        tar -xzf "$tmp_dir/act.tar.gz" -C "$tmp_dir"
        run_or_echo sudo mv "$tmp_dir/act" /usr/local/bin/act
        run_or_echo sudo chmod +x /usr/local/bin/act
    else
        print_status "error" "Failed to download act from GitHub releases"
        rm -rf "$tmp_dir"
        return 1
    fi

    rm -rf "$tmp_dir"

    if command_exists act; then
        act --version >> "$LOG_FILE"
        print_status "success" "act installed: $(act --version 2>/dev/null)"
    else
        print_status "error" "act installation failed — check $LOG_FILE"
        return 1
    fi
}

install_gitleaks() {
    print_status "section" "GITLEAKS (SECRET SCANNER)"

    if command_exists gitleaks; then
        print_status "info" "gitleaks already installed"
        return 0
    fi

    if command_exists brew; then
        print_status "info" "Installing gitleaks via Homebrew..."
        if run_or_echo brew install gitleaks &>> "$LOG_FILE"; then
            print_status "success" "gitleaks installed via Homebrew"
            return 0
        fi
        print_status "warning" "Homebrew install failed, falling back to GitHub release..."
    fi

    local arch download_arch tmp_dir latest_url latest_tag version tarball_url

    arch=$(uname -m)
    case "$arch" in
        x86_64)  download_arch="x64" ;;
        aarch64) download_arch="arm64" ;;
        armv7l)  download_arch="armv7" ;;
        *)
            print_status "warning" "Unsupported architecture for gitleaks: $arch"
            return 1
            ;;
    esac

    latest_url="https://github.com/gitleaks/gitleaks/releases/latest"
    latest_tag=$(curl -sLI -o /dev/null -w '%{url_effective}' "$latest_url" 2>>"$LOG_FILE" | sed 's|.*/tag/||')
    if [ -z "$latest_tag" ]; then
        print_status "error" "Could not resolve latest gitleaks version"
        return 1
    fi
    version="${latest_tag#v}"

    tmp_dir=$(mktemp -d)
    tarball_url="https://github.com/gitleaks/gitleaks/releases/download/${latest_tag}/gitleaks_${version}_linux_${download_arch}.tar.gz"

    print_status "info" "Downloading gitleaks ${latest_tag} from GitHub releases..."
    if wget -O "$tmp_dir/gitleaks.tar.gz" "$tarball_url" 2>>"$LOG_FILE" || \
       run_or_echo curl -L -o "$tmp_dir/gitleaks.tar.gz" "$tarball_url" 2>>"$LOG_FILE"; then
        tar -xzf "$tmp_dir/gitleaks.tar.gz" -C "$tmp_dir"
        run_or_echo sudo mv "$tmp_dir/gitleaks" /usr/local/bin/gitleaks
        run_or_echo sudo chmod +x /usr/local/bin/gitleaks
    else
        print_status "error" "Failed to download gitleaks from GitHub releases"
        rm -rf "$tmp_dir"
        return 1
    fi

    rm -rf "$tmp_dir"

    if command_exists gitleaks; then
        gitleaks version >> "$LOG_FILE"
        print_status "success" "gitleaks installed: $(gitleaks version 2>/dev/null)"
    else
        print_status "error" "gitleaks installation failed — check $LOG_FILE"
        return 1
    fi
}

install_shellcheck() {
    print_status "section" "SHELLCHECK (SHELL SCRIPT LINTER)"

    if command_exists shellcheck; then
        print_status "info" "shellcheck already installed"
        return 0
    fi

    if command_exists brew; then
        print_status "info" "Installing shellcheck via Homebrew..."
        if run_or_echo brew install shellcheck &>> "$LOG_FILE"; then
            print_status "success" "shellcheck installed via Homebrew"
            return 0
        fi
        print_status "warning" "Homebrew install failed, falling back to system package..."
    fi

    # Distro package names: apt/pacman/zypper use 'shellcheck'; Fedora uses 'ShellCheck'.
    print_status "info" "Installing shellcheck via system package manager..."
    install_package shellcheck shellcheck ShellCheck shellcheck &>> "$LOG_FILE"

    if command_exists shellcheck; then
        shellcheck --version >> "$LOG_FILE"
        print_status "success" "shellcheck installed: $(shellcheck --version 2>/dev/null | awk '/^version:/ {print $2}')"
    else
        print_status "error" "shellcheck installation failed — check $LOG_FILE"
        return 1
    fi
}

install_gitlint() {
    print_status "section" "GITLINT (COMMIT MESSAGE LINTER)"

    if command_exists gitlint; then
        print_status "info" "gitlint already installed"
        return 0
    fi

    if command_exists brew; then
        print_status "info" "Installing gitlint via Homebrew..."
        if run_or_echo brew install gitlint &>> "$LOG_FILE"; then
            print_status "success" "gitlint installed via Homebrew"
            return 0
        fi
        print_status "warning" "Homebrew install failed, falling back to pipx..."
    fi

    # pipx installs the CLI in an isolated venv — the correct path on PEP 668
    # distros (Ubuntu 24.04 blocks `pip install --user` and ships python3 with
    # no pip module). The install_pipx bootstrapper normally provides pipx
    # before this step runs.
    if command_exists pipx; then
        print_status "info" "Installing gitlint via pipx..."
        run_or_echo pipx install gitlint-core &>> "$LOG_FILE"
    else
        print_status "warning" "pipx not found — run the 'Python CLI tooling (pip + pipx)' step first"
    fi

    if command_exists gitlint; then
        gitlint --version >> "$LOG_FILE"
        print_status "success" "gitlint installed: $(gitlint --version 2>/dev/null)"
    else
        print_status "error" "gitlint install failed — try: brew install gitlint  OR  pipx install gitlint-core (ensure ~/.local/bin on PATH)"
        return 1
    fi
}

install_bats() {
    print_status "section" "BATS (BASH TEST FRAMEWORK)"

    if command_exists bats; then
        print_status "info" "bats already installed"
        return 0
    fi

    if command_exists brew; then
        print_status "info" "Installing bats via Homebrew..."
        if run_or_echo brew install bats-core &>> "$LOG_FILE"; then
            print_status "success" "bats installed via Homebrew"
            return 0
        fi
        print_status "warning" "Homebrew install failed, falling back to vendored bats-core..."
    fi

    # No-sudo fallback: bats-core ships an install.sh that takes a prefix, so cloning and
    # installing into ~/.local needs neither root nor an interactive apt password (apt would
    # prompt in the harness). ~/.local/bin is expected on PATH (setup_env.sh handles that).
    local tmp_dir
    tmp_dir=$(mktemp -d)

    print_status "info" "Cloning bats-core from GitHub..."
    if run_or_echo git clone --depth 1 https://github.com/bats-core/bats-core.git "$tmp_dir/bats-core" &>> "$LOG_FILE"; then
        run_or_echo "$tmp_dir/bats-core/install.sh" "$HOME/.local" &>> "$LOG_FILE"
    else
        print_status "error" "Failed to clone bats-core from GitHub"
        rm -rf "$tmp_dir"
        return 1
    fi

    rm -rf "$tmp_dir"

    if command_exists bats; then
        bats --version >> "$LOG_FILE"
        print_status "success" "bats installed: $(bats --version 2>/dev/null)"
    else
        print_status "error" "bats install failed — ensure ~/.local/bin is on PATH; check $LOG_FILE"
        return 1
    fi
}

install_coderabbit() {
    print_status "section" "CODERABBIT CLI (AI CODE REVIEW)"

    # `cr` is only a short alias for `coderabbit`; guard on the real command name.
    if command_exists coderabbit; then
        print_status "info" "coderabbit already installed ($(timeout 10 coderabbit --version 2>/dev/null | head -n1 || echo "unknown"))"
        print_status "config" "Authenticate manually if signed out: coderabbit auth login"
        return 0
    fi

    # Homebrew is deliberately NOT used: `coderabbit` ships as a macOS-only cask
    # (`brew install --cask coderabbit`, "Requirements: macOS"), and Homebrew on
    # Linux has no cask support at all — so `brew install coderabbit` can only
    # fail here. The vendor script is the only documented Linux path.
    #
    # Fetched to a temp file instead of piping curl straight into sh: the payload
    # stays inspectable in the log, and the execution can go through run_or_echo
    # so DRY_RUN=1 previews it rather than running a remote installer.
    local tmp_dir
    tmp_dir=$(mktemp -d)

    print_status "info" "Downloading the CodeRabbit install script..."
    if ! curl -fsSL https://cli.coderabbit.ai/install.sh -o "$tmp_dir/install.sh" 2>> "$LOG_FILE"; then
        print_status "error" "Failed to download the CodeRabbit install script"
        rm -rf "$tmp_dir"
        return 1
    fi

    print_status "info" "Running the CodeRabbit installer..."
    # The script ends in a "Sign in to CodeRabbit?" prompt that reads stdin, falling back to
    # /dev/tty — with its output in the log the prompt is invisible and the run hangs. CI=1 is
    # the vendor's own switch to skip it; closing stdin alone is not enough because of the tty
    # fallback.
    if run_or_echo env CI=1 sh "$tmp_dir/install.sh" < /dev/null &>> "$LOG_FILE"; then
        print_status "success" "coderabbit installed (command: coderabbit, alias: cr)"
        # Auth opens a browser and is per-user — never trigger it from the installer.
        print_status "config" "Authenticate manually: coderabbit auth login"
    else
        print_status "error" "coderabbit install failed — ensure ~/.local/bin is on PATH; check $LOG_FILE"
        rm -rf "$tmp_dir"
        return 1
    fi

    rm -rf "$tmp_dir"
}

INSTALL_REGISTRY+=(
    "install_github_cli:GitHub CLI::"
    "install_act:act (Run GitHub Actions Locally)::"
    "install_gitleaks:Gitleaks (Secret Scanner)::"
    "install_shellcheck:shellcheck (Shell Script Linter)::"
    "install_gitlint:gitlint (Commit Message Linter)::"
    "install_bats:bats (Bash Test Framework)::"
    "install_coderabbit:CodeRabbit CLI (AI Code Review)::"
)
