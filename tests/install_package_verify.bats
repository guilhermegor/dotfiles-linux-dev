#!/usr/bin/env bats
#
# install_package / install_packages_verified (distro_config/install_lib/_common.sh): a non-zero
# $INSTALL_CMD exit is success when the package database says every requested package landed
# (#632). The install command and the dpkg-query / rpm / pacman queries are all stubbed.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP="$(mktemp -d)"
    export LOG_FILE="$TMP/log" PRESENT="$TMP/present"
    : > "$PRESENT"
    mkdir -p "$TMP/bin"
    # Each query stub succeeds only for names listed in $PRESENT.
    cat > "$TMP/bin/dpkg-query" <<'STUB'
#!/bin/bash
pkg="${!#}"
grep -qx "$pkg" "$PRESENT" && printf 'install ok installed' || { printf 'unknown ok not-installed'; exit 1; }
STUB
    cat > "$TMP/bin/rpm" <<'STUB'
#!/bin/bash
grep -qx "${!#}" "$PRESENT"
STUB
    cat > "$TMP/bin/pacman" <<'STUB'
#!/bin/bash
grep -qx "${!#}" "$PRESENT"
STUB
    # Install stub: always exits 1, as apt does with an unrelated broken package.
    printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/failing_install"
    printf '#!/bin/bash\nexit 0\n' > "$TMP/bin/ok_install"
    chmod +x "$TMP/bin/"*
    export PATH="$TMP/bin:$PATH"
    source "$REPO_ROOT/distro_config/install_lib/_common.sh"
}

teardown() {
    rm -rf "$TMP"
}

@test "apt: failing install with the package present is success plus a warning" {
    PACKAGE_MANAGER=apt INSTALL_CMD=failing_install
    echo foo > "$PRESENT"
    run install_package foo
    [ "$status" -eq 0 ]
    [[ "$output" == *"all requested packages are installed"* ]]
}

@test "apt: failing install with the package missing still fails" {
    PACKAGE_MANAGER=apt INSTALL_CMD=failing_install
    run install_package foo
    [ "$status" -eq 1 ]
}

@test "multi-package: one missing package keeps the failure" {
    PACKAGE_MANAGER=apt INSTALL_CMD=failing_install
    echo a > "$PRESENT"
    run install_packages_verified a b
    [ "$status" -eq 1 ]
}

@test "multi-package: all present is success" {
    PACKAGE_MANAGER=apt INSTALL_CMD=failing_install
    printf 'a\nb\n' > "$PRESENT"
    run install_packages_verified a b
    [ "$status" -eq 0 ]
}

@test "dnf: failing install is verified through rpm -q" {
    PACKAGE_MANAGER=dnf INSTALL_CMD=failing_install
    echo foo-rpm > "$PRESENT"
    run install_package foo foo-deb foo-rpm
    [ "$status" -eq 0 ]
}

@test "pacman: failing install with the package missing fails" {
    PACKAGE_MANAGER=pacman INSTALL_CMD=failing_install
    run install_package foo foo-deb foo-rpm foo-arch
    [ "$status" -eq 1 ]
}

@test "pacman: failing install is verified through pacman -Q" {
    PACKAGE_MANAGER=pacman INSTALL_CMD=failing_install
    echo foo-arch > "$PRESENT"
    run install_package foo foo-deb foo-rpm foo-arch
    [ "$status" -eq 0 ]
}

@test "a succeeding install never consults the package database" {
    PACKAGE_MANAGER=apt INSTALL_CMD=ok_install
    run install_package foo
    [ "$status" -eq 0 ]
    [[ "$output" != *"all requested packages"* ]]
}
