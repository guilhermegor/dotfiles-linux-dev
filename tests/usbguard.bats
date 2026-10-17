#!/usr/bin/env bats
#
# Unit tests for install_usbguard / uninstall_usbguard (issue #788).
#
# This is a lockout-risk feature: a usbguard daemon that starts with
# ImplicitPolicyTarget=block and an empty rules.conf blocks the keyboard and
# mouse. The systemctl stub therefore records ENFORCED_WITHOUT_POLICY whenever
# it is asked to enable/start/restart usbguard while rules.conf holds no rule,
# so the ordering tests fail if enforcement ever runs before the policy exists.
#
# sudo is a stub that logs and then runs the command against a fake
# /etc/usbguard under $TMP; usbguard/systemctl/apt-get are stubs too.
#
# Run locally: bats tests/usbguard.bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP="$(mktemp -d)"
    export LOG_FILE="$TMP/log"
    export CALLS="$TMP/calls.log"
    : > "$CALLS"
    export HOME="$TMP/home"
    mkdir -p "$HOME" "$TMP/bin"
    export SUDO_USER="alice"

    export _UG_DIR="$TMP/etc/usbguard"
    mkdir -p "$_UG_DIR"
    : > "$_UG_DIR/rules.conf"
    printf 'RuleFile=/etc/usbguard/rules.conf\nImplicitPolicyTarget=block\nIPCAllowedUsers=root\nIPCAllowedGroups=root plugdev\n' \
        > "$_UG_DIR/usbguard-daemon.conf"

    printf '#!/bin/bash\necho "apt-get $*" >> "%s"\n' "$CALLS" > "$TMP/bin/apt-get"
    # sudo: log the call, then run it for real against the fake config dir.
    printf '#!/bin/bash\necho "sudo $*" >> "%s"\nexec "$@"\n' "$CALLS" > "$TMP/bin/sudo"
    cat > "$TMP/bin/usbguard" <<STUB
#!/bin/bash
echo "usbguard \$*" >> "$CALLS"
if [ "\$1" = generate-policy ] && [ -z "\${GEN_EMPTY:-}" ]; then
    echo 'allow id 1d6b:0002 serial "" name "xHCI Host Controller"'
    echo 'allow id 046d:c52b serial "" name "USB Receiver"'
fi
STUB
    cat > "$TMP/bin/systemctl" <<STUB
#!/bin/bash
echo "systemctl \$*" >> "$CALLS"
case "\$1" in
    enable|start|restart)
        if ! grep -qvE '^[[:space:]]*(#|\$)' "$_UG_DIR/rules.conf"; then
            echo "ENFORCED_WITHOUT_POLICY systemctl \$*" >> "$CALLS"
        fi ;;
esac
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

# refute_call PATTERN: the stub call log never matches PATTERN (no bare `!`).
refute_call() {
    run grep -q -- "$1" "$CALLS"
    [ "$status" -ne 0 ]
}

# call_line PATTERN: line number of the first matching call.
call_line() {
    grep -n -m1 -- "$1" "$CALLS" | cut -d: -f1
}

@test "registered in INSTALL_REGISTRY with no gnome folder and no desktop file" {
    local entry
    for entry in "${INSTALL_REGISTRY[@]}"; do
        [[ "$entry" == install_usbguard:* ]] && break
    done
    [ "$entry" = "install_usbguard:USBGuard (block unknown USB devices)::" ]
    declare -F install_usbguard
    declare -F uninstall_usbguard
}

@test "fresh install generates the policy from connected devices and enables the daemon" {
    run install_usbguard
    [ "$status" -eq 0 ]
    grep -q '^allow id 046d:c52b' "$_UG_DIR/rules.conf"
    grep -q '^ImplicitPolicyTarget=block$' "$_UG_DIR/usbguard-daemon.conf"
    grep -q 'systemctl enable usbguard' "$CALLS"
    grep -q 'systemctl restart usbguard' "$CALLS"
}

@test "policy is generated and written BEFORE the daemon is enabled or restarted" {
    run install_usbguard
    [ "$status" -eq 0 ]
    refute_call ENFORCED_WITHOUT_POLICY
    local gen enable restart
    gen="$(call_line 'usbguard generate-policy')"
    enable="$(call_line 'systemctl enable usbguard')"
    restart="$(call_line 'systemctl restart usbguard')"
    [ -n "$gen" ] && [ -n "$enable" ] && [ -n "$restart" ]
    [ "$gen" -lt "$enable" ]
    [ "$enable" -lt "$restart" ]
}

@test "the ordering stub really detects enforcement without a policy" {
    : > "$_UG_DIR/rules.conf"
    "$TMP/bin/systemctl" enable usbguard
    run grep -q ENFORCED_WITHOUT_POLICY "$CALLS"
    [ "$status" -eq 0 ]
}

@test "an existing rules.conf with rules is preserved byte for byte" {
    printf '# mine\nallow id 1050:0407 name "YubiKey"\n' > "$_UG_DIR/rules.conf"
    cp "$_UG_DIR/rules.conf" "$TMP/rules.before"
    run install_usbguard
    [ "$status" -eq 0 ]
    cmp "$_UG_DIR/rules.conf" "$TMP/rules.before"
    refute_call 'usbguard generate-policy'
    grep -q 'systemctl enable usbguard' "$CALLS"
}

@test "a comment-only rules.conf counts as empty and is generated" {
    printf '# nothing here\n\n' > "$_UG_DIR/rules.conf"
    run install_usbguard
    [ "$status" -eq 0 ]
    grep -q '^allow id 1d6b:0002' "$_UG_DIR/rules.conf"
}

@test "an empty generated policy aborts before the daemon is touched" {
    export GEN_EMPTY=1
    run install_usbguard
    [ "$status" -ne 0 ]
    [ ! -s "$_UG_DIR/rules.conf" ]
    refute_call 'systemctl'
}

@test "ImplicitPolicyTarget is forced to block when the config says allow" {
    sed -i 's/^ImplicitPolicyTarget=.*/ImplicitPolicyTarget=allow/' "$_UG_DIR/usbguard-daemon.conf"
    run install_usbguard
    [ "$status" -eq 0 ]
    grep -q '^ImplicitPolicyTarget=block$' "$_UG_DIR/usbguard-daemon.conf"
    run grep -c '^ImplicitPolicyTarget=' "$_UG_DIR/usbguard-daemon.conf"
    [ "$output" = "1" ]
}

@test "the desktop user is added to IPCAllowedUsers once, keeping existing entries" {
    run install_usbguard
    [ "$status" -eq 0 ]
    run install_usbguard
    [ "$status" -eq 0 ]
    run grep '^IPCAllowedUsers=' "$_UG_DIR/usbguard-daemon.conf"
    [ "$output" = "IPCAllowedUsers=root alice" ]
}

@test "a missing IPCAllowedUsers line is appended" {
    sed -i '/^IPCAllowedUsers=/d' "$_UG_DIR/usbguard-daemon.conf"
    run install_usbguard
    [ "$status" -eq 0 ]
    grep -q '^IPCAllowedUsers=root alice$' "$_UG_DIR/usbguard-daemon.conf"
}

@test "post-install message shows how to allow a device and how to back out" {
    run install_usbguard
    [ "$status" -eq 0 ]
    [[ "$output" == *"usbguard list-devices"* ]]
    [[ "$output" == *"usbguard allow-device -p <id>"* ]]
    [[ "$output" == *"sudo systemctl disable --now usbguard"* ]]
}

@test "DRY_RUN changes nothing: no package, daemon, policy or config mutation" {
    export DRY_RUN=1
    cp "$_UG_DIR/usbguard-daemon.conf" "$TMP/conf.before"
    run install_usbguard
    [ "$status" -eq 0 ]
    [ ! -s "$CALLS" ]
    [ ! -s "$_UG_DIR/rules.conf" ]
    cmp "$_UG_DIR/usbguard-daemon.conf" "$TMP/conf.before"
    [[ "$output" == *"[dry-run] sudo usbguard generate-policy"* ]]
    [[ "$output" == *"[dry-run] sudo systemctl enable usbguard"* ]]
}

@test "uninstall stops the daemon first, then removes the package" {
    run uninstall_usbguard
    [ "$status" -eq 0 ]
    local stop remove
    stop="$(call_line 'systemctl disable --now usbguard')"
    remove="$(call_line 'apt-get remove -y usbguard')"
    [ -n "$stop" ] && [ -n "$remove" ]
    [ "$stop" -lt "$remove" ]
}

@test "uninstall under DRY_RUN changes nothing" {
    export DRY_RUN=1
    run uninstall_usbguard
    [ "$status" -eq 0 ]
    [ ! -s "$CALLS" ]
}
