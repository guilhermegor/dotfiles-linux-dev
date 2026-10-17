#!/usr/bin/env bats
#
# Unit tests for the USBGuard Allow/Block prompt (issue #789): rule
# classification, dialog -> command mapping, and the watch-handler gate.
# usbguard, pkexec and zenity are stubs that log their argv; nothing touches
# the real daemon.
#
# Run locally: bats tests/usbguard_prompt.bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP="$(mktemp -d)"
    export CALLS="$TMP/calls.log"
    : > "$CALLS"
    mkdir -p "$TMP/bin"
    local c
    for c in usbguard pkexec; do
        printf '#!/bin/bash\necho "%s $*" >> "%s"\n' "$c" "$CALLS" > "$TMP/bin/$c"
    done
    # zenity: prints $ZEN_OUT, exits $ZEN_RC (default 0), logs the text it was given.
    cat > "$TMP/bin/zenity" <<STUB
#!/bin/bash
echo "zenity \$*" >> "$CALLS"
[ -n "\${ZEN_OUT:-}" ] && echo "\$ZEN_OUT"
exit "\${ZEN_RC:-0}"
STUB
    chmod +x "$TMP/bin/"*
    export PATH="$TMP/bin:$PATH"
    # shellcheck source=../distro_config/usbguard/usbguard-prompt
    source "$REPO_ROOT/distro_config/usbguard/usbguard-prompt"
}

teardown() {
    rm -rf "$TMP"
}

STORAGE='block id 0781:5581 serial "X" name "Ultra" hash "h" parent-hash "p" via-port "1-1" with-interface { 08:06:50 }'
HID='block id 04d9:0169 serial "" name "Keyboard" hash "h" parent-hash "p" via-port "1-2" with-interface { 03:01:01 03:00:00 }'
COMBO='block id 1234:5678 serial "" name "Pendrive" hash "h" parent-hash "p" via-port "1-3" with-interface { 08:06:50 03:01:01 }'
NOINFO='block id 1234:5678 serial "" name "Mystery" hash "h" parent-hash "p" via-port "1-3"'
NONAME='block id 1:2 serial "" name "" with-interface { 08:06:50 }'

@test "classify: storage only is plain" {
    run usbguard_classify "$STORAGE"
    [ "$output" = plain ]
}

@test "classify: HID only is hid" {
    run usbguard_classify "$HID"
    [ "$output" = hid ]
}

@test "classify: storage plus HID is combo" {
    run usbguard_classify "$COMBO"
    [ "$output" = combo ]
}

@test "classify: no interface info is unknown" {
    run usbguard_classify "$NOINFO"
    [ "$output" = unknown ]
}

@test "classify: wildcard HID and set operator are understood" {
    run usbguard_classify 'block id 1:2 name "x" with-interface one-of { 08:*:* 03:*:* }'
    [ "$output" = combo ]
}

@test "classify: other classes (hub, audio) are plain, not hid" {
    run usbguard_classify 'block id 1:2 name "x" with-interface { 09:00:00 01:01:00 }'
    [ "$output" = plain ]
}

@test "device name is read from the rule, with a fallback" {
    run usbguard_device_name "$COMBO"
    [ "$output" = Pendrive ]
    run usbguard_device_name "$NONAME"
    [ "$output" = "unnamed device" ]
}

@test "text: warnings escalate and every class says no check can prove it" {
    local c
    for c in plain hid combo unknown; do
        run usbguard_prompt_text "$c" Dev
        [[ "$output" == *"No check can prove a device is not a Rubber Ducky"* ]]
    done
    run usbguard_prompt_text hid Dev
    [[ "$output" == WARNING* ]]
    run usbguard_prompt_text combo Dev
    [[ "$output" == "!! STRONG WARNING !!"* ]]
    run usbguard_prompt_text plain Dev
    [[ "$output" != *WARNING* ]]
}

@test "action: OK is allow, extra button is always, everything else is block" {
    run usbguard_prompt_action 0 ""
    [ "$output" = allow ]
    run usbguard_prompt_action 1 "Always allow"
    [ "$output" = always ]
    run usbguard_prompt_action 1 ""
    [ "$output" = block ]
    run usbguard_prompt_action 5 ""
    [ "$output" = block ]
}

@test "apply: allow -> usbguard allow-device (no pkexec, not permanent)" {
    usbguard_prompt_apply allow 7
    grep -qx 'usbguard allow-device 7' "$CALLS"
    run grep -E 'pkexec| -p ' "$CALLS"
    [ "$status" -ne 0 ]
}

@test "apply: block -> usbguard block-device" {
    usbguard_prompt_apply block 7
    grep -qx 'usbguard block-device 7' "$CALLS"
}

@test "apply: always -> pkexec usbguard allow-device -p" {
    usbguard_prompt_apply always 7
    grep -qx 'pkexec usbguard allow-device -p 7' "$CALLS"
}

@test "dialog: Allow button runs allow-device" {
    ZEN_RC=0 usbguard_prompt_dialog 9 "$STORAGE"
    grep -qx 'usbguard allow-device 9' "$CALLS"
}

@test "dialog: Always allow button goes through pkexec" {
    ZEN_RC=1 ZEN_OUT="Always allow" usbguard_prompt_dialog 9 "$HID"
    grep -qx 'pkexec usbguard allow-device -p 9' "$CALLS"
}

@test "dialog: Block, close and timeout all block" {
    ZEN_RC=1 usbguard_prompt_dialog 9 "$COMBO"
    ZEN_RC=5 usbguard_prompt_dialog 9 "$COMBO"
    run grep -c '^usbguard block-device 9$' "$CALLS"
    [ "$output" = 2 ]
    run grep -E 'allow-device' "$CALLS"
    [ "$status" -ne 0 ]
}

@test "dialog: a combo device shows the strong warning text" {
    usbguard_prompt_dialog 9 "$COMBO"
    grep -q 'STRONG WARNING' "$CALLS"
}

@test "handler: ignores events that are not a blocked insert" {
    USBGUARD_DEVICE_EVENT=Remove USBGUARD_DEVICE_TARGET=block USBGUARD_DEVICE_ID=3 \
        usbguard_prompt_main
    USBGUARD_DEVICE_EVENT=Insert USBGUARD_DEVICE_TARGET=allow USBGUARD_DEVICE_ID=3 \
        usbguard_prompt_main
    sleep 0.3
    [ ! -s "$CALLS" ]
}

@test "handler: a blocked insert shows the dialog" {
    USBGUARD_DEVICE_EVENT=Insert USBGUARD_DEVICE_TARGET=block USBGUARD_DEVICE_ID=3 \
        USBGUARD_DEVICE_RULE="$STORAGE" usbguard_prompt_main
    wait
    grep -q '^zenity ' "$CALLS"
    grep -qx 'usbguard allow-device 3' "$CALLS"
}

@test "unit file runs usbguard watch with the installed handler, never udev" {
    run grep -E '^ExecStart=/usr/bin/usbguard watch --wait --exec %h/.local/bin/usbguard-prompt$' \
        "$REPO_ROOT/distro_config/usbguard/usbguard-prompt.service"
    [ "$status" -eq 0 ]
}
