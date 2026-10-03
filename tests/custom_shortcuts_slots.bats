#!/usr/bin/env bats
#
# GNOME custom keybinding slots are positional (dotfiles-dev#601): the number of
# `custom<N>` paths in set_keybindings_array must equal the number of
# set_individual_keybinding calls, with no gap and no dangling path.

SCRIPT="${BATS_TEST_DIRNAME}/../distro_config/set_custom_shortcuts.sh"

@test "array paths and set_individual_keybinding calls match, indices contiguous" {
    paths=$(sed -n '/^set_keybindings_array()/,/^}/p' "$SCRIPT" | grep -oE 'custom[0-9]+/' | tr -d '/' | sort -V | tr '\n' ' ')
    calls=$(grep -oE '^ +set_individual_keybinding [0-9]+' "$SCRIPT" | awk '{print "custom"$2}' | sort -V | tr '\n' ' ')
    [ -n "$paths" ]
    [ "$paths" = "$calls" ]
    expected=$(seq 0 $(( $(wc -w <<<"$paths") - 1 )) | sed 's/^/custom/' | tr '\n' ' ')
    [ "$paths" = "$expected" ]
}

@test "the removed Super+K Kill Insync shortcut is gone" {
    run grep -nE '<Super>k|Kill Insync"' "$SCRIPT"
    [ "$status" -ne 0 ]
}

@test "stale custom15 dconf path is reset before the array is set" {
    reset_line=$(grep -n 'dconf reset -f .*custom15/' "$SCRIPT" | cut -d: -f1)
    call_line=$(grep -nE '^ +set_keybindings_array$' "$SCRIPT" | cut -d: -f1)
    [ -n "$reset_line" ]
    [ "$reset_line" -lt "$call_line" ]
}
