#!/usr/bin/env bats
#
# Unit tests for install_f3_qt (issue #856).
# Every external tool is stubbed on PATH: no network, no root, no build.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP="$(mktemp -d)"
    export LOG_FILE="$TMP/log"
    export CALLS="$TMP/calls.log"
    : > "$CALLS"
    mkdir -p "$TMP/bin"
    export PATH="$TMP/bin:$PATH"

    for tool in sudo git qmake make apt-get yay; do
        _stub "$tool" 'echo "$(basename "$0") $*" >> "$CALLS"'
    done

    # shellcheck source=../distro_config/install_lib/_common.sh
    source "$REPO_ROOT/distro_config/install_lib/_common.sh"
    # shellcheck source=../distro_config/install_lib/vm.sh
    source "$REPO_ROOT/distro_config/install_lib/vm.sh"
    PACKAGE_MANAGER="apt"
}

teardown() {
    rm -rf "$TMP"
}

_stub() {
    printf '#!/bin/bash\n%s\n' "$2" > "$TMP/bin/$1"
    chmod +x "$TMP/bin/$1"
}

@test "is a no-op when f3-qt is already installed" {
    _stub f3-qt 'exit 0'
    run install_f3_qt
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]]
    [ ! -s "$CALLS" ]
}

@test "a fetched commit that is not the pinned SHA aborts before build or install" {
    run_or_echo() { "$@"; }
    _stub git 'echo "git $*" >> "$CALLS"; [ "$3" = rev-parse ] && echo deadbeef; exit 0'
    run _f3_qt_build_from_source
    [ "$status" -eq 1 ]
    [[ "$output" == *"commit mismatch"* ]]
    run grep -E "^(qmake|make|sudo)" "$CALLS"
    [ "$status" -eq 1 ]
}

@test "the pinned SHA is a 40-char hex commit" {
    [[ "$F3_QT_COMMIT" =~ ^[0-9a-f]{40}$ ]]
}

@test "registry maps f3-qt to the Infra folder" {
    local entry found=1
    for entry in "${INSTALL_REGISTRY[@]}"; do
        [ "$entry" = "install_f3_qt:F3-QT (Flash Fraud Tester):Infra:f3-qt.desktop" ] && found=0
    done
    [ "$found" -eq 0 ]
}
