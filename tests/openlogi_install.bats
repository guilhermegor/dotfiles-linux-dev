#!/usr/bin/env bats
#
# Unit tests for the Solaar -> openlogi swap (issues #235, #236, #237).
#
# Strategy: source the real install_lib/_common.sh + system_utils.sh and
# assert on the resulting function/registry state, plus the tracked
# config.toml symlink behaviour. No test invokes install_openlogi() itself
# (that would download/apt-install for real), only the pure _link_openlogi_config
# helper against a throwaway $HOME.
#
# Run locally: bats tests/

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    HOME="$(mktemp -d)"
    export HOME

    # shellcheck source=../distro_config/install_lib/_common.sh
    source "$REPO_ROOT/distro_config/install_lib/_common.sh"
    PACKAGE_MANAGER="apt"
    INSTALL_CMD="run_or_echo sudo apt-get install -y"

    # shellcheck source=../distro_config/install_lib/system_utils.sh
    source "$REPO_ROOT/distro_config/install_lib/system_utils.sh"
}

teardown() {
    rm -rf "$HOME"
}

# refute_repo_grep PATTERN FILE
# Asserts PATTERN never appears in FILE. NOT `! grep -q …`: bash exempts a
# `!`-inverted command from `set -e`, so such a line is not a real assertion
# unless it happens to be the test's last statement (issue #380).
refute_repo_grep() {
    run grep -q -- "$1" "$2"
    [ "$status" -ne 0 ]
}

# --- openlogi is wired up -----------------------------------------------------

@test "install_openlogi and verify_openlogi are defined" {
    declare -F install_openlogi
    declare -F verify_openlogi
}

@test "INSTALL_REGISTRY has an install_openlogi entry" {
    local found=0
    for entry in "${INSTALL_REGISTRY[@]}"; do
        [[ "$entry" == install_openlogi:* ]] && found=1
    done
    [ "$found" -eq 1 ]
}

@test "validate_registry passes with install_openlogi registered" {
    run validate_registry
    [ "$status" -eq 0 ]
}

@test "the tracked openlogi config.toml exists in the repo" {
    [ -f "$REPO_ROOT/distro_config/dotfiles/openlogi/config.toml" ]
}

# --- download arch mapping (release assets are named linux-amd64 / linux-arm64) --

@test "_openlogi_download_arch maps amd64/x86_64 to the release asset arch amd64" {
    [ "$(_openlogi_download_arch amd64)" = "amd64" ]
    [ "$(_openlogi_download_arch x86_64)" = "amd64" ]
}

@test "_openlogi_download_arch maps arm64/aarch64 to arm64" {
    [ "$(_openlogi_download_arch arm64)" = "arm64" ]
    [ "$(_openlogi_download_arch aarch64)" = "arm64" ]
}

@test "_openlogi_download_arch fails on an unsupported architecture" {
    run _openlogi_download_arch riscv64
    [ "$status" -ne 0 ]
}

@test "_link_openlogi_config symlinks the tracked config.toml into place" {
    _link_openlogi_config
    [ -L "$HOME/.config/openlogi/config.toml" ]
    [ "$(readlink -f "$HOME/.config/openlogi/config.toml")" = \
      "$(readlink -f "$REPO_ROOT/distro_config/dotfiles/openlogi/config.toml")" ]
}

@test "_link_openlogi_config backs up a pre-existing non-symlink config" {
    mkdir -p "$HOME/.config/openlogi"
    echo "pre-existing" > "$HOME/.config/openlogi/config.toml"

    _link_openlogi_config

    [ -L "$HOME/.config/openlogi/config.toml" ]
    compgen -G "$HOME/.config/openlogi/config.toml.bak.*" > /dev/null
}

# --- Solaar is fully removed ---------------------------------------------------

@test "install_solaar no longer exists" {
    run declare -F install_solaar
    [ "$status" -ne 0 ]
}

@test "INSTALL_REGISTRY has no solaar entry" {
    local entry
    for entry in "${INSTALL_REGISTRY[@]}"; do
        [[ "$entry" != *solaar* ]]
    done
}

@test "the utilities rollup no longer installs solaar" {
    refute_repo_grep "solaar" "$REPO_ROOT/distro_config/install_lib/system_utils.sh"
}

@test "ubuntu_workspace.sh no longer places a solaar .desktop entry" {
    refute_repo_grep "solaar" "$REPO_ROOT/distro_config/ubuntu_workspace.sh"
}

# --- install flow (issue #766: vendor route 404, SHA256SUMS lived nowhere) -------
# curl, sudo, dpkg and systemctl are stubs: curl serves fixtures from $SERVE by
# URL and logs every URL, sudo/systemctl only log. Nothing touches the network.

_stub_install_flow() {
    SERVE="$HOME/serve"; CALLS="$HOME/calls.log"; LOG_FILE="$HOME/log"
    export SERVE CALLS LOG_FILE
    mkdir -p "$SERVE" "$HOME/bin"
    : > "$CALLS"
    printf 'deb-bytes' > "$SERVE/deb"
    DEB_SUM=$(sha256sum "$SERVE/deb" | awk '{print $1}')
    printf '%s  openlogi-v9.9.9-linux-amd64.deb\n%s  openlogi-v9.9.9-linux-arm64.deb\n' \
        "$DEB_SUM" "$(printf '%064d' 1)" > "$SERVE/SHA256SUMS"
    cat > "$HOME/bin/curl" <<'STUB'
#!/bin/bash
out=""; url=""
while [ $# -gt 0 ]; do
    case "$1" in -o) out="$2"; shift ;; -*) ;; *) url="$1" ;; esac
    shift
done
echo "curl $url" >> "$CALLS"
case "$url" in
    */latest/download/SHA256SUMS) [ -e "$SERVE/SHA256SUMS" ] || exit 22; cp "$SERVE/SHA256SUMS" "$out" ;;
    */download/v9.9.9/openlogi-v9.9.9-linux-amd64.deb) cp "$SERVE/deb" "$out" ;;
    *) exit 22 ;;
esac
STUB
    printf '#!/bin/bash\necho "sudo $*" >> "%s"\nexit "${SUDO_RC:-0}"\n' "$CALLS" > "$HOME/bin/sudo"
    printf '#!/bin/bash\necho "systemctl $*" >> "%s"\n' "$CALLS" > "$HOME/bin/systemctl"
    printf '#!/bin/bash\necho amd64\n' > "$HOME/bin/dpkg"
    chmod +x "$HOME/bin/"*
    export PATH="$HOME/bin:$PATH"
    # openlogi looks absent until the stubbed apt-get install has been called.
    command_exists() { if [ "$1" = openlogi ]; then grep -q "apt-get install" "$CALLS"; else command -v "$1" > /dev/null 2>&1; fi; }
}

@test "install_openlogi fetches SHA256SUMS and the .deb from the GitHub release" {
    _stub_install_flow
    run install_openlogi
    [ "$status" -eq 0 ]
    grep -q 'curl https://github.com/AprilNEA/OpenLogi/releases/latest/download/SHA256SUMS' "$CALLS"
    grep -q 'curl https://github.com/AprilNEA/OpenLogi/releases/download/v9.9.9/openlogi-v9.9.9-linux-amd64.deb' "$CALLS"
    grep -q 'sudo apt-get install -y .*openlogi.deb' "$CALLS"
    refute_repo_grep 'openlogi.org' "$CALLS"
}

@test "install_openlogi refuses a .deb whose checksum does not match" {
    _stub_install_flow
    printf '%064d  openlogi-v9.9.9-linux-amd64.deb\n' 7 > "$SERVE/SHA256SUMS"
    run install_openlogi
    [ "$status" -ne 0 ]
    refute_repo_grep 'apt-get install' "$CALLS"
    refute_repo_grep 'systemctl' "$CALLS"
}

@test "install_openlogi refuses when SHA256SUMS has no linux .deb entry" {
    _stub_install_flow
    printf '%s  OpenLogi-v9.9.9-macos-arm64.dmg\n' "$DEB_SUM" > "$SERVE/SHA256SUMS"
    run install_openlogi
    [ "$status" -ne 0 ]
    refute_repo_grep 'apt-get install' "$CALLS"
}

@test "install_openlogi refuses when SHA256SUMS cannot be fetched" {
    _stub_install_flow
    rm "$SERVE/SHA256SUMS"
    run install_openlogi
    [ "$status" -ne 0 ]
    refute_repo_grep 'apt-get install' "$CALLS"
}

@test "install_openlogi does not enable the agent service when the install failed" {
    _stub_install_flow
    SUDO_RC=1 run install_openlogi
    [ "$status" -ne 0 ]
    refute_repo_grep 'systemctl' "$CALLS"
}

@test "install_openlogi points manual installs at the GitHub releases page" {
    _stub_install_flow
    PACKAGE_MANAGER="dnf" run install_openlogi
    [ "$status" -ne 0 ]
    [[ "$output" == *"https://github.com/AprilNEA/OpenLogi/releases"* ]]
    [[ "$output" != *"openlogi.org"* ]]
}
