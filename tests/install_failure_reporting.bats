#!/usr/bin/env bats
#
# Regression for issue #343: an install_* function that prints
# `print_status "warning"` on a genuine failure but falls off the end of the
# function with an implicit `return 0` never reaches INSTALL_FAILURES, so
# report_failures prints "All installs completed without errors" even though
# something failed. Mirrors tests/run_chain.bats (same shape, different
# collector) — never invokes a real installer, only run_install/report_failures
# from _common.sh plus a synthetic failing function.
#
# Run locally: bats tests/

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    HOME="$(mktemp -d)"
    export HOME

    # shellcheck source=../distro_config/install_lib/_common.sh
    source "$REPO_ROOT/distro_config/install_lib/_common.sh"
    PACKAGE_MANAGER="apt"

    # shellcheck source=../distro_config/install_lib/system_utils.sh
    source "$REPO_ROOT/distro_config/install_lib/system_utils.sh"
}

teardown() {
    rm -rf "$HOME"
}

# A well-behaved install_* (the fixed shape): warns, then returns 1.
_fake_install_that_fails() {
    print_status "warning" "fake tool could not be verified"
    return 1
}

@test "run_install records a failing install_* in INSTALL_FAILURES" {
    run_install _fake_install_that_fails "Fake Tool"
    [ "${#INSTALL_FAILURES[@]}" -eq 1 ]
    [ "${INSTALL_FAILURES[0]}" = "Fake Tool" ]
}

@test "the end-of-run summary names a failure from run_install, not the all-clear" {
    run_install _fake_install_that_fails "Fake Tool"
    run report_failures
    [[ "$output" == *"Fake Tool"* ]]
    [[ "$output" != *"All installs completed without errors"* ]]
}

@test "report_failures prints the all-clear only when INSTALL_FAILURES is empty" {
    run report_failures
    [ "$status" -eq 0 ]
    [[ "$output" == *"All installs completed without errors"* ]]
}

@test "report_failures names a recorded failure instead of the all-clear" {
    INSTALL_FAILURES=("Fake Tool")
    run report_failures
    [[ "$output" == *"INSTALL FAILURES"* ]]
    [[ "$output" == *"Fake Tool"* ]]
    [[ "$output" != *"All installs completed without errors"* ]]
}

# --- regression: the two functions this issue actually fixed -----------------

@test "verify_openlogi returns non-zero when openlogi is not installed" {
    command_exists() { return 1; }  # hermetic: ignore a real /usr/bin/openlogi
    run verify_openlogi
    [ "$status" -ne 0 ]
}

@test "run_install records install_openlogi as failed when verification fails" {
    # install_openlogi's last statement is verify_openlogi, so a verification
    # failure must propagate as the function's own exit status (#343).
    command_exists() { return 1; }  # hermetic: ignore a real /usr/bin/openlogi
    run_install verify_openlogi "openlogi (Logitech HID++ manager)"
    [ "${#INSTALL_FAILURES[@]}" -eq 1 ]
    [ "${INSTALL_FAILURES[0]}" = "openlogi (Logitech HID++ manager)" ]
}

@test "configure_gsconnect returns non-zero when the extension is not found" {
    gnome-extensions() { echo ""; }
    export -f gnome-extensions
    run configure_gsconnect
    [ "$status" -ne 0 ]
}
