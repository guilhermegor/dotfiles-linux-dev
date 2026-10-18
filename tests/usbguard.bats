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

@test "the desktop user gets a scoped ACL file: devices, policy list, exceptions listen, nothing else" {
    run install_usbguard
    [ "$status" -eq 0 ]
    local acl="$_UG_DIR/IPCAccessControl.d/alice"
    [ "$(stat -c %a "$acl")" = "600" ]
    [ "$(cat "$acl")" = "$(printf 'Devices=modify,list,listen\nPolicy=list\nExceptions=listen')" ]
    run grep -c 'Parameters' "$acl"
    [ "$output" = "0" ]
    run grep -c 'Policy=.*modify' "$acl"
    [ "$output" = "0" ]
}

@test "the daemon is pointed at the ACL folder" {
    run install_usbguard
    [ "$status" -eq 0 ]
    grep -q "^IPCAccessControlFiles=$_UG_DIR/IPCAccessControl.d/\$" "$_UG_DIR/usbguard-daemon.conf"
}

@test "IPCAllowedUsers is never modified (it would grant full rights, incl. Parameters)" {
    run install_usbguard
    [ "$status" -eq 0 ]
    run install_usbguard
    [ "$status" -eq 0 ]
    run grep '^IPCAllowedUsers=' "$_UG_DIR/usbguard-daemon.conf"
    [ "$output" = "IPCAllowedUsers=root" ]
    run grep -c alice "$_UG_DIR/usbguard-daemon.conf"
    [ "$output" = "0" ]
}

@test "RuleFile is pinned to the rules.conf that the empty-policy gate checks" {
    printf 'RuleFile=/etc/usbguard/other.conf\nIPCAllowedUsers=root\n' > "$_UG_DIR/usbguard-daemon.conf"
    run install_usbguard
    [ "$status" -eq 0 ]
    grep -q "^RuleFile=$_UG_DIR/rules.conf\$" "$_UG_DIR/usbguard-daemon.conf"
}

@test "an already-installed usbguard is not reinstalled but config is still applied" {
    run install_usbguard
    [ "$status" -eq 0 ]
    refute_call 'apt-get install'
    grep -q 'systemctl restart usbguard' "$CALLS"
}

@test "refuses when the user is in a group listed in IPCAllowedGroups, daemon untouched" {
    printf '#!/bin/bash\necho "alice plugdev"\n' > "$TMP/bin/id"
    chmod +x "$TMP/bin/id"
    cp "$_UG_DIR/usbguard-daemon.conf" "$TMP/conf.before"
    run install_usbguard
    [ "$status" -eq 1 ]
    [[ "$output" == *"plugdev"* ]]
    [[ "$output" == *"remove 'plugdev' from IPCAllowedGroups"* ]]
    refute_call 'systemctl'
    [ ! -e "$_UG_DIR/IPCAccessControl.d/alice" ]
    run diff "$_UG_DIR/usbguard-daemon.conf" "$TMP/conf.before"
    [ "$status" -eq 0 ]
}

@test "DRY_RUN reports the IPCAllowedGroups refusal without changing anything" {
    printf '#!/bin/bash\necho "alice plugdev"\n' > "$TMP/bin/id"
    chmod +x "$TMP/bin/id"
    DRY_RUN=1 run install_usbguard
    [[ "$output" == *"would refuse"* ]]
    refute_call 'systemctl'
}

@test "DRY_RUN says the group check was skipped when the root-only config is unreadable" {
    [ "$(id -u)" -ne 0 ] || skip "root can read a 0000 file"
    printf '#!/bin/bash\necho "alice plugdev"\n' > "$TMP/bin/id"
    chmod +x "$TMP/bin/id"
    # sudo -n fails, as it does with no cached credentials.
    printf '#!/bin/bash\necho "sudo $*" >> "%s"\n[ "$1" = -n ] && exit 1\nexec "$@"\n' "$CALLS" > "$TMP/bin/sudo"
    chmod 000 "$_UG_DIR/usbguard-daemon.conf"
    DRY_RUN=1 run install_usbguard
    chmod 600 "$_UG_DIR/usbguard-daemon.conf"
    [[ "$output" == *"IPCAllowedGroups check was skipped"* ]]
    [[ "$output" != *"would refuse"* ]]
    refute_call 'systemctl'
}

@test "DRY_RUN reads a root-only config through cached sudo and reports the refusal" {
    [ "$(id -u)" -ne 0 ] || skip "root can read a 0000 file"
    printf '#!/bin/bash\necho "alice plugdev"\n' > "$TMP/bin/id"
    chmod +x "$TMP/bin/id"
    # Cached sudo: -n succeeds and reads the file as if it were root.
    printf '#!/bin/bash\necho "sudo $*" >> "%s"\n[ "$1" = -n ] && shift\nchmod 600 "%s"\n"$@"; rc=$?\nchmod 000 "%s"\nexit $rc\n' \
        "$CALLS" "$_UG_DIR/usbguard-daemon.conf" "$_UG_DIR/usbguard-daemon.conf" > "$TMP/bin/sudo"
    chmod 000 "$_UG_DIR/usbguard-daemon.conf"
    DRY_RUN=1 run install_usbguard
    chmod 600 "$_UG_DIR/usbguard-daemon.conf"
    [[ "$output" == *"would refuse"* ]]
    refute_call 'systemctl'
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

@test "uninstall stops and removes the prompt watcher before removing the package" {
    unset XDG_CONFIG_HOME
    local unit="$HOME/.config/systemd/user/usbguard-prompt.service"
    mkdir -p "${unit%/*}" "$HOME/.local/bin"
    : > "$unit"
    : > "$HOME/.local/bin/usbguard-prompt"
    run uninstall_usbguard
    [ "$status" -eq 0 ]
    local stop remove
    stop="$(call_line 'systemctl --user disable --now usbguard-prompt.service')"
    remove="$(call_line 'apt-get remove -y usbguard')"
    [ -n "$stop" ] && [ -n "$remove" ]
    [ "$stop" -lt "$remove" ]
    [ ! -e "$unit" ]
    [ ! -e "$HOME/.local/bin/usbguard-prompt" ]
}

@test "a stale IPCAllowedUsers grant from the earlier version is removed, root and others kept" {
    sed -i 's/^IPCAllowedUsers=.*/IPCAllowedUsers=root alice bob/' "$_UG_DIR/usbguard-daemon.conf"
    run install_usbguard
    [ "$status" -eq 0 ]
    run grep '^IPCAllowedUsers=' "$_UG_DIR/usbguard-daemon.conf"
    [ "$output" = "IPCAllowedUsers=root bob" ]
    sed -i 's/^IPCAllowedUsers=.*/IPCAllowedUsers=root alice/' "$_UG_DIR/usbguard-daemon.conf"
    run install_usbguard
    run grep '^IPCAllowedUsers=' "$_UG_DIR/usbguard-daemon.conf"
    [ "$output" = "IPCAllowedUsers=root" ]
}

@test "uninstall also drops a stale IPCAllowedUsers entry" {
    sed -i 's/^IPCAllowedUsers=.*/IPCAllowedUsers=root alice/' "$_UG_DIR/usbguard-daemon.conf"
    run uninstall_usbguard
    [ "$status" -eq 0 ]
    run grep '^IPCAllowedUsers=' "$_UG_DIR/usbguard-daemon.conf"
    [ "$output" = "IPCAllowedUsers=root" ]
}

@test "uninstall run directly as root keeps root in IPCAllowedUsers" {
    # The daemon has no built-in root bypass: IPCAllowedUsers=root is
    # root's only IPC grant, and install never re-adds it.
    unset SUDO_USER
    id() { [ "$1" = "-un" ] && echo root || command id "$@"; }
    run uninstall_usbguard
    [ "$status" -eq 0 ]
    run grep '^IPCAllowedUsers=' "$_UG_DIR/usbguard-daemon.conf"
    [ "$output" = "IPCAllowedUsers=root" ]
}

@test "uninstall removes the user's ACL file" {
    install_usbguard > /dev/null
    [ -f "$_UG_DIR/IPCAccessControl.d/alice" ]
    run uninstall_usbguard
    [ "$status" -eq 0 ]
    [ ! -e "$_UG_DIR/IPCAccessControl.d/alice" ]
}

@test "uninstall under DRY_RUN changes nothing" {
    export DRY_RUN=1
    run uninstall_usbguard
    [ "$status" -eq 0 ]
    [ ! -s "$CALLS" ]
}
