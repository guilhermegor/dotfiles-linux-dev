#!/usr/bin/env bats
#
# Unit tests for install_free_download_manager (issue #679).
# wget/curl/apt-get/dpkg/dpkg-query are stubbed on PATH: no network, no root.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP="$(mktemp -d)"
    export LOG_FILE="$TMP/log"
    export CALLS="$TMP/calls.log"
    : > "$CALLS"
    mkdir -p "$TMP/bin"
    export PATH="$TMP/bin:$PATH"

    _stub wget 'echo "wget $*" >> "$CALLS"; [ "$1" = -O ] && echo deb > "$2"; exit 0'
    _stub curl 'echo "curl $*" >> "$CALLS"'
    _stub sudo '"$@"'
    _stub apt-get 'echo "apt-get $*" >> "$CALLS"'
    _stub dpkg 'echo amd64'
    _stub dpkg-query 'exit 1'

    # shellcheck source=../distro_config/install_lib/_common.sh
    source "$REPO_ROOT/distro_config/install_lib/_common.sh"
    PACKAGE_MANAGER="apt"
    # shellcheck source=../distro_config/install_lib/sharing.sh
    source "$REPO_ROOT/distro_config/install_lib/sharing.sh"
}

teardown() {
    rm -rf "$TMP"
}

_stub() {
    printf '#!/bin/bash\n%s\n' "$2" > "$TMP/bin/$1"
    chmod +x "$TMP/bin/$1"
}

@test "installs the vendor .deb when absent" {
    run install_free_download_manager
    [ "$status" -eq 0 ]
    grep -q "wget -O .*freedownloadmanager.deb https://files2.freedownloadmanager.org/" "$CALLS"
    grep -q "apt-get install -y .*freedownloadmanager.deb" "$CALLS"
}

@test "is a no-op when already installed" {
    _stub dpkg-query 'echo "install ok installed"'
    run install_free_download_manager
    [ "$status" -eq 0 ]
    [ ! -s "$CALLS" ]
}

@test "fails loudly on a non-apt distro" {
    PACKAGE_MANAGER="dnf"
    run install_free_download_manager
    [ "$status" -eq 1 ]
    [[ "$output" == *"unsupported distro"* ]]
    [ ! -s "$CALLS" ]
}

@test "fails loudly on an unsupported architecture" {
    _stub dpkg 'echo arm64'
    run install_free_download_manager
    [ "$status" -eq 1 ]
    [ ! -s "$CALLS" ]
}

@test "fails when apt-get install fails" {
    _stub apt-get 'exit 1'
    run install_free_download_manager
    [ "$status" -eq 1 ]
}

@test "registry entry is in Sharing with the verified desktop file and validates" {
    [[ " ${INSTALL_REGISTRY[*]} " == *"install_free_download_manager:Free Download Manager:Sharing:freedownloadmanager.desktop"* ]]
    run validate_registry
    [ "$status" -eq 0 ]
}
