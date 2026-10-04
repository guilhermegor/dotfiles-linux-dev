#!/usr/bin/env bats
#
# Unit tests for install_codexbar (dotfiles-linux-dev#563): distribution-flexible
# install of the CodexBar Codex/Claude usage tray (Swift CLI + Qt 6 desktop),
# replacing upstream's per-distro README shopping list + hand-run `sh` block.
#
# Strategy: throwaway $HOME, no network, no root, no real Qt/glibc probed —
# getconf/dpkg-query/gh/curl are stubbed on PATH so every guard is exercised
# deterministically regardless of what is actually installed on the runner.
#
# Run locally: bats tests/

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP="$(mktemp -d)"
    HOME="$TMP/home"
    mkdir -p "$HOME"
    export HOME
    export LOG_FILE="$TMP/log"
    mkdir -p "$TMP/bin"
    export PATH="$TMP/bin:$PATH"

    # shellcheck source=../distro_config/install_lib/_common.sh
    source "$REPO_ROOT/distro_config/install_lib/_common.sh"
    PACKAGE_MANAGER="apt"
    INSTALL_CMD="true"

    # shellcheck source=../distro_config/install_coding_lib/ai_clients.sh
    source "$REPO_ROOT/distro_config/install_coding_lib/ai_clients.sh"

    # A passing baseline every guard test overrides one piece of: real
    # x86_64/glibc 2.39+/Qt 6.5 hosts, a working gh download, and a codexbar
    # binary that appears on PATH once the (never-real) install.py "ran".
    uname() { [ "$1" = "-m" ] && echo "x86_64" || command uname "$@"; }
    export -f uname
    getconf() { [ "$1" = "GNU_LIBC_VERSION" ] && echo "glibc 2.39" || command getconf "$@"; }
    export -f getconf
    dpkg-query() { echo "6.5.2-1"; }
    export -f dpkg-query
    apt-cache() { return 0; }
    export -f apt-cache
}

teardown() {
    rm -rf "$TMP"
}

_write_gh_stub_ok() {
    cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
# Emulate `gh release download`: drop matching archives + real checksums.
dest="."
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    [ "${args[$i]}" = "--dir" ] && dest="${args[$((i + 1))]}"
done
mkdir -p "$dest"
for name in CodexBarCLI-v9.9.9-linux-x86_64.tar.gz CodexBarDesktop-v9.9.9-linux-x86_64.tar.gz; do
    tar -czf "$dest/$name" -T /dev/null
    (cd "$dest" && sha256sum "$name" > "$name.sha256")
done
STUB
    chmod +x "$TMP/bin/gh"
}

# codexbar-linux only needs to exist on PATH for command_exists to see it —
# install.py itself is never invoked for real in these tests.
_stub_codexbar_linux_on_path() {
    cat > "$TMP/bin/codexbar-linux" <<'STUB'
#!/bin/bash
echo "codexbar-linux 9.9.9"
STUB
    chmod +x "$TMP/bin/codexbar-linux"
}

# --- guards: fail loudly, never silently -------------------------------------

@test "install_codexbar refuses an unsupported architecture" {
    uname() { [ "$1" = "-m" ] && echo "riscv64" || command uname "$@"; }
    export -f uname
    run install_codexbar
    [ "$status" -eq 1 ]
    [[ "$output" == *"x86_64/aarch64"* ]]
}

@test "install_codexbar refuses glibc below 2.39" {
    getconf() { [ "$1" = "GNU_LIBC_VERSION" ] && echo "glibc 2.31" || command getconf "$@"; }
    export -f getconf
    run install_codexbar
    [ "$status" -eq 1 ]
    [[ "$output" == *"glibc 2.39"* ]]
}

@test "install_codexbar accepts glibc exactly at the 2.39 floor" {
    # Only asserts the guard does not reject 2.39 itself; a later guard
    # (Qt, or the download stub not being installed here) may still fail.
    getconf() { [ "$1" = "GNU_LIBC_VERSION" ] && echo "glibc 2.39" || command getconf "$@"; }
    export -f getconf
    run install_codexbar
    [[ "$output" != *"requires glibc 2.39+"* ]]
}

@test "install_codexbar refuses Qt below 6.4 after installing the runtime set" {
    dpkg-query() { echo "6.2.4-2"; }
    export -f dpkg-query
    run install_codexbar
    [ "$status" -eq 1 ]
    [[ "$output" == *"Qt 6.4+"* ]]
}

@test "install_codexbar refuses when curl is unavailable" {
    curl() { return 127; }
    export -f curl
    command_exists() { [ "$1" = "curl" ] && return 1; command -v "$1" &>/dev/null; }
    export -f command_exists
    run install_codexbar
    [ "$status" -eq 1 ]
    [[ "$output" == *"curl"* ]]
}

@test "install_codexbar refuses an unknown package manager's Qt runtime set" {
    PACKAGE_MANAGER="zypper"
    run install_codexbar
    [ "$status" -eq 1 ]
    [[ "$output" == *"No known Qt 6/QML runtime package set"* ]]
}

# --- download path: checksums verified before either archive is extracted ---

@test "install_codexbar fails when a release checksum does not verify" {
    cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
dest="."
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    [ "${args[$i]}" = "--dir" ] && dest="${args[$((i + 1))]}"
done
mkdir -p "$dest"
for name in CodexBarCLI-v9.9.9-linux-x86_64.tar.gz CodexBarDesktop-v9.9.9-linux-x86_64.tar.gz; do
    tar -czf "$dest/$name" -T /dev/null
    echo "0000000000000000000000000000000000000000000000000000000000000000  $name" > "$dest/$name.sha256"
done
STUB
    chmod +x "$TMP/bin/gh"

    run install_codexbar
    [ "$status" -eq 1 ]
    [[ "$output" == *"Checksum verification failed"* ]]
    # Neither archive's contents were ever trusted enough to extract.
    [ ! -d "$HOME/.local/lib/codexbar-cli" ] || [ -z "$(ls -A "$HOME/.local/lib/codexbar-cli" 2>/dev/null)" ]
}

@test "install_codexbar reports a missing CLI archive rather than silently continuing" {
    cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
exit 0
STUB
    chmod +x "$TMP/bin/gh"
    run install_codexbar
    [ "$status" -eq 1 ]
    [[ "$output" == *"Missing a CodexBar release archive"* ]]
}

@test "install_codexbar never prompts (no interactive read)" {
    fn="$(declare -f install_codexbar _codexbar_download_release _codexbar_install_qt_runtime)"
    [[ "$fn" != *$'\nread '* ]]
    [[ "$fn" != *$'\n    read '* ]]
}

# --- registry entry shape (dotfiles-linux-dev#563) ---------------------------------

@test "INSTALL_REGISTRY has an install_codexbar entry with the verified fields" {
    local entry fn label folder desktop found=0
    for entry in "${INSTALL_REGISTRY[@]}"; do
        if [[ "$entry" == install_codexbar:* ]]; then
            found=1
            IFS=':' read -r fn label folder desktop <<< "$entry"
            [ "$folder" = "Utilitarios" ]
            [ "$desktop" = "com.steipete.CodexBar.desktop" ]
        fi
    done
    [ "$found" -eq 1 ]
}

@test "validate_registry passes with install_codexbar registered" {
    run validate_registry
    [ "$status" -eq 0 ]
}
