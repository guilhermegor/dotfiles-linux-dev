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

    # latest-linux.yml: electron-builder's per-asset base64 sha512. The stub curl
    # writes "deb\n" as the .deb, so that is what the checksum must cover.
    export YML="$TMP/latest-linux.yml"
    printf -- '- url: OpenWhispr-1.10.3-linux-amd64.deb\n  sha512: %s\n' \
        "$(printf 'deb\n' | openssl dgst -sha512 -binary | base64 -w0)" > "$YML.body"
    { echo "version: 1.10.3"; echo "files:"; sed 's/^/  /' "$YML.body"; } > "$YML"

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
    *latest-linux.yml*) cat "$YML" ;;
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
    install) [ "${APT_NOLAND:-0}" = 1 ] || touch "$INSTALLED_FLAG" ;;
    remove)  rm -f "$INSTALLED_FLAG" ;;
esac
exit "${APT_RC:-0}"
STUB

    cat > "$TMP/bin/dpkg" <<'STUB'
#!/bin/bash
case "$1" in
    --print-architecture) echo "$ARCH" ;;
esac
STUB

    # package_landed (the shared #632 check) reads dpkg-query, not dpkg -l.
    cat > "$TMP/bin/dpkg-query" <<'STUB'
#!/bin/bash
[ -e "$INSTALLED_FLAG" ] && printf 'install ok installed'
exit 0
STUB
    chmod +x "$TMP/bin/curl" "$TMP/bin/sudo" "$TMP/bin/apt-get" "$TMP/bin/dpkg" "$TMP/bin/dpkg-query"

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
    *latest-linux.yml*) cat "$YML" ;;
    *) exit 22 ;;
esac
STUB
    run install_openwhispr
    [ "$status" -eq 1 ]
    refute_call 'apt-get'
}

@test "install_openwhispr succeeds with a warning when apt exits non-zero but the package landed" {
    APT_RC=100 run install_openwhispr
    [ "$status" -eq 0 ]
    [[ "$output" == *"apt-get exited 100 but open-whispr is installed"* ]]
}

@test "install_openwhispr fails when apt exits non-zero and the package is absent" {
    APT_RC=100 APT_NOLAND=1 run install_openwhispr
    [ "$status" -eq 1 ]
    [[ "$output" == *"installation failed"* ]]
}

@test "install_openwhispr installs curl first when it is missing" {
    : > "$TMP/curl_missing"
    command_exists() {
        [ "$1" = curl ] && [ -e "$TMP/curl_missing" ] && return 1
        command -v "$1" &>/dev/null
    }
    install_package() { echo "install_package $*" >> "$CALLS"; rm -f "$TMP/curl_missing"; }
    run install_openwhispr
    [ "$status" -eq 0 ]
    grep -q '^install_package curl' "$CALLS"
}

@test "install_openwhispr fails clearly when curl cannot be installed" {
    command_exists() { [ "$1" = curl ] && return 1; command -v "$1" &>/dev/null; }
    install_package() { echo "install_package $*" >> "$CALLS"; }
    run install_openwhispr
    [ "$status" -eq 1 ]
    [[ "$output" == *"curl is required"* ]]
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

@test "install_openwhispr reports the real error when the release API call fails" {
    printf '#!/bin/bash\nexit 22\n' > "$TMP/bin/curl"
    run install_openwhispr
    [ "$status" -eq 1 ]
    [[ "$output" == *"Could not query the OpenWhispr release API (curl exit 22"* ]]
    [[ "$output" != *"No linux-amd64 .deb asset found"* ]]
}

@test "install_openwhispr refuses a .deb whose sha512 differs from latest-linux.yml" {
    sed -i 's/sha512: .*/sha512: AAAA/' "$YML"
    run install_openwhispr
    [ "$status" -eq 1 ]
    [[ "$output" == *"checksum missing or mismatched"* ]]
    refute_call 'apt-get'
}

@test "install_openwhispr removes its temp dir on a failed install" {
    mkdir "$TMP/t"
    TMPDIR="$TMP/t" APT_RC=100 APT_NOLAND=1 run install_openwhispr
    [ "$status" -eq 1 ]
    [ -z "$(ls -A "$TMP/t")" ]
}

@test "install_openwhispr tells the user the exact usermod step when not in the input group" {
    printf '#!/bin/bash\necho "input:x:104:someoneelse"\n' > "$TMP/bin/getent"; chmod +x "$TMP/bin/getent"
    SUDO_USER=tester run install_openwhispr
    [ "$status" -eq 0 ]
    [[ "$output" == *'sudo usermod -aG input $USER'* ]]
}

@test "install_openwhispr says to re-login when the user is already in the input group" {
    printf '#!/bin/bash\necho "input:x:104:tester"\n' > "$TMP/bin/getent"; chmod +x "$TMP/bin/getent"
    SUDO_USER=tester run install_openwhispr
    [ "$status" -eq 0 ]
    [[ "$output" == *"log out and in once"* ]]
}

@test "install_openwhispr checks SUDO_USER, not root, for input-group membership" {
    printf '#!/bin/bash\necho "input:x:104:desk"\n' > "$TMP/bin/getent"; chmod +x "$TMP/bin/getent"
    SUDO_USER=desk USER=root run install_openwhispr
    [ "$status" -eq 0 ]
    [[ "$output" == *"log out and in once"* ]]
}
