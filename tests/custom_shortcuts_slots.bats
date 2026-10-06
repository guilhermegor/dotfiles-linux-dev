#!/usr/bin/env bats
#
# GNOME custom keybinding slots are positional (dotfiles-linux-dev#601): the number of
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

@test "Super+B is retired; AI-state push/pull bind to Super+Shift+B / Super+Alt+B (#657)" {
    run grep -nE '"<Super>b"|backup-external-ssd' "$SCRIPT"
    [ "$status" -ne 0 ]
    run grep -F 'ai-state-sync push" "<Super><Shift>b"' "$SCRIPT"
    [ "$status" -eq 0 ]
    run grep -F 'ai-state-sync pull" "<Super><Alt>b"' "$SCRIPT"
    [ "$status" -eq 0 ]
}

# --- #653: clear every managed binding before assigning (stubbed gsettings/dconf) ---

setup_stubs() {
    export HOME="$BATS_TEST_TMPDIR/home" STATE="$BATS_TEST_TMPDIR/state"
    mkdir -p "$HOME" "$STATE" "$BATS_TEST_TMPDIR/bin"
    : > "$STATE/calls.log"
    cat > "$BATS_TEST_TMPDIR/bin/gsettings" <<'STUB'
#!/bin/bash
# set <schema:path> binding <v>: log it and record a DUP if another slot holds <v>.
[ "$1" = set ] || exit 0
slot=${2##*/custom-keybindings/}; slot=${slot%/}; slot=${slot#custom}
if [ "$3" = binding ]; then
    echo "binding $slot $4" >> "$STATE/calls.log"
    if [ -n "$4" ]; then
        for f in "$STATE"/slot_*; do
            if [ "$f" != "$STATE/slot_$slot" ] && [ "$(cat "$f")" = "$4" ]; then
                echo "DUP $4 $slot $(basename "$f")" >> "$STATE/dups.log"
            fi
        done
    fi
    printf '%s' "$4" > "$STATE/slot_$slot"
fi
exit 0
STUB
    printf '#!/bin/bash\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/dconf"
    chmod +x "$BATS_TEST_TMPDIR/bin/"*
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "every managed slot is cleared before any slot gets its new binding" {
    setup_stubs
    run bash "$SCRIPT" <<< "n"
    [ "$status" -eq 0 ]
    n=$(grep -cE '^ +set_individual_keybinding [0-9]+' "$SCRIPT")
    last_clear=$(grep -nE '^binding [0-9]+ $' "$STATE/calls.log" | tail -1 | cut -d: -f1)
    first_assign=$(grep -nE '^binding [0-9]+ .+' "$STATE/calls.log" | head -1 | cut -d: -f1)
    [ "$(grep -cE '^binding [0-9]+ $' "$STATE/calls.log")" -eq "$n" ]
    [ "$last_clear" -lt "$first_assign" ]
}

@test "renumbered layout never has two slots holding the same binding" {
    setup_stubs
    # pre-renumber layout: slot 11 still holds what slot 10 is about to receive
    printf '%s' '<Super>c' > "$STATE/slot_8"
    printf '%s' '<Super>b' > "$STATE/slot_9"
    printf '%s' '<Super>j' > "$STATE/slot_10"
    printf '%s' '<Super><Shift>e' > "$STATE/slot_11"
    printf '%s' '<Super><Shift>m' > "$STATE/slot_12"
    run bash "$SCRIPT" <<< "n"
    [ "$status" -eq 0 ]
    [ ! -s "$STATE/dups.log" ]
    [ "$(cat "$STATE/slot_10")" = '<Super><Shift>e' ]
}
