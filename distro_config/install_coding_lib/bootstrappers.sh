#!/bin/bash
#
# distro_config/install_coding_lib/bootstrappers.sh
#
# Foundational installers: core dependencies, package managers, version managers.
# Most other coding installs depend on at least one of these being run first.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "bootstrappers.sh is meant to be sourced, not executed." >&2
    exit 1
fi

install_core_dependencies() {
    print_status "section" "CORE DEPENDENCIES"

    print_status "info" "Installing curl and SSL libraries..."
    case "$PACKAGE_MANAGER" in
        apt)        $INSTALL_CMD curl wget libcurl4-openssl-dev libssl-dev libnotify-bin ;;
        dnf|yum)    $INSTALL_CMD curl wget libcurl-devel openssl-devel ;;
        pacman)     $INSTALL_CMD curl wget openssl ;;
        zypper)     $INSTALL_CMD curl wget libcurl-devel libopenssl-devel ;;
    esac

    print_status "info" "Installing media codecs..."
    case "$PACKAGE_MANAGER" in
        apt)
            $INSTALL_CMD ubuntu-restricted-extras || print_status "warning" "Restricted extras not available"
            ;;
        dnf|yum)
            print_status "info" "Installing RPM Fusion repositories..."
            sudo $PACKAGE_MANAGER install -y \
                https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-"$(rpm -E %fedora)".noarch.rpm \
                https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-"$(rpm -E %fedora)".noarch.rpm || true
            $INSTALL_CMD ffmpeg gstreamer1-plugins-{bad-\*,good-\*,base} gstreamer1-plugin-openh264 \
                gstreamer1-libav --exclude=gstreamer1-plugins-bad-free-devel || print_status "warning" "Some codecs failed"
            ;;
        pacman)
            $INSTALL_CMD ffmpeg gst-plugins-{base,good,bad,ugly} gst-libav
            ;;
    esac

    print_status "info" "Installing DKMS and Git..."
    install_package "dkms" "dkms" "dkms" "dkms"
    install_package "git" "git" "git" "git"

    if command_exists dkms; then
        dkms --version >> "$LOG_FILE"
    fi
    if command_exists git; then
        git --version >> "$LOG_FILE"
    fi

    print_status "success" "Core dependencies installed"
}

install_homebrew() {
    print_status "section" "HOMEBREW PACKAGE MANAGER"

    if command_exists brew; then
        print_status "info" "Homebrew already installed"
        brew --version >> "$LOG_FILE"
        return 0
    fi

    print_status "info" "Installing Homebrew dependencies..."
    case "$PACKAGE_MANAGER" in
        apt)
            $INSTALL_CMD build-essential procps curl file git
            ;;
        dnf|yum)
            sudo $PACKAGE_MANAGER groupinstall -y 'Development Tools' || \
            sudo $PACKAGE_MANAGER group install -y 'Development Tools'
            $INSTALL_CMD procps-ng curl file git
            ;;
        pacman)
            $INSTALL_CMD base-devel procps-ng curl file git
            ;;
        zypper)
            sudo zypper install -y -t pattern devel_basis
            $INSTALL_CMD procps curl file git
            ;;
    esac

    print_status "info" "Downloading and installing Homebrew..."
    print_status "warning" "This may take several minutes..."

    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    print_status "config" "Configuring Homebrew environment..."

    local brew_path=""
    if [ -d "$HOME/.linuxbrew" ]; then
        brew_path="$HOME/.linuxbrew/bin/brew"
    elif [ -d "/home/linuxbrew/.linuxbrew" ]; then
        brew_path="/home/linuxbrew/.linuxbrew/bin/brew"
    fi

    if [ -z "$brew_path" ]; then
        print_status "error" "Homebrew installation path not found"
        return 1
    fi

    eval "$($brew_path shellenv)"

    if ! grep -q "brew shellenv" ~/.bashrc; then
        echo "" >> ~/.bashrc
        echo "# Homebrew configuration" >> ~/.bashrc
        echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> ~/.bashrc
        print_status "success" "Homebrew added to ~/.bashrc"
    fi

    if ! grep -q "brew shellenv" ~/.profile; then
        echo "" >> ~/.profile
        echo "# Homebrew configuration" >> ~/.profile
        echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> ~/.profile
        print_status "success" "Homebrew added to ~/.profile"
    fi

    if command_exists brew; then
        print_status "info" "Testing Homebrew installation..."
        if run_or_echo brew install hello &>> "$LOG_FILE"; then
            print_status "success" "Homebrew installed and tested successfully"
            brew uninstall hello &>> "$LOG_FILE"
        else
            print_status "warning" "Homebrew installed but test failed"
        fi
    else
        print_status "error" "Homebrew installation failed"
        return 1
    fi

    print_status "success" "Homebrew configured successfully"
    print_status "info" "Homebrew version: $(brew --version | head -n1)"
}

install_asdf() {
    print_status "section" "ASDF VERSION MANAGER"

    if command_exists asdf; then
        print_status "info" "asdf already installed"
        asdf --version >> "$LOG_FILE"
        return 0
    fi

    if ! command_exists brew; then
        print_status "warning" "Homebrew not found. Installing Homebrew first..."
        install_homebrew
    fi

    print_status "info" "Installing asdf via Homebrew..."
    run_or_echo brew install asdf

    print_status "config" "Configuring asdf environment..."

    if ! grep -q "asdf.sh" ~/.bashrc; then
        echo "" >> ~/.bashrc
        echo "# asdf version manager" >> ~/.bashrc
        echo '. $(brew --prefix asdf)/libexec/asdf.sh' >> ~/.bashrc
        print_status "success" "asdf added to ~/.bashrc"
    fi

    if ! grep -q "asdf.sh" ~/.profile; then
        echo "" >> ~/.profile
        echo "# asdf version manager" >> ~/.profile
        echo '. $(brew --prefix asdf)/libexec/asdf.sh' >> ~/.profile
        print_status "success" "asdf added to ~/.profile"
    fi

    if [ -f "$(brew --prefix asdf)/libexec/asdf.sh" ]; then
        . "$(brew --prefix asdf)/libexec/asdf.sh"
    fi

    if command_exists asdf; then
        print_status "success" "asdf installed successfully"
        print_status "info" "asdf version: $(asdf --version)"
        print_status "info" "Available commands: asdf plugin list all, asdf plugin add <name>, asdf install <name> <version>"
    else
        print_status "warning" "asdf installed but not available in current session"
        print_status "info" "Please run: source ~/.bashrc"
    fi

    print_status "success" "asdf configured successfully"
}

install_pyenv() {
    print_status "section" "PYENV (PYTHON VERSION MANAGER)"

    if command_exists pyenv; then
        print_status "info" "pyenv already installed"
        return 0
    fi

    if [ -d "$HOME/.pyenv" ]; then
        print_status "warning" "Found existing ~/.pyenv directory but pyenv command not available"
        print_status "info" "Setting up existing pyenv installation..."

        export PYENV_ROOT="$HOME/.pyenv"
        export PATH="$PYENV_ROOT/bin:$PATH"

        if ! grep -q "PYENV_ROOT" ~/.bashrc; then
            {
                echo 'export PYENV_ROOT="$HOME/.pyenv"'
                echo '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"'
                echo 'eval "$(pyenv init - bash)"'
            } >> ~/.bashrc
            print_status "success" "pyenv configuration added to ~/.bashrc"
        fi

        if ! grep -q "PYENV_ROOT" ~/.profile; then
            {
                echo 'export PYENV_ROOT="$HOME/.pyenv"'
                echo '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"'
                echo 'eval "$(pyenv init - bash)"'
            } >> ~/.profile
            print_status "success" "pyenv configuration added to ~/.profile"
        fi

        eval "$(pyenv init - bash)"

        print_status "success" "Existing pyenv setup completed"
        return 0
    fi

    print_status "info" "Installing pyenv dependencies..."
    run_or_echo sudo apt install -y make build-essential libssl-dev zlib1g-dev \
        libbz2-dev libreadline-dev libsqlite3-dev wget curl llvm \
        libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev

    print_status "info" "Installing pyenv..."
    curl -fsSL https://pyenv.run | bash

    print_status "config" "Adding pyenv to shell configuration..."
    {
        echo 'export PYENV_ROOT="$HOME/.pyenv"'
        echo '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"'
        echo 'eval "$(pyenv init - bash)"'
    } >> ~/.bashrc

    {
        echo 'export PYENV_ROOT="$HOME/.pyenv"'
        echo '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"'
        echo 'eval "$(pyenv init - bash)"'
    } >> ~/.profile

    export PYENV_ROOT="$HOME/.pyenv"
    export PATH="$PYENV_ROOT/bin:$PATH"
    eval "$(pyenv init - bash)"

    print_status "info" "Installing Python 3.12.8..."
    run_or_echo pyenv install 3.12.8

    print_status "success" "pyenv installed with Python 3.12.8"
}

install_pipx() {
    print_status "section" "PYTHON CLI TOOLING (pip + pipx)"

    # Ubuntu 24.04 ships python3 WITHOUT the pip module and without pipx, and
    # PEP 668 blocks `pip install --user`. pipx installs Python CLIs (gitlint,
    # etc.) in isolated venvs — the correct path on modern Debian/Ubuntu. Install
    # both python3-pip (library installs) and pipx (CLI installs) here so later
    # steps that need a Python CLI don't fail with "No module named pip".
    if command_exists pipx; then
        print_status "info" "pipx already installed"
    elif command_exists apt; then
        print_status "info" "Installing python3-pip + pipx via apt..."
        run_or_echo sudo apt install -y python3-pip pipx
    elif command_exists brew; then
        print_status "info" "Installing pipx via Homebrew..."
        run_or_echo brew install pipx &>> "$LOG_FILE"
    else
        print_status "warning" "No apt/brew found — install pipx manually (https://pipx.pypa.io)"
        return 1
    fi

    if command_exists pipx; then
        run_or_echo pipx ensurepath &>> "$LOG_FILE"
        print_status "success" "pipx ready: $(pipx --version 2>/dev/null)"
    else
        print_status "warning" "pipx installed but not on PATH yet — run: pipx ensurepath && source ~/.bashrc"
    fi
}

# Bootstrappers are not registered in INSTALL_REGISTRY here — install_coding.sh
# splices them in as framework-prepended entries (similar to how
# install_programs.sh handles create_dev_folder / update_system / setup_firewall).
