#!/usr/bin/env bats
#
# Unit tests for install_openwhispr / uninstall_openwhispr (issue #792).
#
# Strategy: curl, sudo, apt-get and dpkg are stubbed on PATH. The GitHub release
# API answers from a fixture that lists every asset upstream really ships, so
# "right asset chosen" is a real selection among rpm/AppImage/tar.gz/deb. No
# network, no root, nothing installed on the machine.
#
# Run locally: bats tests/

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP="$(mktemp -d)"
    export LOG_FILE="$TMP/log"
    export CALLS="$TMP/calls.log"
    export INSTALLED_FLAG="$TMP/installed"
    export ARCH=amd64
    mkdir -p "$TMP/bin"
    : > "$CALLS"
    export PATH="$TMP/bin:$PATH"

    local base="https://github.com/HeroTools/open-whispr/releases/download/v1.10.3"
    cat > "$TMP/release.json" <<JSON
{
  "tag_name": "v1.10.3",
  "assets": [
    {
      "name": "OpenWhispr-1.10.3-linux-x86_64.AppImage",
      "browser_download_url": "$base/OpenWhispr-1.10.3-linux-x86_64.AppImage"
    },
    {
      "name": "OpenWhispr-1.10.3-linux-amd64.deb",
      "browser_download_url": "$base/OpenWhispr-1.10.3-linux-amd64.deb"
    },
    {
      "name": "OpenWhispr-1.10.3-linux-x86_64.rpm",
      "browser_download_url": "$base/OpenWhispr-1.10.3-linux-x86_64.rpm"
    },
    {
      "name": "OpenWhispr-1.10.3-linux-x64.tar.gz",
      "browser_download_url": "$base/OpenWhispr-1.10.3-linux-x64.tar.gz"
    }
  ]
}
JSON
    export RELEASE_JSON="$TMP/release.json"

    # curl: API URL -> fixture; anything with -o -> write a fake file there.
    cat > "$TMP/bin/curl" <<'STUB'
#!/bin/bash
echo "curl $*" >> "$CALLS"
out=""
prev=""
for a in "$@"; do
    [ "$prev" = "-o" ] && out="$a"
    prev="$a"
done
if [ -n "$out" ]; then echo deb > "$out"; exit 0; fi
case "$*" in
    *api.github.com*) cat "$RELEASE_JSON" ;;
esac
STUB

    # sudo: drop `env VAR=...` and run the rest, so apt-get lands on the stub.
    cat > "$TMP/bin/sudo" <<'STUB'
#!/bin/bash
[ "$1" = env ] && shift && shift
exec "$@"
STUB

    cat > "$TMP/bin/apt-get" <<'STUB'
#!/bin/bash
echo "apt-get $*" >> "$CALLS"
case "$1" in
    install) touch "$INSTALLED_FLAG" ;;
    remove)  rm -f "$INSTALLED_FLAG" ;;
esac
STUB

    cat > "$TMP/bin/dpkg" <<'STUB'
#!/bin/bash
case "$1" in
    --print-architecture) echo "$ARCH" ;;
    -l) [ -e "$INSTALLED_FLAG" ] && echo "ii  open-whispr  1.10.3  amd64  dictation"; exit 0 ;;
esac
STUB
    chmod +x "$TMP/bin/curl" "$TMP/bin/sudo" "$TMP/bin/apt-get" "$TMP/bin/dpkg"

    # shellcheck source=../distro_config/install_lib/_common.sh
    source "$REPO_ROOT/distro_config/install_lib/_common.sh"
    PACKAGE_MANAGER="apt"
    # shellcheck source=../distro_config/install_lib/media.sh
    source "$REPO_ROOT/distro_config/install_lib/media.sh"
}

teardown() {
    rm -rf "$TMP"
}

# NOT `! grep -q …`: a `!`-inverted command is exempt from set -e (issue #380).
refute_call() {
    run grep -q -- "$1" "$CALLS"
    [ "$status" -ne 0 ]
}

@test "install_openwhispr downloads the linux-amd64 .deb, not the AppImage/rpm/tar.gz" {
    run install_openwhispr
    [ "$status" -eq 0 ]
    grep -q -- '-o .*open-whispr.deb .*OpenWhispr-1.10.3-linux-amd64.deb' "$CALLS"
    refute_call 'AppImage'
    refute_call '\.rpm'
    refute_call 'tar\.gz'
}

@test "install_openwhispr hands the downloaded .deb to apt-get install" {
    run install_openwhispr
    [ "$status" -eq 0 ]
    grep -qE 'apt-get install -y .*/open-whispr\.deb' "$CALLS"
    [ -e "$INSTALLED_FLAG" ]
}

@test "install_openwhispr under DRY_RUN=1 downloads nothing and installs nothing" {
    DRY_RUN=1 run install_openwhispr
    [ "$status" -eq 0 ]
    [[ "$output" == *"[dry-run] sudo env DEBIAN_FRONTEND=noninteractive apt-get install"* ]]
    refute_call 'apt-get'
    refute_call '-o '
    [ ! -e "$INSTALLED_FLAG" ]
}

@test "install_openwhispr is a no-op when open-whispr is already installed" {
    touch "$INSTALLED_FLAG"
    run install_openwhispr
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]]
    [ ! -s "$CALLS" ]
}

@test "install_openwhispr fails when the release has no linux-amd64 .deb" {
    echo '{"assets": []}' > "$RELEASE_JSON"
    run install_openwhispr
    [ "$status" -eq 1 ]
    refute_call 'apt-get'
}

@test "install_openwhispr refuses a non-amd64 machine before touching the network" {
    ARCH=arm64
    run install_openwhispr
    [ "$status" -eq 1 ]
    [ ! -s "$CALLS" ]
}

@test "install_openwhispr refuses a non-apt distro before touching the network" {
    export PACKAGE_MANAGER="dnf"
    run install_openwhispr
    [ "$status" -eq 1 ]
    [ ! -s "$CALLS" ]
}

@test "install_openwhispr fails when the .deb download fails" {
    cat > "$TMP/bin/curl" <<'STUB'
#!/bin/bash
case "$*" in
    *api.github.com*) cat "$RELEASE_JSON" ;;
    *) exit 22 ;;
esac
STUB
    run install_openwhispr
    [ "$status" -eq 1 ]
    refute_call 'apt-get'
}

@test "uninstall_openwhispr removes the package when installed" {
    touch "$INSTALLED_FLAG"
    run uninstall_openwhispr
    [ "$status" -eq 0 ]
    grep -q 'apt-get remove -y open-whispr' "$CALLS"
    [ ! -e "$INSTALLED_FLAG" ]
}

@test "uninstall_openwhispr is a no-op when not installed" {
    run uninstall_openwhispr
    [ "$status" -eq 0 ]
    [ ! -s "$CALLS" ]
}

@test "uninstall_openwhispr under DRY_RUN=1 removes nothing" {
    touch "$INSTALLED_FLAG"
    DRY_RUN=1 run uninstall_openwhispr
    [ "$status" -eq 0 ]
    refute_call 'apt-get'
    [ -e "$INSTALLED_FLAG" ]
}

@test "registry lists OpenWhispr in the Media folder with the .desktop id the .deb ships" {
    local entry found=""
    for entry in "${INSTALL_REGISTRY[@]}"; do
        [[ "$entry" == install_openwhispr:* ]] && found="$entry"
    done
    [ "$found" = "install_openwhispr:OpenWhispr (Voice Dictation):Media:open-whispr.desktop" ]
}
