#!/bin/bash

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# Slots custom0..custom<N-1> are owned by this script; keep in sync with the
# set_individual_keybinding calls (tests/custom_shortcuts_slots.bats enforces it).
MANAGED_SLOT_COUNT=15

# function to check if a keybinding conflicts with a GNOME default binding.
# Custom bindings are skipped — this script fully owns and overwrites that
# array, so existing custom slots are never real conflicts.
keybinding_exists() {
    local binding="$1"

    local default_bindings
    default_bindings=$(gsettings list-recursively org.gnome.settings-daemon.plugins.media-keys \
        | grep -v "custom-keybindings")

    while read -r line; do
        if [[ "$line" == *"'$binding'"* ]]; then
            echo "Conflict found in default keybinding: $line"
            return 0
        fi
    done <<< "$default_bindings"

    return 1
}

# function to verify keybindings
verify_keybindings() {
    local bindings=("$@")
    local conflict_found=0
    
    print_status info "Verifying keybindings for conflicts..."
    
    for binding in "${bindings[@]}"; do
        if keybinding_exists "$binding"; then
            print_status error "Conflict detected! The keybinding '$binding' is already in use."
            conflict_found=1
        else
            print_status success "Keybinding '$binding' is available."
        fi
    done
    
    if [ $conflict_found -eq 1 ]; then
        print_status error "\nWarning: One or more keybinding conflicts detected!"
        read -p "Do you want to continue anyway? [y/N] " -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_status error "Aborting due to keybinding conflicts."
            exit 1
        fi
    else
        print_status success "\nAll keybindings are available. No conflicts detected."
    fi
}

# function to set the custom keybindings array
set_keybindings_array() {
    print_status info "Setting up custom keybindings array..."
    gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings \
    "['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/', \
    '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom1/', \
    '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom2/', \
    '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom3/', \
    '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom4/', \
    '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom5/', \
    '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom6/', \
    '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom7/', \
    '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom8/', \
    '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom9/', \
    '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom10/', \
    '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom11/', \
    '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom12/', \
    '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom13/', \
    '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom14/']"
}

# function to set individual keybindings
set_individual_keybinding() {
    local index="$1"
    local name="$2"
    local command="$3"
    local binding="$4"
    
    print_status warning "Setting up keybinding $index: $name..."
    gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom${index}/ name "$name"
    gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom${index}/ command "$command"
    gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom${index}/ binding "$binding"
}

# function to blank the binding of every managed slot before reassigning.
# gsd-media-keys refuses a grab while another slot still holds the accelerator
# and never retries (dotfiles-linux-dev#653), so no binding may be held twice
# mid-run; writing an identical value also emits no change, so blank first to
# force a real change event (and a fresh grab) on every slot.
clear_managed_bindings() {
    local i
    print_status info "Clearing bindings of managed slots so gsd re-grabs them..."
    for ((i = 0; i < MANAGED_SLOT_COUNT; i++)); do
        gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom${i}/" binding ""
    done
}

# function to create the copy-path script
create_copy_path_script() {
    local script_path="$HOME/.local/bin/copy-path.sh"
    local nautilus_scripts_dir="$HOME/.local/share/nautilus/scripts"
    local symlink_path="$nautilus_scripts_dir/Copy Path"

    print_status info "Creating enhanced copy-path script at $script_path..."
    
    mkdir -p "$HOME/.local/bin"
    mkdir -p "$nautilus_scripts_dir"
    
    cat > "$script_path" << 'EOF'
#!/bin/bash

# Enhanced file path copier with paste support
# Can be called from Nautilus or as a standalone command

# If we have paths from Nautilus (right-click in Nautilus)
if [ -n "$NAUTILUS_SCRIPT_SELECTED_FILE_PATHS" ]; then
    # Clean and copy the paths
    cleaned_paths=$(echo "$NAUTILUS_SCRIPT_SELECTED_FILE_PATHS" | sed "s/'/\\'/g" | tr '\n' ' ')
    echo -n "$cleaned_paths" | xclip -selection clipboard
    echo -n "$cleaned_paths" > /tmp/last_copied_paths
    notify-send "Path(s) copied to clipboard:" "$cleaned_paths"
    
# If we're called with --paste argument (from keybinding)
elif [ "$1" = "--paste" ]; then
    if [ -f /tmp/last_copied_paths ]; then
        # Get the current clipboard content to restore later
        current_clip=$(xclip -o -selection clipboard 2>/dev/null)
        
        # Put the paths back in clipboard
        cat /tmp/last_copied_paths | xclip -selection clipboard
        
        # Give time for clipboard to update
        sleep 0.3
        
        # Paste using Ctrl+V (more reliable than typing)
        xdotool key --clearmodifiers ctrl+v
        
        # Restore original clipboard content after a delay
        (sleep 1; echo -n "$current_clip" | xclip -selection clipboard) &
    else
        notify-send "No paths to paste" "Copy some files first with Ctrl+Shift+C"
    fi
EOF

    chmod +x "$script_path"
    
    # Create symlink in Nautilus scripts directory
    ln -sf "$script_path" "$symlink_path"
    
    print_status success "Enhanced copy-path script created successfully!"
    print_status success "Nautilus integration set up automatically!"
}

# function to install the external SSD backup script to ~/.local/bin
create_backup_script() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local src_script="$script_dir/../storage/backup_external_ssd.sh"
    local dest_script="$HOME/.local/bin/backup-external-ssd.sh"

    print_status info "Installing backup-external-ssd.sh to $dest_script..."

    mkdir -p "$HOME/.local/bin"

    if [ ! -f "$src_script" ]; then
        print_status error "Source script not found: $src_script"
        return 1
    fi

    cp "$src_script" "$dest_script"
    chmod +x "$dest_script"

    print_status success "Backup script installed at $dest_script"
}

# function to install backup-env.sh to ~/.local/bin
create_backup_env_script() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local src_script="$script_dir/../storage/backup_env.sh"
    local dest_script="$HOME/.local/bin/backup-env.sh"

    print_status info "Installing backup-env.sh to $dest_script..."
    mkdir -p "$HOME/.local/bin"

    if [ ! -f "$src_script" ]; then
        print_status error "Source script not found: $src_script"
        return 1
    fi

    cp "$src_script" "$dest_script"
    chmod +x "$dest_script"
    print_status success "backup-env.sh installed at $dest_script"
}

# function to install export-memory.sh to ~/.local/bin
create_export_memory_script() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local src_script="$script_dir/../storage/export_memory.sh"
    local dest_script="$HOME/.local/bin/export-memory.sh"

    print_status info "Installing export-memory.sh to $dest_script..."
    mkdir -p "$HOME/.local/bin"

    if [ ! -f "$src_script" ]; then
        print_status error "Source script not found: $src_script"
        return 1
    fi

    cp "$src_script" "$dest_script"
    chmod +x "$dest_script"
    print_status success "export-memory.sh installed at $dest_script"
}

# function to install restore-env.sh to ~/.local/bin
create_restore_env_script() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local src_script="$script_dir/../storage/restore_env.sh"
    local dest_script="$HOME/.local/bin/restore-env.sh"

    print_status info "Installing restore-env.sh to $dest_script..."
    mkdir -p "$HOME/.local/bin"

    if [ ! -f "$src_script" ]; then
        print_status error "Source script not found: $src_script"
        return 1
    fi

    cp "$src_script" "$dest_script"
    chmod +x "$dest_script"
    print_status success "restore-env.sh installed at $dest_script"
}

# function to install restore-memory.sh to ~/.local/bin
create_restore_memory_script() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local src_script="$script_dir/../storage/restore_memory.sh"
    local dest_script="$HOME/.local/bin/restore-memory.sh"

    print_status info "Installing restore-memory.sh to $dest_script..."
    mkdir -p "$HOME/.local/bin"

    if [ ! -f "$src_script" ]; then
        print_status error "Source script not found: $src_script"
        return 1
    fi

    cp "$src_script" "$dest_script"
    chmod +x "$dest_script"
    print_status success "restore-memory.sh installed at $dest_script"
}

# function to create the show-shortcuts rofi popup script
create_show_shortcuts_script() {
    local script_path="$HOME/.local/bin/show-shortcuts.sh"

    print_status info "Creating show-shortcuts.sh at $script_path..."
    mkdir -p "$HOME/.local/bin"

    cat > "$script_path" << 'EOF'
#!/bin/bash

# Rofi shortcut cheat-sheet
# Shows curated GNOME system shortcuts and all custom dconf bindings.
# Selecting an entry shows its description via notify-send.

build_system_entries() {
    local -a entries=(
        "HEADER:── Window Management ──────────────────────────"
        "Super+Up|Maximise Window|Expands the focused window to fill the screen"
        "Super+Down|Restore Window|Restores a maximised window to its previous size"
        "Super+Left|Tile Left|Snaps the focused window to the left half of the screen"
        "Super+Right|Tile Right|Snaps the focused window to the right half of the screen"
        "Alt+F4|Close Window|Closes the focused window"
        "Super+H|Hide Window|Minimises the focused window"
        "Alt+F7|Move Window|Move the window using the keyboard arrow keys"
        "Alt+F8|Resize Window|Resize the window using the keyboard arrow keys"
        "HEADER:── Workspaces ────────────────────────────────"
        "Super+1|Workspace 1|Switch to workspace 1"
        "Super+2|Workspace 2|Switch to workspace 2"
        "Super+3|Workspace 3|Switch to workspace 3"
        "Super+4|Workspace 4|Switch to workspace 4"
        "Super+Shift+1|Move to Workspace 1|Move the current window to workspace 1"
        "Super+Shift+2|Move to Workspace 2|Move the current window to workspace 2"
        "Super+Shift+3|Move to Workspace 3|Move the current window to workspace 3"
        "Super+Shift+4|Move to Workspace 4|Move the current window to workspace 4"
        "Ctrl+Alt+Left|Previous Workspace|Switch to the previous workspace"
        "Ctrl+Alt+Right|Next Workspace|Switch to the next workspace"
        "HEADER:── Screenshots ───────────────────────────────"
        "Print|Screenshot Desktop|Capture the entire desktop"
        "Shift+Print|Screenshot Area|Select a screen region to capture"
        "Alt+Print|Screenshot Window|Capture only the active window"
        "HEADER:── System & Navigation ───────────────────────"
        "Super|Activities Overview|Open the Activities overview"
        "Super+A|App Grid|Open the application grid"
        "Super+L|Lock Screen|Lock the screen immediately"
        "Alt+F2|Run Dialog|Open the run command dialog"
        "Super+Tab|Switch Apps|Cycle through running applications"
        "Alt+Tab|Switch Windows|Cycle through open windows"
        "Ctrl+Alt+T|Terminal|Open a terminal window"
    )

    for entry in "${entries[@]}"; do
        if [[ "$entry" == HEADER:* ]]; then
            printf '%s\0nonselectable\x1ftrue\n' "${entry#HEADER:}"
        else
            IFS='|' read -r binding name desc <<< "$entry"
            printf '  %-24s │  %s\0info\x1f%s\n' "$binding" "$name" "$desc"
        fi
    done
}

build_custom_entries() {
    local raw_paths
    raw_paths=$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings \
        2>/dev/null | tr -d "[]' " | tr ',' '\n' | grep -v '^$')

    [ -z "$raw_paths" ] && return

    while IFS= read -r path; do
        local name binding command
        name=$(gsettings get \
            "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${path}" \
            name 2>/dev/null | tr -d "'")
        binding=$(gsettings get \
            "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${path}" \
            binding 2>/dev/null | tr -d "'")
        command=$(gsettings get \
            "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${path}" \
            command 2>/dev/null | tr -d "'")

        [ -z "$name" ] && continue

        local readable_binding
        readable_binding=$(echo "$binding" \
            | sed 's/<Super>/Super+/g; s/<Ctrl>/Ctrl+/g; s/<Shift>/Shift+/g; s/<Alt>/Alt+/g' \
            | sed 's/+$//')

        printf '  %-24s │  %s\0info\x1f%s\n' "$readable_binding" "$name" "$command"
    done <<< "$raw_paths"
}

main() {
    if ! command -v rofi &>/dev/null; then
        notify-send "Missing dependency" "Please install rofi: sudo apt install rofi"
        exit 1
    fi

    local description
    description=$(
        {
            printf '── System Shortcuts ─────────────────────────────\0nonselectable\x1ftrue\n'
            build_system_entries
            printf ' \0nonselectable\x1ftrue\n'
            printf '── Custom Shortcuts ─────────────────────────────\0nonselectable\x1ftrue\n'
            build_custom_entries
        } | rofi -dmenu -i \
                 -p " Shortcuts" \
                 -format 'i' \
                 -theme-str 'window {width: 780px;} listview {lines: 22;}' \
                 -no-custom
    )

    [ -n "$description" ] && [ "$description" != " " ] && \
        notify-send --expire-time=6000 "Shortcut Info" "$description"
}

main
EOF

    chmod +x "$script_path"
    print_status success "show-shortcuts.sh created successfully!"
}

# function to add claudestatus shell aliases to ~/.bashrc
create_claudestatus_aliases() {
    local marker="# claudestatus shortcuts"
    if grep -q "$marker" ~/.bashrc 2>/dev/null; then
        print_status success "claudestatus aliases already present in ~/.bashrc"
        return 0
    fi

    print_status info "Adding claudestatus aliases to ~/.bashrc..."
    {
        printf '\n'
        printf '# claudestatus shortcuts\n'
        printf 'alias cs='"'"'claudestatus'"'"'           # usage dashboard\n'
        printf 'alias cs-quick='"'"'claudestatus --quick'"'"'  # quick recommendation\n'
        printf 'alias cs-add='"'"'claudestatus add'"'"'   # add account: cs-add <alias>\n'
    } >> ~/.bashrc
    print_status success "claudestatus aliases added to ~/.bashrc"
    print_status warning "  cs            → show usage dashboard"
    print_status warning "  cs-quick      → quick account recommendation"
    print_status warning "  cs-add <name> → add account (e.g. work, personal_1, personal_2)"
}

# function to create the claudestatus dashboard launcher script
create_claudestatus_dashboard_script() {
    local script_path="$HOME/.local/bin/claudestatus-dashboard.sh"
    print_status info "Creating claudestatus-dashboard.sh at $script_path..."
    mkdir -p "$HOME/.local/bin"
    
    cat > "$script_path" << 'EOF'
#!/bin/bash
# Open the claudestatus usage dashboard + current auth status in a terminal window.
# Uses bash -i so ~/.bashrc is sourced (npm global bin in PATH).
# Falls back through gnome-terminal → xterm → notify-send.

cmd='
echo "=== Claude Authentication Status ==="
claude auth status --text
echo
echo "=== Claudestatus Dashboard ==="
claudestatus
echo
echo "=================================="
read -rp "Press Enter to close..."
'

if command -v gnome-terminal &>/dev/null; then
    gnome-terminal --maximize -- bash -ic "$cmd"
elif command -v xterm &>/dev/null; then
    xterm -maximized -e bash -ic "$cmd"
else
    notify-send "claudestatus" \
        "No terminal emulator found. Run 'claudestatus' manually in a terminal."
fi
EOF

    chmod +x "$script_path"
    print_status success "claudestatus-dashboard.sh created successfully!"
}

# Modified main function to set up all keybindings 
set_all_keybindings() {
    print_status success "Configuring GNOME custom keybindings..."
    
    # Define the keybindings we'll be using
    local bindings=("<Super>e" "<Super>r" "<Super>t" "<Super><Ctrl>s" "<Ctrl><Shift>c" "<Ctrl><Shift>v" "<Ctrl><Shift>Escape" "<Super>c" "<Super>b" "<Super>j" "<Super><Shift>e" "<Super><Shift>m" "<Super><Alt>e" "<Super><Alt>m" "<Super><Shift>u")
    
    # Ask user if they want to verify conflicts
    read -p "Do you want to verify for shortcut conflicts before proceeding? [Y/n] " -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
        verify_keybindings "${bindings[@]}"
    fi
    
    # Set up claudestatus shell aliases and dashboard launcher
    create_claudestatus_aliases
    create_claudestatus_dashboard_script

    # Create the enhanced copy-path script and set up Nautilus integration
    create_copy_path_script
    
    # Create the backup script and install to ~/.local/bin
    create_backup_script
    create_backup_env_script
    create_export_memory_script
    create_restore_env_script
    create_restore_memory_script
    create_show_shortcuts_script

    # custom15 was the last slot before the Super+K Kill Insync binding was removed
    # and 7..15 renumbered down; an earlier run left it bound in dconf, so reset it.
    dconf reset -f /org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom15/

    clear_managed_bindings
    set_keybindings_array

    # Set individual keybindings
    set_individual_keybinding 0 "Open File Manager" "nautilus --new-window" "<Super>e"
    set_individual_keybinding 1 "Restart PC" "systemctl reboot" "<Super>r"
    set_individual_keybinding 2 "Shutdown PC" "systemctl poweroff" "<Super>t"
    set_individual_keybinding 3 "Open Settings" "gnome-control-center" "<Super><Ctrl>s"
    set_individual_keybinding 4 "Copy File Path" "$HOME/.local/bin/copy-path.sh" "<Ctrl><Shift>c"
    set_individual_keybinding 5 "Paste File Path" "$HOME/.local/bin/copy-path.sh --paste" "<Ctrl><Shift>v"
    set_individual_keybinding 6 "Gerenciador de Tarefas" "flatpak run io.missioncenter.MissionCenter" "<Ctrl><Shift>Escape"
    set_individual_keybinding 7 "Open Characters" "gnome-characters" "<Super>c"
    set_individual_keybinding 8 "Backup External SSDs" "$HOME/.local/bin/backup-external-ssd.sh" "<Super>b"
    set_individual_keybinding 9 "Show All Shortcuts" "$HOME/.local/bin/show-shortcuts.sh" "<Super>j"
    set_individual_keybinding 10 "Backup Env Files" "$HOME/.local/bin/backup-env.sh" "<Super><Shift>e"
    set_individual_keybinding 11 "Export Claude Memory" "$HOME/.local/bin/export-memory.sh" "<Super><Shift>m"
    set_individual_keybinding 12 "Restore Env Files" "$HOME/.local/bin/restore-env.sh" "<Super><Alt>e"
    set_individual_keybinding 13 "Restore Claude Memory" "$HOME/.local/bin/restore-memory.sh" "<Super><Alt>m"
    set_individual_keybinding 14 "Claude Usage Dashboard" "$HOME/.local/bin/claudestatus-dashboard.sh" "<Super><Shift>u"

    print_status success "All keybindings have been configured successfully!"
    print_status warning "You can now use:"
    print_status warning "  - Ctrl+Shift+C in Nautilus to copy file paths"
    print_status warning "  - Ctrl+Shift+V anywhere to paste the paths"
    print_status warning "  - Ctrl+Shift+Esc to open Task Manager"
    print_status warning "  - Super+C to open GNOME Characters"
    print_status warning "  - Super+B to back up external SSDs to the BKP cloud-sync drive"
    print_status warning "  - Super+J to open the shortcut cheat-sheet (rofi popup)"
    print_status warning "  - Super+Shift+E to back up .env files from all ~/github repos"
    print_status warning "  - Super+Shift+M to export Claude Code memory to backup"
    print_status warning "  - Super+Alt+E to restore .env files from backup"
    print_status warning "  - Super+Alt+M to restore Claude Code memory from backup"
    print_status warning "  - Super+Shift+U to open the Claude usage dashboard (claudestatus)"
    print_status warning "Shell aliases added to ~/.bashrc (reload with: source ~/.bashrc):"
    print_status warning "  - cs            → claudestatus (usage dashboard)"
    print_status warning "  - cs-quick      → claudestatus --quick"
    print_status warning "  - cs-add <name> → claudestatus add <name>"
    print_status warning "    e.g.: cs-add work | cs-add personal_1 | cs-add personal_2"
}

# execute the main function
set_all_keybindings