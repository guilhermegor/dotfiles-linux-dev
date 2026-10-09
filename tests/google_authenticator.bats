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
    for tool in apt-get pam-auth-update; do
        printf '#!/bin/bash\necho "%s $*" >> "%s"\n' "$tool" "$CALLS" > "$TMP/bin/$tool"
        chmod +x "$TMP/bin/$tool"
    done
    # sshd stub: -T prints $SSHD_T_OUT (exit $SSHD_T_RC), -t exits $SSHD_CHECK_RC.
    # While $DROPIN_MARK exists, -T also reports our drop-in's KI yes / UsePAM yes
    # (sshd keeps the first value, so the drop-in wins); the sudo stub deletes the
    # marker on `rm` of either drop-in name, like the real removal would.
    export SSHD_T_OUT="$TMP/sshd_T.out"
    export DROPIN_MARK="$TMP/dropin_present"
    printf 'passwordauthentication yes\nkbdinteractiveauthentication no\n' > "$SSHD_T_OUT"
    cat > "$TMP/bin/sshd" <<'STUB'
#!/bin/bash
case "$1" in
    -T) cat "$SSHD_T_OUT"
        if [ -e "$DROPIN_MARK" ]; then printf 'kbdinteractiveauthentication yes\nusepam %s\n' "${SSHD_DROPIN_PAM:-yes}"; fi
        exit "${SSHD_T_RC:-0}" ;;
    -t) exit "${SSHD_CHECK_RC:-0}" ;;
esac
STUB
    # sudo stub: log, forward only to the sshd stub — a real sudo is unreachable.
    cat > "$TMP/bin/sudo" <<STUB
#!/bin/bash
echo "sudo \$*" >> "$CALLS"
if [ "\$1" = rm ]; then case "\$*" in *google-authenticator.conf*) rm -f "\$DROPIN_MARK" ;; esac; fi
if [ "\$1" = install ]; then case "\$*" in *google-authenticator.conf*) : > "\$DROPIN_MARK" ;; esac; fi
if [ "\$1" = sshd ]; then shift; exec "$TMP/bin/sshd" "\$@"; fi
STUB
    chmod +x "$TMP/bin/sshd" "$TMP/bin/sudo"
    export PATH="$TMP/bin:$PATH"
    # pam-auth-update is a stub, so a fake common-auth stands in for its output.
    export _GA_COMMON_AUTH="$TMP/common-auth"
    echo 'auth required pam_google_authenticator.so nullok' > "$_GA_COMMON_AUTH"

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
    grep -q 'sshd_config.d/10-google-authenticator.conf' "$CALLS"
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
    refute_call 'sshd -[tT]'
    grep -q 'pam-auth-update --enable' "$CALLS"
}

@test "failed sshd -t removes the drop-in and fails" {
    export SSHD_CHECK_RC=1
    run install_google_authenticator
    [ "$status" -ne 0 ]
    grep -q 'sudo rm -f /etc/ssh/sshd_config.d/10-google-authenticator.conf' "$CALLS"
}

# refute_dropin_installed: the ssh drop-in was never copied into place.
refute_dropin_installed() {
    run grep -q 'install .*sshd_config.d' "$CALLS"
    [ "$status" -ne 0 ]
}

@test "key-only host (password and kbd-interactive off) skips the drop-in and warns" {
    printf 'passwordauthentication no\nkbdinteractiveauthentication no\n' > "$SSHD_T_OUT"
    run install_google_authenticator
    [ "$status" -eq 0 ]
    local install_output="$output"
    refute_dropin_installed
    [[ "$install_output" == *"reopen password logins"* ]]
    [[ "$install_output" == *"docs/totp-2fa.md"* ]]
    grep -q 'pam-auth-update --enable' "$CALLS"
}

@test "password auth on installs the drop-in" {
    printf 'passwordauthentication yes\nkbdinteractiveauthentication no\n' > "$SSHD_T_OUT"
    run install_google_authenticator
    [ "$status" -eq 0 ]
    grep -q 'install .*10-google-authenticator.conf' "$CALLS"
}

@test "KI yes with UsePAM yes (password off) installs the drop-in" {
    printf 'passwordauthentication no\nkbdinteractiveauthentication yes\nusepam yes\n' > "$SSHD_T_OUT"
    run install_google_authenticator
    [ "$status" -eq 0 ]
    grep -q 'install .*10-google-authenticator.conf' "$CALLS"
}

@test "KI yes with UsePAM no (password off) skips the drop-in" {
    printf 'passwordauthentication no\nkbdinteractiveauthentication yes\nusepam no\n' > "$SSHD_T_OUT"
    run install_google_authenticator
    [ "$status" -eq 0 ]
    refute_dropin_installed
}

@test "re-run on a now key-only host removes our drop-in and does not reinstall it" {
    printf 'passwordauthentication no\nkbdinteractiveauthentication no\nusepam yes\n' > "$SSHD_T_OUT"
    : > "$DROPIN_MARK"
    run install_google_authenticator
    [ "$status" -eq 0 ]
    [ ! -e "$DROPIN_MARK" ]
    refute_dropin_installed
    # the removal ran before the probe, or the probe would still see our KI yes
    local rm_line probe_line
    rm_line="$(grep -n 'sudo rm -f' "$CALLS" | head -1 | cut -d: -f1)"
    probe_line="$(grep -n 'sudo sshd -T' "$CALLS" | head -1 | cut -d: -f1)"
    [ "$rm_line" -lt "$probe_line" ]
}

@test "key-only re-run that removed an earlier drop-in warns to reload sshd" {
    export _GA_SSHD_DROPIN="$TMP/10-google-authenticator.conf"
    : > "$_GA_SSHD_DROPIN"
    printf 'passwordauthentication no\nkbdinteractiveauthentication no\n' > "$SSHD_T_OUT"
    run install_google_authenticator
    [ "$status" -eq 0 ]
    [[ "$output" == *"earlier TOTP ssh drop-in was removed"* ]]
}

@test "key-only first run with no earlier drop-in does not warn to reload" {
    export _GA_SSHD_DROPIN="$TMP/10-google-authenticator.conf"
    export _GA_SSHD_DROPIN_OLD="$TMP/google-authenticator.conf"
    printf 'passwordauthentication no\nkbdinteractiveauthentication no\n' > "$SSHD_T_OUT"
    run install_google_authenticator
    [ "$status" -eq 0 ]
    [[ "$output" != *"earlier TOTP ssh drop-in"* ]]
}

@test "install removes the old unprefixed drop-in name too" {
    run install_google_authenticator
    [ "$status" -eq 0 ]
    grep -q 'sudo rm -f .*/etc/ssh/sshd_config.d/google-authenticator.conf' "$CALLS"
}

@test "a failed sshd -T read skips the drop-in (fail closed)" {
    export SSHD_T_RC=1
    run install_google_authenticator
    [ "$status" -eq 0 ]
    local install_output="$output"
    refute_dropin_installed
    [[ "$install_output" == *"reopen password logins"* ]]
}

@test "install fails when pam-auth-update leaves common-auth without the module" {
    : > "$_GA_COMMON_AUTH"
    run install_google_authenticator
    [ "$status" -ne 0 ]
    [[ "$output" == *"left"*"unchanged"* ]]
    refute_dropin_installed
}

@test "DRY_RUN=1 uninstall runs nothing" {
    DRY_RUN=1 run uninstall_google_authenticator
    [ "$status" -eq 0 ]
    [ ! -s "$CALLS" ]
    [[ "$output" == *"[dry-run] sudo pam-auth-update --disable google-authenticator"* ]]
}

@test "DRY_RUN=1 runs nothing" {
    DRY_RUN=1 run install_google_authenticator
    [ "$status" -eq 0 ]
    [ ! -s "$CALLS" ]
    [[ "$output" == *"[dry-run] sudo pam-auth-update --enable google-authenticator"* ]]
}

@test "uninstall disables the profile and removes the drop-in" {
    : > "$_GA_COMMON_AUTH"
    run uninstall_google_authenticator
    [ "$status" -eq 0 ]
    grep -q 'pam-auth-update --disable google-authenticator' "$CALLS"
    grep -q 'rm -f .*/etc/ssh/sshd_config.d/10-google-authenticator.conf' "$CALLS"
    grep -q 'rm -f .*/etc/ssh/sshd_config.d/google-authenticator.conf' "$CALLS"
    refute_call '/etc/pam.d'
}

@test "uninstall fails and removes nothing while common-auth still lists the module" {
    run uninstall_google_authenticator
    [ "$status" -ne 0 ]
    [[ "$output" == *"still lists"* ]]
    refute_call 'rm -f'
}

@test "install tells the owner to reload sshd after adding the drop-in" {
    run install_google_authenticator
    [ "$status" -eq 0 ]
    [[ "$output" == *"systemctl reload ssh"* ]]
}

@test "registered as a CLI entry with an empty gnome folder" {
    [[ " ${INSTALL_REGISTRY[*]} " == *" install_google_authenticator:Google Authenticator (TOTP 2FA):: "* ]]
}

@test "sshd outside PATH but at /usr/sbin/sshd still gets the drop-in" {
    [ -x /usr/sbin/sshd ] || skip "no /usr/sbin/sshd on this host"
    command_exists() { [ "$1" = sshd ] && return 1; command -v "$1" &>/dev/null; }
    run install_google_authenticator
    [ "$status" -eq 0 ]
    grep -q 'install .*10-google-authenticator.conf' "$CALLS"
}

@test "sshd missing everywhere with an earlier drop-in warns to reload" {
    [ ! -x /usr/sbin/sshd ] || skip "host has /usr/sbin/sshd"
    command_exists() { [ "$1" = sshd ] && return 1; command -v "$1" &>/dev/null; }
    export _GA_SSHD_DROPIN="$TMP/10-google-authenticator.conf"
    : > "$_GA_SSHD_DROPIN"
    run install_google_authenticator
    [ "$status" -eq 0 ]
    [[ "$output" == *"earlier TOTP ssh drop-in was removed"* ]]
}

@test "an earlier drop-in pinning UsePAM no makes the install remove ours and fail" {
    export SSHD_DROPIN_PAM=no
    run install_google_authenticator
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not enable UsePAM"* ]]
    grep -q 'sudo rm -f /etc/ssh/sshd_config.d/10-google-authenticator.conf' "$CALLS"
}
