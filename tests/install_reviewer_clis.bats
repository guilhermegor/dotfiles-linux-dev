#!/usr/bin/env bats
#
# install_graphite / install_greptile (dotfiles-linux-dev#713): the installers only
# install and print the manual login hint; they never touch a token.
# npm, node, gt and greptile are stubbed on PATH; the network is never reached.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP="$(mktemp -d)"
    HOME="$TMP/home"
    mkdir -p "$HOME" "$TMP/bin"
    export HOME LOG_FILE="$TMP/log" TMP
    # Stub dir + symlinks to only the utilities the installers need, so no system
    # npm/node/gt/greptile can ever resolve (a real global install would hit the network).
    mkdir -p "$TMP/sys"
    local tool path
    ORIG_PATH="$PATH"
    for tool in bash sed head cat timeout mktemp rm chmod mkdir dirname env sh grep; do
        path="$(command -v "$tool")" && ln -s "$path" "$TMP/sys/$tool"
    done
    export PATH="$TMP/bin:$TMP/sys"
    # shellcheck source=../distro_config/install_lib/_common.sh
    source "$REPO_ROOT/distro_config/install_lib/_common.sh"
    # shellcheck source=../distro_config/install_coding_lib/ai_clients.sh
    source "$REPO_ROOT/distro_config/install_coding_lib/ai_clients.sh"
    # shellcheck source=../distro_config/install_coding_lib/vcs.sh
    source "$REPO_ROOT/distro_config/install_coding_lib/vcs.sh"
}

teardown() {
    PATH="$ORIG_PATH"
    rm -rf "$TMP"
}

# stub_npm <binary-to-create>: `npm install -g <pkg>` records its args and drops the binary.
stub_npm() {
    cat > "$TMP/bin/npm" <<STUB
#!/bin/bash
echo "\$*" >> "$TMP/npm_args"
printf '#!/bin/bash\necho "$1 9.9.9"\n' > "$TMP/bin/$1"
chmod +x "$TMP/bin/$1"
STUB
    chmod +x "$TMP/bin/npm"
}

stub_node() {
    printf '#!/bin/bash\necho "v%s.1.0"\n' "$1" > "$TMP/bin/node"
    chmod +x "$TMP/bin/node"
}

@test "registry names both new installers and validate_registry is green" {
    [[ " ${INSTALL_REGISTRY[*]} " == *"install_graphite:"* ]]
    [[ " ${INSTALL_REGISTRY[*]} " == *"install_greptile:"* ]]
    run validate_registry
    [ "$status" -eq 0 ]
}

@test "install_coderabbit stays registered (vcs.sh)" {
    source "$REPO_ROOT/distro_config/install_coding_lib/vcs.sh"
    run validate_registry
    [ "$status" -eq 0 ]
    [[ " ${INSTALL_REGISTRY[*]} " == *"install_coderabbit:"* ]]
}

@test "install_graphite installs the stable channel and prints the login hint" {
    stub_npm gt
    run install_graphite
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP/npm_args")" = "install -g @withgraphite/graphite-cli@stable" ]
    [[ "$output" == *"gt version: gt 9.9.9"* ]]
    [[ "$output" == *"gt auth --token <token"* ]]
}

@test "install_graphite is a no-op when gt is already present" {
    stub_npm gt
    printf '#!/bin/bash\necho "gt 1.0.0"\n' > "$TMP/bin/gt"
    chmod +x "$TMP/bin/gt"
    run install_graphite
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed (gt 1.0.0)"* ]]
    [ ! -e "$TMP/npm_args" ]
}

@test "install_graphite fails without npm" {
    run install_graphite
    [ "$status" -eq 1 ]
    [[ "$output" == *"npm is not available"* ]]
}

@test "install_greptile installs greptile@latest and prints the login hint" {
    stub_npm greptile
    stub_node 25
    run install_greptile
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP/npm_args")" = "install -g greptile@latest" ]
    [[ "$output" == *"greptile version: greptile 9.9.9"* ]]
    [[ "$output" == *"greptile login"* ]]
}

@test "install_greptile refuses Node older than 22 without calling npm install" {
    stub_npm greptile
    stub_node 20
    run install_greptile
    [ "$status" -eq 1 ]
    [[ "$output" == *"needs Node.js >= 22"* ]]
    [ ! -e "$TMP/npm_args" ]
}

@test "install_greptile is a no-op when greptile is already present" {
    stub_npm greptile
    printf '#!/bin/bash\necho "greptile 2.0.0"\n' > "$TMP/bin/greptile"
    chmod +x "$TMP/bin/greptile"
    run install_greptile
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed (greptile 2.0.0)"* ]]
    [ ! -e "$TMP/npm_args" ]
}

@test "neither installer ever invokes an auth command" {
    stub_npm gt
    stub_node 25
    run install_graphite
    [ "$status" -eq 0 ]
    [[ ! "$(cat "$TMP/npm_args")" == *auth* ]]
}

@test "already-installed paths still print the manual login hint" {
    printf '#!/bin/bash\necho "gt 1.0.0"\n' > "$TMP/bin/gt"
    printf '#!/bin/bash\necho "greptile 2.0.0"\n' > "$TMP/bin/greptile"
    chmod +x "$TMP/bin/gt" "$TMP/bin/greptile"
    run install_graphite
    [[ "$output" == *"gt auth --token <token"* ]]
    run install_greptile
    [[ "$output" == *"greptile login"* ]]
}

@test "DRY_RUN previews both installers as success without installing" {
    stub_npm gt
    stub_node 25
    DRY_RUN=1 run install_graphite
    [ "$status" -eq 0 ]
    DRY_RUN=1 run install_greptile
    [ "$status" -eq 0 ]
    [ ! -e "$TMP/bin/gt" ]
    [ ! -e "$TMP/bin/greptile" ]
}

@test "install_graphite lives in vcs.sh (GitHub workflow tool), not ai_clients.sh" {
    run grep -c '^install_graphite()' "$REPO_ROOT/distro_config/install_coding_lib/vcs.sh"
    [ "$output" = "1" ]
    run grep -c '^install_graphite()' "$REPO_ROOT/distro_config/install_coding_lib/ai_clients.sh"
    [ "$output" = "0" ]
}

@test "no system npm is reachable from the test PATH" {
    run command -v npm
    [ "$status" -ne 0 ]
}
