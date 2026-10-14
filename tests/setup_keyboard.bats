#!/usr/bin/env bats
#
# Unit tests for drivers/setup_keyboard.sh layout merging, against a fake
# `gsettings` backed by files (never the real session).
#
# Run locally: bats tests/

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$REPO_ROOT/drivers/setup_keyboard.sh"
    TMP="$(mktemp -d)"
    export GS_DIR="$TMP/gs"
    mkdir -p "$GS_DIR" "$TMP/bin"
    cat > "$TMP/bin/gsettings" << 'EOF'
#!/bin/bash
# get <schema> <key> | set <schema> <key> <value>; GS_DROP_SET=1 ignores sets.
f="$GS_DIR/$2.$3"
case "$1" in
    get) cat "$f" ;;
    set) [[ -n "${GS_DROP_SET:-}" ]] || printf '%s\n' "$4" > "$f" ;;
esac
EOF
    chmod +x "$TMP/bin/gsettings"
    export PATH="$TMP/bin:$PATH"
    echo "@a(ss) []" > "$GS_DIR/org.gnome.desktop.input-sources.sources"
    echo "@as []" > "$GS_DIR/org.gnome.desktop.wm.keybindings.switch-input-source"
}

teardown() {
    rm -rf "$TMP"
}

# Run configure_keyboard_layouts in a subshell with the script sourced.
configure() {
    bash -c 'source "$1" && configure_keyboard_layouts' _ "$SCRIPT"
}

sources() { cat "$GS_DIR/org.gnome.desktop.input-sources.sources"; }
keys() { cat "$GS_DIR/org.gnome.desktop.wm.keybindings.switch-input-source"; }

@test "empty sources become us then br" {
    run configure
    [ "$status" -eq 0 ]
    [ "$(sources)" = "[('xkb', 'us'), ('xkb', 'br')]" ]
}

@test "existing us+alt-intl stays first and br is appended" {
    echo "[('xkb', 'us+alt-intl')]" > "$GS_DIR/org.gnome.desktop.input-sources.sources"
    run configure
    [ "$status" -eq 0 ]
    [ "$(sources)" = "[('xkb', 'us+alt-intl'), ('xkb', 'br')]" ]
}

@test "br already present is not duplicated" {
    echo "[('xkb', 'br'), ('xkb', 'us')]" > "$GS_DIR/org.gnome.desktop.input-sources.sources"
    run configure
    [ "$status" -eq 0 ]
    [ "$(sources)" = "[('xkb', 'us'), ('xkb', 'br')]" ]
}

@test "user-added extra source survives" {
    echo "[('xkb', 'us'), ('xkb', 'de')]" > "$GS_DIR/org.gnome.desktop.input-sources.sources"
    run configure
    [ "$status" -eq 0 ]
    [ "$(sources)" = "[('xkb', 'us'), ('xkb', 'de'), ('xkb', 'br')]" ]
}

@test "Super+space is added when missing, other keys kept" {
    echo "['XF86Keyboard']" > "$GS_DIR/org.gnome.desktop.wm.keybindings.switch-input-source"
    run configure
    [ "$status" -eq 0 ]
    [ "$(keys)" = "['XF86Keyboard', '<Super>space']" ]
}

@test "Super+space is not duplicated" {
    echo "['<Super>space', 'XF86Keyboard']" > "$GS_DIR/org.gnome.desktop.wm.keybindings.switch-input-source"
    run configure
    [ "$status" -eq 0 ]
    [ "$(keys)" = "['<Super>space', 'XF86Keyboard']" ]
}

@test "read-back mismatch exits non-zero" {
    GS_DROP_SET=1 run configure
    [ "$status" -ne 0 ]
    [[ "$output" == *"read back"* ]]
}

@test "duplicate existing sources collapse to one" {
    echo "[('xkb', 'br'), ('xkb', 'us+alt-intl'), ('xkb', 'br'), ('xkb', 'us+alt-intl')]" \
        > "$GS_DIR/org.gnome.desktop.input-sources.sources"
    run configure
    [ "$status" -eq 0 ]
    [ "$(sources)" = "[('xkb', 'us+alt-intl'), ('xkb', 'br')]" ]
}
