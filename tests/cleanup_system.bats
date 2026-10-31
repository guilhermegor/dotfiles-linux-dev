#!/usr/bin/env bats
#
# Regression for #767: cleanup_system printed "System cleaned up" even when
# `apt full-upgrade` / `apt autoremove` exited non-zero (dpkg could not
# configure linux-modules-* because linux-headers-* was missing).
#
# install_programs.sh runs main() on source, so the functions under test are
# extracted by name and sourced alone; apt/dpkg/sudo are shell-function stubs.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    LOG_FILE="$BATS_TEST_TMPDIR/log"
    PACKAGE_MANAGER="apt"
    print_status() { echo "[$1] $2"; }
    run_or_echo() { "$@"; }
    # never forward the lock-file rm to the host; the apt calls go to the stubs
    sudo() { [ "$1" = rm ] && return 0; "$@"; }
    systemctl() { return 0; }

    local fn
    for fn in cleanup_system _hint_unconfigured_kernel_modules; do
        eval "$(awk -v f="$fn" '$0 == f"() {" {p=1} p {print} p && $0 == "}" {exit}' \
            "$REPO_ROOT/distro_config/install_programs.sh")"
    done
}

@test "cleanup_system fails and hints at missing headers when apt is broken" {
    apt() { [ "$1" = list ] && return 0; return 100; }
    dpkg() { printf 'ii  bash 1\niF  linux-modules-nvidia-580-7.0.0-38-generic 1\n'; }
    dpkg-query() { return 1; }

    run cleanup_system
    [ "$status" -ne 0 ]
    [[ "$output" != *"System cleaned up"* ]]
    [[ "$output" == *"sudo apt install linux-headers-7.0.0-38-generic && sudo dpkg --configure -a"* ]]
}

# #847: a held kernel metapackage ("hi" = hold + fully installed) keeps the
# headers behind while the unheld nvidia modules move on; the fix must unhold it.
@test "cleanup hint unholds a held kernel metapackage and does not call it unconfigured" {
    apt() { [ "$1" = list ] && return 0; return 100; }
    dpkg() { printf 'hi  linux-generic-hwe-24.04 1\niF  linux-modules-nvidia-580-7.0.0-42-generic 1\n'; }
    dpkg-query() { return 1; }

    run cleanup_system
    [ "$status" -ne 0 ]
    [[ "$output" != *"not fully configured: linux-generic-hwe-24.04"* ]]
    [[ "$output" == *"held: linux-generic-hwe-24.04"* ]]
    [[ "$output" == *"Fix: sudo apt-mark unhold linux-generic-hwe-24.04 && sudo apt install linux-headers-7.0.0-42-generic && sudo dpkg --configure -a"* ]]
}

@test "cleanup_system succeeds and reports cleaned up when apt works" {
    apt() { return 0; }

    run cleanup_system
    [ "$status" -eq 0 ]
    [[ "$output" == *"System cleaned up"* ]]
}

# Each step must be checked on its own: an earlier failure would otherwise
# hide a missing `|| failed=1` on a later step.
_only_fails() {
    APT_FAIL_ON="$1"
    apt() { [ "$1" = "$APT_FAIL_ON" ] && return 100; return 0; }
    dpkg() { :; }
    run cleanup_system
    [ "$status" -ne 0 ]
    [[ "$output" != *"System cleaned up"* ]]
}

@test "cleanup_system fails when only full-upgrade fails" { _only_fails full-upgrade; }
@test "cleanup_system fails when only autoremove fails"   { _only_fails autoremove; }
@test "cleanup_system fails when only clean fails"        { _only_fails clean; }
