#!/usr/bin/env bats
#
# Unit tests for install_google_authenticator / uninstall_google_authenticator
# (issue #676). apt-get, sudo, pam-auth-update and sshd are stubs that only
# append their argv to a log; nothing here touches the real system.
#
# Run locally: bats tests/google_authenticator.bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP="$(mktemp -d)"
    export LOG_FILE="$TMP/log"
    export CALLS="$TMP/calls.log"
    : > "$CALLS"
    mkdir -p "$TMP/bin"
    for tool in apt-get pam-auth-update sshd; do
        printf '#!/bin/bash\necho "%s $*" >> "%s"\n' "$tool" "$CALLS" > "$TMP/bin/$tool"
        chmod +x "$TMP/bin/$tool"
    done
    # sudo stub: log only, never exec — a real sudo must not be reachable.
    printf '#!/bin/bash\necho "sudo $*" >> "%s"\n' "$CALLS" > "$TMP/bin/sudo"
    chmod +x "$TMP/bin/sudo"
    export PATH="$TMP/bin:$PATH"

    # shellcheck source=../distro_config/install_lib/_common.sh
    source "$REPO_ROOT/distro_config/install_lib/_common.sh"
    export PACKAGE_MANAGER="apt"
    # shellcheck source=../distro_config/install_lib/system_utils.sh
    source "$REPO_ROOT/distro_config/install_lib/system_utils.sh"
}

teardown() {
    rm -rf "$TMP"
}

# refute_call PATTERN: the stub call log never matches PATTERN (no bare `!`).
refute_call() {
    run grep -q -- "$1" "$CALLS"
    [ "$status" -ne 0 ]
}

@test "profile keeps nullok and runs as Additional (after pam_unix)" {
    run grep -c 'pam_google_authenticator.so nullok' "$REPO_ROOT/distro_config/pam/google-authenticator"
    [ "$output" = "2" ]
    run grep -q '^Auth-Type: Additional' "$REPO_ROOT/distro_config/pam/google-authenticator"
    [ "$status" -eq 0 ]
}

@test "install enables the profile via pam-auth-update and never edits /etc/pam.d" {
    run install_google_authenticator
    [ "$status" -eq 0 ]
    grep -q 'apt-get install -y libpam-google-authenticator' "$CALLS"
    grep -q 'pam-auth-update --enable google-authenticator' "$CALLS"
    grep -q '/usr/share/pam-configs/google-authenticator' "$CALLS"
    refute_call '/etc/pam.d'
}

@test "install writes and validates the ssh drop-in when sshd is present" {
    run install_google_authenticator
    [ "$status" -eq 0 ]
    grep -q 'sshd_config.d/google-authenticator.conf' "$CALLS"
    grep -q 'sudo sshd -t' "$CALLS"
    run grep -E '^(KbdInteractiveAuthentication|UsePAM) yes' \
        "$REPO_ROOT/distro_config/pam/sshd-google-authenticator.conf"
    [ "${#lines[@]}" -eq 2 ]
    run grep -q AuthenticationMethods "$REPO_ROOT/distro_config/pam/sshd-google-authenticator.conf"
    [ "$status" -ne 0 ]
}

@test "install skips the ssh drop-in cleanly without sshd" {
    command_exists() { [ "$1" = sshd ] && return 1; command -v "$1" &>/dev/null; }
    run install_google_authenticator
    [ "$status" -eq 0 ]
    refute_call 'sshd'
    grep -q 'pam-auth-update --enable' "$CALLS"
}

@test "failed sshd -t removes the drop-in and fails" {
    printf '#!/bin/bash\necho "sudo $*" >> "%s"\nif [ "$1" = sshd ]; then exit 1; fi\n' "$CALLS" > "$TMP/bin/sudo"
    run install_google_authenticator
    [ "$status" -ne 0 ]
    grep -q 'sudo rm -f /etc/ssh/sshd_config.d/google-authenticator.conf' "$CALLS"
}

@test "DRY_RUN=1 runs nothing" {
    DRY_RUN=1 run install_google_authenticator
    [ "$status" -eq 0 ]
    [ ! -s "$CALLS" ]
    [[ "$output" == *"[dry-run] sudo pam-auth-update --enable google-authenticator"* ]]
}

@test "uninstall disables the profile and removes the drop-in" {
    run uninstall_google_authenticator
    [ "$status" -eq 0 ]
    grep -q 'pam-auth-update --disable google-authenticator' "$CALLS"
    grep -q 'rm -f /etc/ssh/sshd_config.d/google-authenticator.conf' "$CALLS"
    refute_call '/etc/pam.d'
}

@test "registered as a CLI entry with an empty gnome folder" {
    [[ " ${INSTALL_REGISTRY[*]} " == *" install_google_authenticator:Google Authenticator (TOTP 2FA):: "* ]]
}
