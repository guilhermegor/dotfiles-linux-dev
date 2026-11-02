#!/usr/bin/env bats
#
# install_snapcraft (dotfiles-linux-dev#855): installs via `snap install snapcraft --classic`
# and prints the manual login hint; never logs in. snap, sudo and snapcraft are stubbed on
# PATH; the network is never reached.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP="$(mktemp -d)"
    HOME="$TMP/home"
    mkdir -p "$HOME" "$TMP/bin" "$TMP/sys"
    export HOME LOG_FILE="$TMP/log" TMP
    local tool path
    ORIG_PATH="$PATH"
    for tool in bash sed head cat timeout mktemp rm chmod mkdir dirname env sh grep; do
        path="$(command -v "$tool")" && ln -s "$path" "$TMP/sys/$tool"
    done
    export PATH="$TMP/bin:$TMP/sys"
    # shellcheck source=../distro_config/install_lib/_common.sh
    source "$REPO_ROOT/distro_config/install_lib/_common.sh"
    # shellcheck source=../distro_config/install_coding_lib/vcs.sh
    source "$REPO_ROOT/distro_config/install_coding_lib/vcs.sh"
}

teardown() {
    PATH="$ORIG_PATH"
    rm -rf "$TMP"
}

# stub_snap: `snap install snapcraft --classic` records its args and drops the binary.
stub_snap() {
    cat > "$TMP/bin/snap" <<STUB
#!/bin/bash
echo "\$*" >> "$TMP/snap_args"
printf '#!/bin/bash\necho "snapcraft 8.0.0"\n' > "$TMP/bin/snapcraft"
chmod +x "$TMP/bin/snapcraft"
STUB
    chmod +x "$TMP/bin/snap"
    printf '#!/bin/bash\nexec "$@"\n' > "$TMP/bin/sudo"
    chmod +x "$TMP/bin/sudo"
}

@test "registry names install_snapcraft and validate_registry is green" {
    [[ " ${INSTALL_REGISTRY[*]} " == *"install_snapcraft:"* ]]
    run validate_registry
    [ "$status" -eq 0 ]
}

@test "install_snapcraft issues snap install --classic and prints the hints" {
    stub_snap
    run install_snapcraft
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP/snap_args")" = "install snapcraft --classic" ]
    [[ "$output" == *"snapcraft login"* ]]
    [[ "$output" == *"export-login --snaps=<name> --acls package_access,package_push,package_update,package_release"* ]]
}

@test "install_snapcraft is a no-op when snapcraft is already present" {
    stub_snap
    printf '#!/bin/bash\necho "snapcraft 7.0.0"\n' > "$TMP/bin/snapcraft"
    chmod +x "$TMP/bin/snapcraft"
    run install_snapcraft
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed (snapcraft 7.0.0)"* ]]
    [ ! -e "$TMP/snap_args" ]
}

@test "DRY_RUN prints the command without installing" {
    stub_snap
    DRY_RUN=1 run install_snapcraft
    [ "$status" -eq 0 ]
    [ ! -e "$TMP/snap_args" ]
    [ ! -e "$TMP/bin/snapcraft" ]
}

@test "install_snapcraft fails clearly when snap is missing" {
    run install_snapcraft
    [ "$status" -eq 1 ]
    [[ "$output" == *"snap is not available"* ]]
}
