#!/usr/bin/env bats
#
# Unit tests for configure_gsconnect (issue #766): it must INSTALL the GSConnect
# extension (not just check for it), via install_package, then enable it.
# sudo and gnome-extensions are stubs that only log argv; nothing touches the system.
#
# Run locally: bats tests/gsconnect_install.bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP="$(mktemp -d)"
    export LOG_FILE="$TMP/log" CALLS="$TMP/calls.log" PRESENT="$TMP/present"
    : > "$CALLS"; : > "$PRESENT"
    mkdir -p "$TMP/bin"
    printf '#!/bin/bash\necho "sudo $*" >> "%s"\nexit "${SUDO_RC:-0}"\n' "$CALLS" > "$TMP/bin/sudo"
    # dpkg-query succeeds only for names listed in $PRESENT (as in install_package_verify.bats).
    cat > "$TMP/bin/dpkg-query" <<'STUB'
#!/bin/bash
grep -qx "${!#}" "$PRESENT" && printf 'install ok installed' || { printf 'unknown ok not-installed'; exit 1; }
STUB
    # gnome-extensions: `list` prints $EXT_LIST, `enable` logs.
    cat > "$TMP/bin/gnome-extensions" <<'STUB'
#!/bin/bash
echo "gnome-extensions $*" >> "$CALLS"
[ "$1" = list ] && printf '%s\n' "${EXT_LIST:-}"
exit 0
STUB
    chmod +x "$TMP/bin/"*
    export PATH="$TMP/bin:$PATH"

    # shellcheck source=../distro_config/install_lib/_common.sh
    source "$REPO_ROOT/distro_config/install_lib/_common.sh"
    export PACKAGE_MANAGER="apt"
    export INSTALL_CMD="run_or_echo sudo apt-get install -y"
    # shellcheck source=../distro_config/install_lib/system_utils.sh
    source "$REPO_ROOT/distro_config/install_lib/system_utils.sh"
}

teardown() {
    rm -rf "$TMP"
}

refute_call() {
    run grep -q -- "$1" "$CALLS"
    [ "$status" -ne 0 ]
}

@test "installs the gsconnect extension and the browser connector, then enables it" {
    EXT_LIST="gsconnect@andyholmes.github.io" run configure_gsconnect
    [ "$status" -eq 0 ]
    grep -q 'apt-get install -y gnome-shell-extension-gsconnect' "$CALLS"
    grep -q 'apt-get install -y gnome-browser-connector' "$CALLS"
    grep -q 'gnome-extensions enable gsconnect@andyholmes.github.io' "$CALLS"
}

@test "no longer installs the transitional chrome-gnome-shell" {
    EXT_LIST="gsconnect@andyholmes.github.io" run configure_gsconnect
    refute_call 'chrome-gnome-shell'
}

@test "apt exiting 1 with the extension package present still enables it" {
    printf '%s\n' gnome-shell-extension-gsconnect gnome-shell-extensions gnome-browser-connector > "$PRESENT"
    SUDO_RC=1 EXT_LIST="gsconnect@andyholmes.github.io" run configure_gsconnect
    [ "$status" -eq 0 ]
    grep -q 'gnome-extensions enable gsconnect@andyholmes.github.io' "$CALLS"
}

@test "fails without enabling when the extension package cannot be installed" {
    SUDO_RC=1 run configure_gsconnect
    [ "$status" -ne 0 ]
    refute_call 'gnome-extensions enable'
}

@test "warns and fails when the extension is not visible to GNOME Shell yet" {
    EXT_LIST="" run configure_gsconnect
    [ "$status" -ne 0 ]
    [[ "$output" == *"log out"* ]]
    refute_call 'gnome-extensions enable'
}

@test "DRY_RUN=1 enables nothing and installs nothing for real" {
    DRY_RUN=1 run configure_gsconnect
    [ "$status" -eq 0 ]
    [ ! -s "$CALLS" ]
    [[ "$output" == *"[dry-run] gnome-extensions enable gsconnect@andyholmes.github.io"* ]]
}

@test "non-apt distros get a clear warning and a failure" {
    PACKAGE_MANAGER="dnf" run configure_gsconnect
    [ "$status" -ne 0 ]
    [[ "$output" == *"only automated on apt"* ]]
    [ ! -s "$CALLS" ]
}
