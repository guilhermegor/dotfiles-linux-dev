#!/bin/bash

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

readonly INPUT_SCHEMA="org.gnome.desktop.input-sources"
readonly KEYBIND_SCHEMA="org.gnome.desktop.wm.keybindings"

# Print every match of an ERE in a GVariant list, one per line.
gv_items() {
    local pattern="$1"
    local text="$2"

    grep -oE "$pattern" <<< "$text" || true
}

# Merge into the current sources: the first en-US entry (any us variant, e.g.
# us+alt-intl) goes first, ('xkb', 'br') is appended when missing, and every
# other entry survives unchanged and unduplicated.
merge_input_sources() {
    local current="$1"
    local entry
    local us_entry=""
    local has_br=0
    local -a rest=()
    local us_re="^\('xkb', 'us(\+[^']*)?'\)$"

    while IFS= read -r entry; do
        if [[ -z "$us_entry" && "$entry" =~ $us_re ]]; then
            us_entry="$entry"
            continue
        fi
        [[ "$entry" == "('xkb', 'br')" ]] && has_br=1
        rest+=("$entry")
    done < <(gv_items "\('[^']*', '[^']*'\)" "$current")

    [[ -z "$us_entry" ]] && us_entry="('xkb', 'us')"
    [[ $has_br -eq 0 ]] && rest+=("('xkb', 'br')")

    local joined="$us_entry"
    for entry in "${rest[@]}"; do
        joined+=", $entry"
    done
    printf '[%s]' "$joined"
}

# Append <Super>space unless already bound; other bindings are kept.
merge_switch_keys() {
    local current="$1"
    local key
    local joined=""
    local found=0

    while IFS= read -r key; do
        [[ "$key" == "'<Super>space'" ]] && found=1
        joined+="${joined:+, }$key"
    done < <(gv_items "'[^']*'" "$current")

    [[ $found -eq 0 ]] && joined+="${joined:+, }'<Super>space'"
    printf '[%s]' "$joined"
}

# Set a gsettings key, read it back, fail on any mismatch.
gsettings_set_verified() {
    local schema="$1"
    local key="$2"
    local want="$3"
    local got

    if ! gsettings set "$schema" "$key" "$want"; then
        print_status "error" "gsettings set $schema $key failed"
        return 1
    fi
    got=$(gsettings get "$schema" "$key")
    if [[ "$got" != "$want" ]]; then
        print_status "error" "$key read back as '$got', expected '$want'"
        return 1
    fi
}

configure_keyboard_layouts() {
    print_status "info" "Configuring keyboard layouts..."

    local current
    local layouts
    current=$(gsettings get "$INPUT_SCHEMA" sources) || return 1
    layouts=$(merge_input_sources "$current")
    gsettings_set_verified "$INPUT_SCHEMA" sources "$layouts" || return 1
    print_status "success" "Input sources: $layouts"
    print_status "config" "English (US) first, Portuguese (Brazil, ABNT2) = xkb 'br'"

    local keys_current
    local keys
    keys_current=$(gsettings get "$KEYBIND_SCHEMA" switch-input-source) || return 1
    keys=$(merge_switch_keys "$keys_current")
    gsettings_set_verified "$KEYBIND_SCHEMA" switch-input-source "$keys" || return 1
    print_status "success" "switch-input-source: $keys"
}

configure_cedilla() {
    print_status "info" "Configuring cedilla support..."

    if [ ! -f /etc/environment ]; then
        sudo touch /etc/environment
        print_status "config" "Created new /etc/environment file"
    elif [ ! -f /etc/environment.bak ]; then
        sudo cp /etc/environment /etc/environment.bak
        print_status "config" "Created backup at /etc/environment.bak"
    fi

    if grep -q "GTK_IM_MODULE=cedilla" /etc/environment && grep -q "QT_IM_MODULE=cedilla" /etc/environment; then
        print_status "success" "Cedilla configuration already exists"
    else
        printf '\n# Cedilla fix configuration\nGTK_IM_MODULE=cedilla\nQT_IM_MODULE=cedilla\n' \
            | sudo tee -a /etc/environment > /dev/null
        print_status "success" "Added cedilla configuration to /etc/environment"
    fi
}

configure_us_cedilla() {
    print_status "info" "Configuring US English layout with cedilla support..."

    local gtk_compose_dir="$HOME/.config/gtk-3.0"
    local gtk_compose_file="$gtk_compose_dir/Compose"

    mkdir -p "$gtk_compose_dir"

    if cat > "$gtk_compose_file" << 'EOF'
# Custom Compose sequences for cedilla in US layout
include "%L"

# Cedilla support for US keyboard
<dead_acute> <C> : "Ç" Ccedilla
<dead_acute> <c> : "ç" ccedilla
<apostrophe> <C> : "Ç" Ccedilla
<apostrophe> <c> : "ç" ccedilla
EOF
    then
        print_status "success" "Created GTK Compose file for cedilla support"
    else
        print_status "error" "Failed to create GTK Compose file"
        return 1
    fi

    if command -v ibus &> /dev/null; then
        print_status "info" "Configuring IBus for cedilla support..."
        gsettings set org.freedesktop.ibus.general use-system-keyboard-layout true 2> /dev/null || true
        print_status "success" "IBus configured for cedilla support"
    fi
}

verify_configuration() {
    print_status "info" "Verifying configuration..."

    local current_layouts
    current_layouts=$(gsettings get "$INPUT_SCHEMA" sources)
    print_status "config" "Current keyboard layouts: $current_layouts"

    if [ -f /etc/environment ]; then
        print_status "config" "Environment file contents:"
        grep -E "GTK_IM_MODULE|QT_IM_MODULE" /etc/environment | while read -r line; do
            print_status "config" "  $line"
        done
    fi

    if [ -f "$HOME/.config/gtk-3.0/Compose" ]; then
        print_status "success" "GTK Compose file exists"
    else
        print_status "warning" "GTK Compose file not found"
    fi
}

main() {
    print_status "section" "Ubuntu Keyboard Configuration"

    if ! configure_keyboard_layouts; then
        print_status "error" "Configuration encountered errors"
        return 1
    fi
    configure_cedilla
    configure_us_cedilla || return 1
    verify_configuration

    print_status "success" "Configuration completed successfully!"
    print_status "info" "Next steps:"
    print_status "config" "1. Log out and log back in for changes to take full effect"
    print_status "config" "2. Super+Space switches between English (US) and Portuguese (Brazil)"
    print_status "config" "3. In US English layout, use ' + c to type ç (cedilla)"
    print_status "config" "4. You can also use Right Alt (AltGr) + , + c in some contexts"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
