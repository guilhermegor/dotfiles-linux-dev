#!/usr/bin/env bats
#
# Unit tests for install_flutter / _install_fvm (issue #578: install Flutter
# manually per https://docs.flutter.dev/install/manual, plus FVM via brew).
#
# Strategy: throwaway $HOME, curl/sha256sum/brew/tar stubbed on PATH, no
# network, no real Flutter SDK ever downloaded or extracted. The curl stub
# serves a canned Flutter release manifest (shape verified live 2026-09-28)
# and a dummy "archive" file; sha256sum is stubbed per-test to control
# match/mismatch; tar is stubbed to fabricate the extracted flutter/dart
# binaries instead of really extracting anything.
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

    # Fixture manifest mirrors the live shape of
    # https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json:
    # pretty-printed JSON, base_url + current_release.stable (a hash) +
    # releases[] entries keyed by hash/channel/version/archive/sha256.
    FIXTURE_MANIFEST="$TMP/releases_linux.json"
    FIXTURE_SHA256="deadbeef00112233445566778899aabbccddeeff00112233445566778899aabb"
    cat > "$FIXTURE_MANIFEST" <<JSON
{
  "base_url": "https://storage.googleapis.com/flutter_infra_release/releases",
  "current_release": {
    "beta": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "dev": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "stable": "6a19cca56475dbfba1478ee68d7bd0c2ef891da1"
  },
  "releases": [
    {
      "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "channel": "beta",
      "version": "3.49.0-0.1.pre",
      "dart_sdk_version": "3.14.0",
      "dart_sdk_arch": "x64",
      "release_date": "2026-09-21T23:07:42.299536Z",
      "archive": "beta/linux/flutter_linux_3.49.0-0.1.pre-beta.tar.xz",
      "sha256": "0000000000000000000000000000000000000000000000000000000000000000"
    },
    {
      "hash": "6a19cca56475dbfba1478ee68d7bd0c2ef891da1",
      "channel": "stable",
      "version": "3.47.5",
      "dart_sdk_version": "3.13.4",
      "dart_sdk_arch": "x64",
      "release_date": "2026-09-18T20:36:35.413968Z",
      "archive": "stable/linux/flutter_linux_3.47.5-stable.tar.xz",
      "sha256": "$FIXTURE_SHA256"
    }
  ]
}
JSON
    export FIXTURE_MANIFEST FIXTURE_SHA256

    # shellcheck source=../distro_config/install_lib/_common.sh
    source "$REPO_ROOT/distro_config/install_lib/_common.sh"
    PACKAGE_MANAGER="apt"

    # shellcheck source=../distro_config/install_coding_lib/languages.sh
    source "$REPO_ROOT/distro_config/install_coding_lib/languages.sh"
}

teardown() {
    rm -rf "$TMP"
}

# refute_output_contains PATTERN — see tests/install_rclone.bats: a bare
# `! grep` inside @test is not a real assertion under set -e (#380).
refute_output_contains() {
    [[ "$output" != *"$1"* ]]
}

# This dev machine has real Homebrew + a real fvm already installed
# (/home/linuxbrew/.linuxbrew/bin/), so `command_exists` would find them
# regardless of PATH stub ordering. Hide them explicitly — same pattern as
# tests/install_rclone.bats' _hide_rclone — delegating every other name to
# the real check.
#
# fvm is scoped to "exists only inside $TMP/bin", not permanently hidden:
# the brew stub below drops a working fvm into $TMP/bin on a simulated
# install, and the post-install verification in _install_fvm must see it.
_hide_brew() {
    command_exists() { [ "$1" = brew ] && return 1; command -v "$1" &>/dev/null; }
}

_hide_fvm() {
    command_exists() {
        if [ "$1" = fvm ]; then [ -x "$TMP/bin/fvm" ]; return $?; fi
        command -v "$1" &>/dev/null
    }
}

_hide_fvm_and_brew() {
    command_exists() {
        if [ "$1" = fvm ]; then [ -x "$TMP/bin/fvm" ]; return $?; fi
        [ "$1" = brew ] && return 1
        command -v "$1" &>/dev/null
    }
}

_write_curl_stub() {
    cat > "$TMP/bin/curl" <<'STUB'
#!/bin/bash
url=""
dest=""
prev=""
for arg in "$@"; do
    if [ "$prev" = "-o" ]; then dest="$arg"; fi
    case "$arg" in http*) url="$arg" ;; esac
    prev="$arg"
done

case "$url" in
    *releases_linux.json)
        cp "$FIXTURE_MANIFEST" "$dest"
        ;;
    *flutter_linux_*.tar.xz)
        echo "fake flutter sdk archive" > "$dest"
        ;;
    *)
        exit 1
        ;;
esac
STUB
    chmod +x "$TMP/bin/curl"
}

# Fake sha256sum that always reports the fixture's expected checksum for the
# downloaded archive — the "checksum matches" path.
_write_matching_sha256sum_stub() {
    cat > "$TMP/bin/sha256sum" <<STUB
#!/bin/bash
echo "$FIXTURE_SHA256  \$1"
STUB
    chmod +x "$TMP/bin/sha256sum"
}

# Fake sha256sum that always disagrees with the manifest — the "checksum
# mismatch" path.
_write_mismatching_sha256sum_stub() {
    cat > "$TMP/bin/sha256sum" <<'STUB'
#!/bin/bash
echo "0000000000000000000000000000000000000000000000000000000000000000  $1"
STUB
    chmod +x "$TMP/bin/sha256sum"
}

# Fabricates the extracted SDK tree instead of really extracting the (fake)
# archive — never invoked in the checksum-mismatch test.
_write_tar_stub() {
    TAR_LOG="$TMP/tar_invocations.log"
    export TAR_LOG
    cat > "$TMP/bin/tar" <<STUB
#!/bin/bash
echo "\$*" >> "$TAR_LOG"
dest=""
prev=""
for arg in "\$@"; do
    if [ "\$prev" = "-C" ]; then dest="\$arg"; fi
    prev="\$arg"
done
mkdir -p "\$dest/flutter/bin"
cat > "\$dest/flutter/bin/flutter" <<'BIN'
#!/bin/bash
case "\$1" in
    --version) echo "Flutter 3.47.5 stub" ;;
    doctor) echo "Doctor stub" ;;
    *) exit 0 ;;
esac
BIN
chmod +x "\$dest/flutter/bin/flutter"
cat > "\$dest/flutter/bin/dart" <<'BIN'
#!/bin/bash
echo "Dart SDK stub"
BIN
chmod +x "\$dest/flutter/bin/dart"
STUB
    chmod +x "$TMP/bin/tar"
}

# Pre-seeds ~/develop/flutter with fake flutter/dart binaries, as if a prior
# run already extracted the SDK — used by tests that only exercise the parts
# of install_flutter after the SDK-download step.
_seed_installed_flutter_sdk() {
    mkdir -p "$HOME/develop/flutter/bin"
    cat > "$HOME/develop/flutter/bin/flutter" <<'BIN'
#!/bin/bash
case "$1" in
    --version) echo "Flutter 3.47.5 stub" ;;
    doctor) echo "Doctor stub" ;;
    *) exit 0 ;;
esac
BIN
    chmod +x "$HOME/develop/flutter/bin/flutter"
    cat > "$HOME/develop/flutter/bin/dart" <<'BIN'
#!/bin/bash
echo "Dart SDK stub"
BIN
    chmod +x "$HOME/develop/flutter/bin/dart"
}

_write_fvm_stub() {
    cat > "$TMP/bin/fvm" <<'STUB'
#!/bin/bash
echo "1.0.0"
STUB
    chmod +x "$TMP/bin/fvm"
}

_write_brew_stub() {
    BREW_LOG="$TMP/brew_invocations.log"
    export BREW_LOG
    cat > "$TMP/bin/brew" <<STUB
#!/bin/bash
echo "\$*" >> "$BREW_LOG"
if [ "\$1" = "install" ] && [ "\$2" = "fvm" ]; then
    ln -sf "$TMP/bin/fvm_after_install" "$TMP/bin/fvm"
fi
STUB
    chmod +x "$TMP/bin/brew"
    cat > "$TMP/bin/fvm_after_install" <<'STUB'
#!/bin/bash
echo "1.0.0"
STUB
    chmod +x "$TMP/bin/fvm_after_install"
}

# --- checksum mismatch -> loud failure, nothing extracted --------------------

@test "install_flutter fails loudly on a Flutter SDK checksum mismatch" {
    _write_curl_stub
    _write_mismatching_sha256sum_stub
    _write_tar_stub

    run install_flutter

    [ "$status" -eq 1 ]
    [[ "$output" == *"Checksum mismatch"* ]]
    [ ! -d "$HOME/develop/flutter" ]
    [ ! -f "$TAR_LOG" ]
}

# --- idempotent PATH append --------------------------------------------------

@test "install_flutter appends the Flutter bin dir to ~/.bashrc only once" {
    _seed_installed_flutter_sdk
    _write_fvm_stub

    run install_flutter
    [ "$status" -eq 0 ]
    local first_count
    first_count=$(grep -cF "$HOME/develop/flutter/bin" "$HOME/.bashrc")
    [ "$first_count" -eq 1 ]

    run install_flutter
    [ "$status" -eq 0 ]
    local second_count
    second_count=$(grep -cF "$HOME/develop/flutter/bin" "$HOME/.bashrc")
    [ "$second_count" -eq 1 ]
}

@test "install_flutter skips the PATH append when the line already exists" {
    _seed_installed_flutter_sdk
    _write_fvm_stub
    {
        echo ""
        echo "# Flutter SDK"
        echo "export PATH=\"\$PATH:$HOME/develop/flutter/bin\""
    } >> "$HOME/.bashrc"

    run install_flutter

    [ "$status" -eq 0 ]
    [[ "$output" == *"already contains"* ]]
    [ "$(grep -cF "$HOME/develop/flutter/bin" "$HOME/.bashrc")" -eq 1 ]
}

# --- missing brew -> loud failure --------------------------------------------

@test "install_flutter fails loudly when fvm is missing and brew is unavailable" {
    _seed_installed_flutter_sdk
    _hide_fvm_and_brew

    run install_flutter

    [ "$status" -eq 1 ]
    [[ "$output" == *"Homebrew is required"* ]]
}

@test "_install_fvm never invokes brew when fvm is already installed" {
    _write_fvm_stub
    _write_brew_stub

    run _install_fvm

    [ "$status" -eq 0 ]
    [ ! -f "$BREW_LOG" ]
}

@test "_install_fvm installs via brew (no separate tap) when fvm is missing" {
    _hide_fvm
    _write_brew_stub

    run _install_fvm

    [ "$status" -eq 0 ]
    grep -qF "install fvm" "$BREW_LOG"
    refute_output_contains "tap"
}

# --- registry entry shape (CLI tool: empty gnome_folder/desktop_file) -------

@test "INSTALL_REGISTRY has an install_flutter entry with empty folder and desktop fields" {
    local entry fn label folder desktop found=0
    for entry in "${INSTALL_REGISTRY[@]}"; do
        if [[ "$entry" == install_flutter:* ]]; then
            found=1
            IFS=':' read -r fn label folder desktop <<< "$entry"
            [ -z "$folder" ]
            [ -z "$desktop" ]
        fi
    done
    [ "$found" -eq 1 ]
}

@test "validate_registry passes with install_flutter registered" {
    run validate_registry
    [ "$status" -eq 0 ]
}

# --- manifest resolution (pure parsing, no network) --------------------------

@test "_flutter_resolve_stable_release resolves the stable archive URL, sha256, and version" {
    run _flutter_resolve_stable_release "$FIXTURE_MANIFEST"

    [ "$status" -eq 0 ]
    [[ "$output" == *"stable/linux/flutter_linux_3.47.5-stable.tar.xz"* ]]
    [[ "$output" == *"$FIXTURE_SHA256"* ]]
    [[ "$output" == *"3.47.5"* ]]
    refute_output_contains "3.49.0-0.1.pre"
}
