#!/bin/bash
#
# distro_config/ubuntu_workspace.sh
#
# GNOME workspace, dock, theme, keybindings, and app-folder organisation.
#
# App-folder organisation (`organize_app_folders` below) draws from THREE sources:
#   1. Static `<folder>_app_names` arrays inside this script — covers pre-installed
#      system apps (gnome-control-center, gnome-system-monitor, etc.) that no installer
#      script manages.
#   2. INSTALL_REGISTRY — sourced from install_lib/ and install_coding_lib/ so any
#      app declared with a `gnome_folder` field automatically gets placed.
#      This eliminates the previous drift where install_<foo>() and the folder
#      arrays had to be kept in sync by hand.
#   3. Filename globs inside each folder block (`*viewer*`, `org.gnome.*`, …) —
#      convenience catch-alls for apps neither of the above names explicitly.
#
# These three sources can disagree about where an app belongs — none of them
# can see what the other two are about to add — and an app can end up in two
# folders at once (#391). The tie-break: Utilities (`Utilitarios`) is the
# fallback folder and loses to any other folder that also claims an id; a
# folder's glob or hardcoded list must explicitly exclude an id another
# folder already owns rather than relying on `sort -u` (that only dedupes
# entries *within* one folder's array, never across folders).
#
# Source 1 and source 2 legitimately overlap for the SAME folder: an app
# with an installer function is both hand-listed (for machines that predate
# its INSTALL_REGISTRY entry) and registry-declared. That overlap is
# harmless (each folder's array is `sort -u`'d) and is not cleaned up here —
# the registry's `gnome_folder` is the authoritative source for anything
# with an install function; the hand-written arrays exist only for apps NO
# install function manages. `tests/gnome_folder_registry_invariant.bats`
# guards the case that matters (an id claimed by two DIFFERENT folders),
# not this same-folder redundancy.

# ----------------------------------------------------------------------------
# Source shared utilities (print_status, color vars, command_exists, …) from
# repo-root lib/common.sh.
# ----------------------------------------------------------------------------

_uw_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$_uw_script_dir/../lib/common.sh"

# ----------------------------------------------------------------------------
# Populate INSTALL_REGISTRY from install_lib + install_coding_lib.
# Sourcing each *.sh only appends to INSTALL_REGISTRY (the install_*() function
# bodies are defined but never invoked here), so no external dependencies run.
# ----------------------------------------------------------------------------

INSTALL_REGISTRY=()
shopt -s nullglob
for _uw_lib in "$_uw_script_dir/install_lib/"[!_]*.sh "$_uw_script_dir/install_coding_lib/"[!_]*.sh; do
    # shellcheck source=/dev/null
    source "$_uw_lib" 2>/dev/null || true
done
shopt -u nullglob
unset _uw_script_dir _uw_lib

configure_terminal() {
    print_status "info" "Configuring terminal profile..."
    
    # get default profile ID
    local profile_id
    profile_id=$(gsettings get org.gnome.Terminal.ProfilesList default)
    profile_id=${profile_id:1:-1} # remove single quotes
    
    # configure terminal appearance
    run_or_echo gsettings set org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:${profile_id}/ use-theme-colors false
    run_or_echo gsettings set org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:${profile_id}/ palette "['rgb(46,52,54)', 'rgb(204,0,0)', 'rgb(78,154,6)', 'rgb(196,160,0)', 'rgb(52,101,164)', 'rgb(117,80,123)', 'rgb(6,152,154)', 'rgb(211,215,207)', 'rgb(85,87,83)', 'rgb(239,41,41)', 'rgb(138,226,52)', 'rgb(252,233,79)', 'rgb(114,159,207)', 'rgb(173,127,168)', 'rgb(52,226,226)', 'rgb(238,238,236)']"
    run_or_echo gsettings set org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:${profile_id}/ background-color 'rgb(46,52,54)'
    run_or_echo gsettings set org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:${profile_id}/ foreground-color 'rgb(238,238,236)'
    run_or_echo gsettings set org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:${profile_id}/ bold-color-same-as-fg true
    run_or_echo gsettings set org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:${profile_id}/ bold-color 'rgb(238,238,236)'
    
    print_status "success" "Terminal configured with Tango Dark theme"
}

set_dark_mode() {
    print_status "info" "Configuring dark mode..."
    run_or_echo gsettings set org.gnome.desktop.interface gtk-theme 'Yaru-dark'
    run_or_echo gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
    print_status "success" "Dark mode configured"
}

set_dock_icon_size() {
    print_status "info" "Setting dock icon size to 48..."
    run_or_echo gsettings set org.gnome.shell.extensions.dash-to-dock dash-max-icon-size 48
    print_status "success" "Dock icon size set to 48"
}

set_dock_position_bottom() {
    print_status "info" "Setting dock position to bottom..."
    run_or_echo gsettings set org.gnome.shell.extensions.dash-to-dock dock-position 'BOTTOM'
    print_status "success" "Dock position set to BOTTOM"
}

set_workspaces_all_displays() {
    print_status "info" "Configuring workspaces for all displays..."
    run_or_echo gsettings set org.gnome.mutter workspaces-only-on-primary false

    # Check if the schema exists before trying to set it
    if gsettings list-schemas | grep -q "org.gnome.shell.overrides"; then
        run_or_echo gsettings set org.gnome.shell.overrides workspaces-only-on-primary false
    else
        print_status "warning" "org.gnome.shell.overrides schema not available - skipping"
    fi

    print_status "success" "Workspaces configured for all displays"
}

set_workspace_app_isolation() {
    print_status "info" "Configurando alternador de aplicativos para mostrar apenas apps do espaço de trabalho atual..."
    
    # This setting makes Alt+Tab show only applications from the current workspace
    run_or_echo gsettings set org.gnome.shell.app-switcher current-workspace-only true
    
    # Alternative setting for some GNOME versions
    if gsettings list-schemas | grep -q "org.gnome.shell.window-switcher"; then
        run_or_echo gsettings set org.gnome.shell.window-switcher current-workspace-only true
    fi
    
    local CURRENT_SETTING
    CURRENT_SETTING=$(gsettings get org.gnome.shell.app-switcher current-workspace-only)
    print_status "success" "Alternador de aplicativos configurado para espaço de trabalho atual: $CURRENT_SETTING"
}

configure_mouse() {
    print_status "info" "Configuring mouse settings..."
    
    # Set mouse speed (velocity) - middle value similar to the screenshot
    run_or_echo gsettings set org.gnome.desktop.peripherals.mouse speed 0.0
    
    # Enable mouse acceleration (default profile)
    run_or_echo gsettings set org.gnome.desktop.peripherals.mouse accel-profile 'default'
    
    # Enable natural scrolling
    run_or_echo gsettings set org.gnome.desktop.peripherals.mouse natural-scroll true
    
    local MOUSE_SPEED
    MOUSE_SPEED=$(gsettings get org.gnome.desktop.peripherals.mouse speed)
    local ACCEL_PROFILE
    ACCEL_PROFILE=$(gsettings get org.gnome.desktop.peripherals.mouse accel-profile)
    local NATURAL_SCROLL
    NATURAL_SCROLL=$(gsettings get org.gnome.desktop.peripherals.mouse natural-scroll)
    
    print_status "success" "Mouse configured:"
    print_status "config" "  Speed: $MOUSE_SPEED"
    print_status "config" "  Acceleration: $ACCEL_PROFILE"
    print_status "config" "  Natural scrolling: $NATURAL_SCROLL"
}

# Merge a gsettings favorite-apps live value into a declared-favorites array,
# by reference, so hand-pinned apps survive a `gsettings set` (which replaces
# the key wholesale). Declared apps keep their order; any existing app not
# already covered is appended, preserving its relative order among itself —
# UNLESS it appears in the unpin list (#392), in which case it is dropped
# instead of re-appended.
# $1: name of the array variable to merge into (nameref)
# $2: raw `gsettings get org.gnome.shell favorite-apps` output, e.g.
#     "['org.gnome.Nautilus.desktop', 'spotify.desktop']"
# $3: (optional) name of an array variable listing quoted ids to skip when
#     merging (nameref), e.g. DOCK_UNPINNED. Omit for "merge everything".
_merge_dock_favorites() {
    local -n _merge_declared="$1"
    local existing_str="$2"
    local -a _merge_no_unpin=()
    local -n _merge_unpinned="${3:-_merge_no_unpin}"
    local -a existing=()
    if [ -n "$existing_str" ]; then
        mapfile -t existing < <(grep -oE "'[^']+'" <<< "$existing_str")
    fi
    local item
    for item in "${existing[@]}"; do
        if [[ " ${_merge_unpinned[*]} " == *" ${item} "* ]]; then
            continue
        fi
        if [[ ! " ${_merge_declared[*]} " == *" ${item} "* ]]; then
            _merge_declared+=("$item")
        fi
    done
}

configure_dock() {
    print_status "info" "Configuring dock..."
    
    # First check if dash-to-dock is installed
    if ! gsettings list-schemas | grep -q org.gnome.shell.extensions.dash-to-dock; then
        print_status "warning" "Dash-to-dock extension not found. Installing..."
        sudo apt install -y gnome-shell-extension-dash-to-dock
        # Restart GNOME Shell to activate
        busctl --user call org.gnome.Shell /org/gnome/Shell org.gnome.Shell Eval s 'Meta.restart("Restarting GNOME Shell...")'
        sleep 3 # Wait for restart
    fi
    
    # Dock position and behavior
    run_or_echo gsettings set org.gnome.shell.extensions.dash-to-dock extend-height false
    set_dock_position_bottom
    set_dock_icon_size
    run_or_echo gsettings set org.gnome.shell.extensions.dash-to-dock background-opacity 0.7
    run_or_echo gsettings set org.gnome.shell.extensions.dash-to-dock transparency-mode 'FIXED'
    
    # Disable showing volumes and devices in dock
    print_status "info" "Disabling volumes and devices in dock..."
    run_or_echo gsettings set org.gnome.shell.extensions.dash-to-dock show-mounts false
    
    print_status "info" "Configuring dock auto-hide..."
    run_or_echo gsettings set org.gnome.shell.extensions.dash-to-dock autohide true
    run_or_echo gsettings set org.gnome.shell.extensions.dash-to-dock intellihide true
    
    # Additional dock hiding settings for better behavior
    run_or_echo gsettings set org.gnome.shell.extensions.dash-to-dock dock-fixed false
    run_or_echo gsettings set org.gnome.shell.extensions.dash-to-dock intellihide-mode 'FOCUS_APPLICATION_WINDOWS'
    
    # Set hide animation speed (in seconds)
    run_or_echo gsettings set org.gnome.shell.extensions.dash-to-dock animation-time 0.2
    run_or_echo gsettings set org.gnome.shell.extensions.dash-to-dock hide-delay 0.2
    run_or_echo gsettings set org.gnome.shell.extensions.dash-to-dock show-delay 0.25
    
    print_status "success" "Dock auto-hide configured"
    
    # Set favorite apps with robust desktop file detection
    print_status "info" "Configuring favorite apps..."
    
    # Function to check if desktop file exists and return the path
    find_desktop_file() {
        local app_name="$1"
        if [ -f "$HOME/.local/share/applications/$app_name" ]; then
            echo "$app_name"
            return 0
        elif [ -f "/usr/share/applications/$app_name" ]; then
            echo "$app_name"
            return 0
        elif [ -f "/var/lib/snapd/desktop/applications/$app_name" ]; then
            echo "$app_name"
            return 0
        elif [ -f "/var/lib/flatpak/exports/share/applications/$app_name" ]; then
            echo "$app_name"
            return 0
        fi
        return 1
    }
    
    # Build favorites list with apps in the specified order
    local favorites=()
    
    # 1. Spotify
    for app in 'spotify_spotify.desktop' 'spotify.desktop'; do
        if result=$(find_desktop_file "$app"); then
            favorites+=("'$result'")
            break
        fi
    done
    
    # SoundCloud is deliberately NOT pinned here — it lives in the Media app
    # folder instead. See DOCK_UNPINNED below.

    # 3. Firefox
    for app in 'firefox_firefox.desktop' 'firefox.desktop'; do
        if result=$(find_desktop_file "$app"); then
            favorites+=("'$result'")
            break
        fi
    done
    
    # Google Chrome is deliberately NOT pinned here (#392) — it lives in the
    # Browsers app folder instead. See DOCK_UNPINNED below.

    # Google Keep is deliberately NOT pinned here — it lives in the Planning
    # app folder instead, via its INSTALL_REGISTRY entry in install_lib/productivity.sh.

    # 5. Notion
    for app in 'notion-snap-reborn_notion-snap-reborn.desktop' 'notion-app_notion-app.desktop' 'notion-app.desktop' 'notion.desktop'; do
        if result=$(find_desktop_file "$app"); then
            favorites+=("'$result'")
            break
        fi
    done
    
    # 6. VS Code
    for app in 'com.microsoft.VSCode.desktop' 'code_code.desktop' 'code.desktop' 'visual-studio-code.desktop'; do
        if result=$(find_desktop_file "$app"); then
            favorites+=("'$result'")
            break
        fi
    done
    
    # 7. Terminal
    for app in 'org.gnome.Terminal.desktop' 'gnome-terminal.desktop'; do
        if result=$(find_desktop_file "$app"); then
            favorites+=("'$result'")
            break
        fi
    done
    
    # Postman and Docker Desktop are deliberately NOT pinned here (#392) —
    # they live in the Data and Infra app folders instead. See DOCK_UNPINNED
    # below.

    # `gsettings set` replaces favorite-apps wholesale, so any app pinned by
    # hand (and not declared above) would otherwise be silently dropped.
    # Merge it back in — declared apps keep their canonical order, hand-pinned
    # extras are appended in their existing relative order (see #103).
    #
    # DOCK_UNPINNED (#392) is a DECLARATION of intent, not a permanent
    # blocklist: it stops these three specific ids from being re-added by the
    # merge above. If the owner pins one of them by hand again, this list
    # will silently unpin it again on the next run — that is the deliberate
    # (if surprising) consequence of stating the removal here instead of
    # deleting the pin once by hand.
    # Passed to _merge_dock_favorites by name (nameref) below, not indexed
    # directly in this scope — shellcheck can't see that usage.
    # shellcheck disable=SC2034
    local -a DOCK_UNPINNED=(
        "'postman_postman.desktop'" "'postman.desktop'" "'Postman.desktop'"
        "'docker-desktop.desktop'" "'docker_docker-desktop.desktop'" "'docker.desktop'"
        "'google-chrome.desktop'" "'chrome.desktop'"
        "'soundcloud.desktop'"
    )
    local current_favorites_str
    current_favorites_str=$(gsettings get org.gnome.shell favorite-apps 2>/dev/null) || current_favorites_str=""
    _merge_dock_favorites favorites "$current_favorites_str" DOCK_UNPINNED

    # Convert array to comma-separated string
    local favorites_str
    favorites_str=$(IFS=,; echo "${favorites[*]}")

    # Set favorites (declared apps + any pre-existing hand-pinned apps)
    run_or_echo gsettings set org.gnome.shell favorite-apps "[${favorites_str}]"

    print_status "success" "Dock configured with ${#favorites[@]} favorite apps"
    print_status "info" "Apps in order: ${favorites_str}"
}

set_ubuntu_ui_interface() {
    print_status "info" "Setting verde-azulado (green-blue) accent color..."
    
    # Set Yaru themes
    run_or_echo gsettings set org.gnome.desktop.interface gtk-theme 'Yaru-viridian-dark'
    run_or_echo gsettings set org.gnome.desktop.interface icon-theme 'Yaru-viridian'
    run_or_echo gsettings set org.gnome.desktop.wm.preferences theme 'Yaru-viridian-dark'
    
    # Also set color scheme to dark
    run_or_echo gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
    
    print_status "success" "Accent color set to verde-azulado (Yaru-viridian)"
}

configure_workspaces() {
    set_workspaces_all_displays
    set_workspace_app_isolation
}

apply_additional_tweaks() {
    print_status "info" "Applying additional tweaks..."
    run_or_echo gsettings set org.gnome.desktop.interface enable-animations true

    # Set clock format to show weekday name and week number
    run_or_echo gsettings set org.gnome.desktop.interface clock-format '24h'
    run_or_echo gsettings set org.gnome.desktop.interface clock-show-weekday true
    run_or_echo gsettings set org.gnome.desktop.interface clock-show-date true
    
    # Try different methods for week number display
    if gsettings list-schemas | grep -q org.gnome.shell.clock; then
        run_or_echo gsettings set org.gnome.shell.clock date-format "'%A %W'"  # shows weekday name and week number
    else
        # Alternative method for newer GNOME versions
        run_or_echo gsettings set org.gnome.desktop.interface clock-show-weekday true
        print_status "warning" "Direct week number display not available - using weekday only"
    fi
    
    # Other tweaks
    run_or_echo gsettings set org.gnome.desktop.background show-desktop-icons true
    run_or_echo gsettings set org.gnome.desktop.wm.preferences button-layout 'appmenu:minimize,maximize,close'

    # Sloppy focus: scroll/interact with the window under the pointer without
    # clicking it first (GNOME ships no dedicated "scroll inactive windows"
    # toggle — sloppy focus is the mechanism). auto-raise must stay false —
    # sloppy focus plus auto-raise true makes windows jump to front as the
    # pointer crosses them, the pairing that gives sloppy focus its bad
    # reputation.
    run_or_echo gsettings set org.gnome.desktop.wm.preferences focus-mode 'sloppy'
    run_or_echo gsettings set org.gnome.desktop.wm.preferences auto-raise false

    print_status "success" "Additional tweaks applied"
}

# Every app-folder id this script has ever produced, derived from the full git
# history of this file:
#     for c in $(git log --format=%H -- distro_config/ubuntu_workspace.sh); do
#       git show $c:distro_config/ubuntu_workspace.sh \
#         | grep -oE "folders/[A-Za-z0-9_-]+/ name" | sed 's|folders/||;s|/ name||'
#     done | sort -u
#
# This allowlist is what makes the reset decidable: "defined in dconf but not in
# folder-children" also catches ids this repo never created — GNOME/distro stock
# folders (Pardus, YaST, Utilities) and anything the user made by hand in the
# Shell. Resetting those would be a sweep of the user's dconf, not a cleanup of
# our own leftovers. Add a row here when an id is retired, never remove one:
# an id drops out of the live set precisely when it becomes the thing to clean.
_HISTORICAL_APP_FOLDER_IDS=(
    AmbienteVirtual Browsers Code Data Design DEV Ereader Infra IRPF Media
    Monitoring Newsletter Office OrgPessoal Planning Reading Seguranca Sharing Sistema
    Social Utilitarios
)

# Reset the relocatable-schema state (name/apps) of any app-folder id that
# THIS run no longer produces. `folder-children` only ever lists ids — it
# never deletes an id's own schema entries, so a dropped id survives in
# dconf carrying its stale name/apps until something re-adds it (#293).
#
# The candidate set is what dconf actually HAS, never what `folder-children`
# lists: an already-orphaned id is by definition absent from `folder-children`,
# so deriving candidates from it can only catch the id on the single run that
# drops it, and never afterwards. That was the gap in the first fix (PR #294) —
# it prevented new orphans while leaving every pre-existing one untouched.
# $1: name of the array holding the ids this run produced (nameref, quoted
#     entries like "'Sistema'", e.g. ordered_folder_ids)
# $2: the CURRENT `folder-children` value, e.g. "['Sistema', 'DEV']"
_reset_orphaned_app_folders() {
    local -n _reset_produced="$1"
    local current_children_str="$2"

    local -a current_ids=()
    if command_exists dconf; then
        mapfile -t current_ids < <(dconf list /org/gnome/desktop/app-folders/folders/ 2>/dev/null \
            | sed "s|/$||; s|^|'|; s|$|'|")
    fi
    # Fall back to folder-children when dconf is unavailable: strictly weaker
    # (transition-only, the PR #294 behaviour) but better than doing nothing.
    if [ ${#current_ids[@]} -eq 0 ] && [ -n "$current_children_str" ]; then
        mapfile -t current_ids < <(grep -oE "'[^']+'" <<< "$current_children_str")
    fi

    local id bare_id path
    for id in "${current_ids[@]}"; do
        # Only ever touch ids this script is known to have created.
        bare_id="${id//\'/}"
        if [[ ! " ${_HISTORICAL_APP_FOLDER_IDS[*]} " == *" ${bare_id} "* ]]; then
            continue
        fi

        # Fail-open: never touch an id this run is actively (re-)creating.
        if [[ " ${_reset_produced[*]} " == *" ${id} "* ]]; then
            continue
        fi

        path="org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/${bare_id}/"

        # Guard strictly to the app-folders relocatable-schema shape —
        # reset-recursively on a wrong path is destructive with no undo.
        if [[ ! "$path" =~ ^org\.gnome\.desktop\.app-folders\.folder:/org/gnome/desktop/app-folders/folders/[A-Za-z0-9_-]+/$ ]]; then
            print_status "warning" "Refusing to reset unexpected folder path: $path"
            continue
        fi

        print_status "info" "Resetting orphaned folder definition: $bare_id"
        run_or_echo gsettings reset-recursively "$path"
    done
}

configure_inactivity_time_lock() {
    print_status "info" "Set inactivity time to lock workspace..."
    run_or_echo gsettings set org.gnome.desktop.session idle-delay 900
    local CURRENT_DELAY
    CURRENT_DELAY=$(gsettings get org.gnome.desktop.session idle-delay)
    print_status "success" "Inactivity time set to $CURRENT_DELAY seconds"
}

configure_power_settings() {
    print_status "info" "Configuring power settings..."
    
    # Set screen blank time to 30 minutes (1800 seconds) when on battery
    run_or_echo gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-timeout 1800
    run_or_echo gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'
    
    local BATTERY_TIMEOUT
    BATTERY_TIMEOUT=$(gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-battery-timeout)
    print_status "success" "Screen will turn off after $BATTERY_TIMEOUT seconds (30 min) on battery"
}

organize_app_folders() {
    print_status "info" "Organizing applications into folders..."
    
    # Function to find desktop file and return just the filename
    find_app_desktop_file() {
        local app_name="$1"
        if [ -f "$HOME/.local/share/applications/$app_name" ]; then
            echo "$app_name"
            return 0
        elif [ -f "/usr/share/applications/$app_name" ]; then
            echo "$app_name"
            return 0
        elif [ -f "/var/lib/snapd/desktop/applications/$app_name" ]; then
            echo "$app_name"
            return 0
        elif [ -f "/var/lib/flatpak/exports/share/applications/$app_name" ]; then
            echo "$app_name"
            return 0
        fi
        return 1
    }

    # Append .desktop filenames from INSTALL_REGISTRY entries whose
    # gnome_folder field matches $1 into the array named by $2.
    # Registry schema: "func:label:gnome_folder:desktop_file"
    _merge_registry_into_folder() {
        local folder_name="$1"
        local -n out_arr="$2"
        local entry fn _label gnome_folder desktop_file derived result
        for entry in "${INSTALL_REGISTRY[@]}"; do
            IFS=':' read -r fn _label gnome_folder desktop_file <<< "$entry"
            [ "$gnome_folder" = "$folder_name" ] || continue
            if [ -n "$desktop_file" ]; then
                derived="$desktop_file"
            else
                derived="${fn#install_}.desktop"
            fi
            if result=$(find_app_desktop_file "$derived"); then
                out_arr+=("'$result'")
            else
                # A declared id that matches no file on disk places nothing, and used to do so in
                # silence: figma sat loose in the app grid for as long as the registry said
                # `figma-linux.desktop` while snap had installed it as
                # `figma-linux_figma-linux.desktop` (snap's `<snap>_<app>.desktop` naming).
                # Not an error — the app may simply not be installed — but it must be visible.
                MISSING_DESKTOP_IDS+=("$derived ($fn -> $folder_name)")
            fi
        done
    }
    
    # Initialize array to store folder IDs
    local folder_ids=()
    local MISSING_DESKTOP_IDS=()
    
    # ==================== SYSTEM FOLDER ====================
    print_status "info" "Creating System folder..."
    local sistema_apps=()
    
    # System applications - common desktop file names
    local system_app_names=(
        # Software/Package Management
        'update-manager.desktop' 'software-properties-gtk.desktop' 'software-properties-drivers.desktop'
        'synaptic.desktop' 'org.gnome.Software.desktop' 'snap-store_ubuntu-software.desktop'
        'io.github.flattool.Warehouse.desktop' 'com.github.tchx84.Flatseal.desktop' 'flatseal.desktop'
        
        # System Settings & Configuration
        'gnome-control-center.desktop' 'unity-control-center.desktop' 'org.gnome.Settings.desktop'
        'gnome-session-properties.desktop' 'gnome-startup-applications.desktop'

        # Hardware & Drivers
        'nvidia-settings.desktop' 'software-properties-drivers.desktop'
        'gnome-firmware-panel.desktop' 'gnome-firmware.desktop' 'firmware-updater.desktop'
        'org.gnome.firmware.desktop' 'org.gnome.Firmware.desktop' 'fwupd.desktop'

        # Language & Locale
        'gnome-language-selector.desktop' 'language-selector.desktop'
        
        # Help & Documentation
        'yelp.desktop' 'gnome-help.desktop' 'help.desktop' 'org.gnome.Yelp.desktop'
        
        # Ubuntu specific
        'ubuntu-session-properties.desktop' 'gnome-initial-setup.desktop'
        'update-notifier.desktop' 'software-center.desktop'
        
        # Firmware Updater - Snap package versions
        'firmware-updater_firmware-updater.desktop' 'firmware-updater_firmware-updater-app.desktop'

        # GNOME Network Displays (Tela via Rede)
        'org.gnome.NetworkDisplays.desktop' 'gnome-network-displays.desktop'
        'org.gnome.Connections.desktop' 'gnome-connections.desktop' 'gnome-remote-desktop.desktop'

        # Launcher
        'rofi.desktop' 'rofi-theme-selector.desktop'
    )
    
    # Search for system apps
    for app in "${system_app_names[@]}"; do
        if result=$(find_app_desktop_file "$app"); then
            sistema_apps+=("'$result'")
        fi
    done
    
    # Also search for related patterns - INCLUDING SNAP/FLATPAK LOCATIONS
    shopt -s nullglob
    for desktop_file in /usr/share/applications/*system*.desktop \
                        /usr/share/applications/*settings*.desktop \
                        /usr/share/applications/*config*.desktop \
                        /usr/share/applications/*update*.desktop \
                        /usr/share/applications/*driver*.desktop \
                        /usr/share/applications/*firmware*.desktop \
                        /var/lib/snapd/desktop/applications/*firmware*.desktop \
                        /var/lib/snapd/desktop/applications/*system*.desktop \
                        /var/lib/snapd/desktop/applications/*update*.desktop \
                        /var/lib/flatpak/exports/share/applications/*NetworkDisplays*.desktop \
                        /var/lib/flatpak/exports/share/applications/*connections*.desktop \
                        "$HOME/.local/share/applications"/*system*.desktop \
                        "$HOME/.local/share/applications"/*settings*.desktop \
                        "$HOME/.local/share/applications"/*config*.desktop \
                        "$HOME/.local/share/applications"/*firmware*.desktop \
                        "$HOME/.local/share/applications"/*NetworkDisplays*.desktop; do
        if [ -f "$desktop_file" ]; then
            local basename
            basename=$(basename "$desktop_file")
            # kdeconnect excluded: *settings* would otherwise catch
            # org.kde.kdeconnect-settings.desktop, which Sharing's own
            # *kdeconnect* glob already claims — Sharing wins (#391).
            # firewall excluded: *config* would otherwise catch
            # firewall-config.desktop, which Security already claims.
            # system-log excluded: *system* would otherwise catch
            # gnome-system-log.desktop, which Utilities already claims.
            # system-monitor excluded: same glob would catch
            # gnome-system-monitor.desktop, which Monitoring owns.
            if [[ ! "$basename" =~ "game" ]] && [[ ! "$basename" =~ "sound" ]] && \
               [[ ! "$basename" =~ "color" ]] && [[ ! "$basename" =~ "kdeconnect" ]] && \
               [[ ! "$basename" =~ "firewall" ]] && [[ ! "$basename" =~ "system-log" ]] && \
               [[ ! "$basename" =~ "system-monitor" ]] && \
               [[ ! " ${sistema_apps[*]} " == *" '$basename' "* ]]; then
                sistema_apps+=("'$basename'")
            fi
        fi
    done
    shopt -u nullglob
    
    # Remove duplicates
    _merge_registry_into_folder "Sistema" sistema_apps
    mapfile -t sistema_apps < <(printf '%s\n' "${sistema_apps[@]}" | sort -u)
    if [ ${#sistema_apps[@]} -gt 0 ]; then
        local sistema_apps_str
        sistema_apps_str=$(IFS=,; echo "${sistema_apps[*]}")
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Sistema/ name 'System'
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Sistema/ apps "[${sistema_apps_str}]"
        folder_ids+=("'Sistema'")
        print_status "success" "System folder created with ${#sistema_apps[@]} apps"
        print_status "config" "  Apps: ${sistema_apps_str}"
    else
        print_status "warning" "No System apps found"
    fi
    
    # ==================== SECURITY FOLDER ====================
    print_status "info" "Creating Security folder..."
    local seguranca_apps=()
    
    # Security and Backup applications
    local security_app_names=(
        'clamtk.desktop' 'com.gitlab.davem.ClamTk.desktop'
        'timeshift-gtk.desktop' 'timeshift.desktop' 'com.teejeetech.Timeshift.desktop'
        'org.gnome.DejaDup.desktop' 'deja-dup.desktop' 'deja-dup-preferences.desktop'
        'backups.desktop' 'gnome-backups.desktop'
        'duplicity.desktop' 'grsync.desktop' 'luckybackup.desktop'
        'veracrypt.desktop' 'keepassxc.desktop' 'seahorse.desktop' 'gnome-seahorse.desktop'
        'gufw.desktop' 'firewall-config.desktop' 'ufw.desktop'
        'com.yubico.yubioath.desktop' 'gscriptor.desktop'
    )
    
    for app in "${security_app_names[@]}"; do
        if result=$(find_app_desktop_file "$app"); then
            seguranca_apps+=("'$result'")
        fi
    done
    
    shopt -s nullglob
    for desktop_file in /usr/share/applications/*backup*.desktop \
                        /usr/share/applications/*timeshift*.desktop \
                        /usr/share/applications/*clam*.desktop \
                        /usr/share/applications/*security*.desktop \
                        /usr/share/applications/*firewall*.desktop \
                        /usr/share/applications/*encrypt*.desktop \
                        "$HOME/.local/share/applications"/*backup*.desktop \
                        "$HOME/.local/share/applications"/*timeshift*.desktop \
                        "$HOME/.local/share/applications"/*clam*.desktop; do
        if [ -f "$desktop_file" ]; then
            local basename
            basename=$(basename "$desktop_file")
            if [[ ! " ${seguranca_apps[*]} " == *" '$basename' "* ]]; then
                seguranca_apps+=("'$basename'")
            fi
        fi
    done
    shopt -u nullglob
    
    _merge_registry_into_folder "Seguranca" seguranca_apps
    mapfile -t seguranca_apps < <(printf '%s\n' "${seguranca_apps[@]}" | sort -u)
    if [ ${#seguranca_apps[@]} -gt 0 ]; then
        local seguranca_apps_str
        seguranca_apps_str=$(IFS=,; echo "${seguranca_apps[*]}")
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Seguranca/ name 'Security'
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Seguranca/ apps "[${seguranca_apps_str}]"
        folder_ids+=("'Seguranca'")
        print_status "success" "Security folder created with ${#seguranca_apps[@]} apps"
        print_status "config" "  Apps: ${seguranca_apps_str}"
    else
        print_status "warning" "No Security apps found"
    fi
    
    # ==================== UTILITIES FOLDER ====================
    print_status "info" "Creating Utilities folder..."
    local utilitarios_apps=()
    
    local utility_app_names=(
        'nm-connection-editor.desktop' 'network-admin.desktop' 'gnome-nettool.desktop'
        # baobab / DiskUtility deliberately absent: Infra claims them (#703).
        'org.gnome.FileShredder.desktop' 'file-shredder.desktop' 'shredder.desktop'
        'com.github.ADBeveridge.Raider.desktop' 'raider.desktop'
        'org.gnome.Evince.desktop' 'evince.desktop'
        'org.gnome.eog.desktop' 'eog.desktop' 'org.gnome.ImageViewer.desktop'
        # 'seahorse.desktop' deliberately absent: Security already claims it
        # (#391) and is the folder that fits.
        'org.gnome.seahorse.Application.desktop'
        # 'org.gnome.Software.desktop' / 'software-center.desktop' deliberately
        # absent: System already claims both (#391).
        'gnome-software.desktop'
        # 'snap-store_ubuntu-software.desktop' deliberately absent: System
        # already claims it (#391).
        'snap-store_snap-store.desktop' 'snap-store.desktop'
        'io.snapcraft.Store.desktop' 'snapcraft-store.desktop'
        'org.gnome.Extensions.desktop' 'gnome-extensions.desktop' 'gnome-shell-extension-prefs.desktop'
        'com.mattjakeman.ExtensionManager.desktop' 'extension-manager.desktop' 'gnome-extension-manager.desktop'
        'com.github.hluk.copyq.desktop' 'copyq.desktop'
        'org.gnome.Shotwell.desktop' 'shotwell.desktop' 'shotwell-viewer.desktop'
        'org.gnome.clocks.desktop' 'gnome-clocks.desktop'
        'org.gnome.Calculator.desktop' 'gnome-calculator.desktop' 'gcalctool.desktop'
        'org.gnome.Nautilus.desktop' 'nautilus.desktop' 'org.gnome.Files.desktop'
        'org.freedesktop.Piper.desktop' 'piper.desktop'
        'org.gnome.Logs.desktop' 'gnome-logs.desktop' 'gnome-system-log.desktop'
        'org.gnome.Characters.desktop' 'gucharmap.desktop' 'gnome-characters.desktop'
        'org.gnome.font-viewer.desktop' 'gnome-font-viewer.desktop' 'org.gnome.FontManager.desktop'
        'font-manager.desktop' 'fonts.desktop'
        'org.gnome.gedit.desktop' 'gedit.desktop' 'org.gnome.TextEditor.desktop' 'gnome-text-editor.desktop'
        'org.gnome.FileRoller.desktop' 'file-roller.desktop'
        'org.gnome.Screenshot.desktop' 'gnome-screenshot.desktop'
        'flameshot.desktop' 'org.flameshot.Flameshot.desktop'
        'org.gnome.Weather.desktop' 'gnome-weather.desktop'
        'org.gnome.Maps.desktop' 'gnome-maps.desktop'
        'evolution.desktop' 'org.gnome.Evolution.desktop'
        'geary.desktop' 'org.gnome.Geary.desktop'
        'gnome-shell-extension-vitals.desktop'
        'usb-creator-gtk.desktop' 'gnome-multi-writer.desktop' 'org.gnome.MultiWriter.desktop'
        'startup-disk-creator.desktop'
        'simple-scan.desktop' 'org.gnome.SimpleScan.desktop' 'gnome-simple-san.desktop'
        'xsane.desktop' 'skanlite.desktop'
        'geomview.desktop' 'org.geomview.Geomview.desktop'
        'bleachbit.desktop'
    )
    
    for app in "${utility_app_names[@]}"; do
        if result=$(find_app_desktop_file "$app"); then
            utilitarios_apps+=("'$result'")
        fi
    done
    
    # No `org.gnome.*.desktop` glob here (#391): every org.gnome app Utilities
    # actually wants (Nautilus, Calculator, eog, Evince, Extensions, Shotwell,
    # clocks, Logs, Characters, font-viewer, gedit/TextEditor, FileRoller,
    # Screenshot, Weather, Maps, Evolution, Geary, MultiWriter, SimpleScan,
    # FileShredder, seahorse.Application) is already in
    # utility_app_names above (baobab/DiskUtility moved to Infra, #703). A blanket org.gnome.* glob catches every OTHER
    # org.gnome app too — Settings/Software (System), SystemMonitor/PowerStats
    # (Monitoring),
    # Boxes/Vinagre (Infra), Cheese/Music/Rhythmbox3/SoundRecorder/Totem
    # (Media), Connections/NetworkDisplays/Yelp/Firmware (System), DejaDup
    # (Security) — silently duplicating whichever folder already claims it.
    shopt -s nullglob
    for desktop_file in /usr/share/applications/*viewer*.desktop \
                        /usr/share/applications/*calculator*.desktop \
                        /usr/share/applications/*files*.desktop \
                        /usr/share/applications/*nautilus*.desktop \
                        /usr/share/applications/*evolution*.desktop \
                        /usr/share/applications/*geary*.desktop \
                        /usr/share/applications/*scan*.desktop \
                        /usr/share/applications/*usb-creator*.desktop \
                        /usr/share/applications/*startup-disk*.desktop \
                        /usr/share/applications/*geomview*.desktop \
                        /usr/share/applications/*flameshot*.desktop \
                        /var/lib/snapd/desktop/applications/snap-store*.desktop \
                        /var/lib/snapd/desktop/applications/*software*.desktop \
                        /var/lib/flatpak/exports/share/applications/*Raider*.desktop \
                        /var/lib/flatpak/exports/share/applications/*shredder*.desktop \
                        /var/lib/flatpak/exports/share/applications/*flameshot*.desktop \
                        "$HOME/.local/share/applications"/*evolution*.desktop \
                        "$HOME/.local/share/applications"/*scan*.desktop \
                        "$HOME/.local/share/applications"/*geomview*.desktop \
                        "$HOME/.local/share/applications"/*Raider*.desktop \
                        "$HOME/.local/share/applications"/*flameshot*.desktop; do
        if [ -f "$desktop_file" ]; then
            local basename
            basename=$(basename "$desktop_file")
            # Exclusions below narrow the `*viewer*`, `*software*` and
            # `snap-store*` globs above so they stop re-adding ids System or
            # Ereader already own (#391): the id itself can't be dropped from
            # THIS array (it was never here — it's glob-caught), only the glob
            # narrowed. remote-viewer/calibre-*viewer* → Infra/Ereader;
            # snap-store_ubuntu-software/software-center → System.
            if [[ ! "$basename" =~ "settings" ]] && [[ ! "$basename" =~ "control-center" ]] && \
               [[ ! "$basename" =~ "software-properties" ]] && [[ ! "$basename" =~ "update" ]] && \
               [[ ! "$basename" =~ "firmware" ]] && \
               [[ ! "$basename" =~ "remote-viewer" ]] && [[ ! "$basename" =~ "calibre" ]] && \
               [[ ! "$basename" =~ "ubuntu-software" ]] && [[ "$basename" != "software-center.desktop" ]] && \
               [[ ! " ${utilitarios_apps[*]} " == *" '$basename' "* ]]; then
                utilitarios_apps+=("'$basename'")
            fi
        fi
    done
    shopt -u nullglob
    
    _merge_registry_into_folder "Utilitarios" utilitarios_apps
    mapfile -t utilitarios_apps < <(printf '%s\n' "${utilitarios_apps[@]}" | sort -u)
    if [ ${#utilitarios_apps[@]} -gt 0 ]; then
        local utilitarios_apps_str
        utilitarios_apps_str=$(IFS=,; echo "${utilitarios_apps[*]}")
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Utilitarios/ name 'Utilities'
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Utilitarios/ apps "[${utilitarios_apps_str}]"
        folder_ids+=("'Utilitarios'")
        print_status "success" "Utilities folder created with ${#utilitarios_apps[@]} apps"
        print_status "config" "  Apps: ${utilitarios_apps_str}"
    else
        print_status "warning" "No Utilities apps found"
    fi

    # ==================== DESIGN FOLDER ====================
    print_status "info" "Creating Design folder..."
    local design_apps=()

    _merge_registry_into_folder "Design" design_apps
    mapfile -t design_apps < <(printf '%s\n' "${design_apps[@]}" | sort -u)
    if [ ${#design_apps[@]} -gt 0 ]; then
        local design_apps_str
        design_apps_str=$(IFS=,; echo "${design_apps[*]}")
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Design/ name 'Design'
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Design/ apps "[${design_apps_str}]"
        folder_ids+=("'Design'")
        print_status "success" "Design folder created with ${#design_apps[@]} apps"
        print_status "config" "  Apps: ${design_apps_str}"
    else
        print_status "warning" "No Design apps found"
    fi

    # ==================== MONITORING FOLDER ====================
    # Read-only dashboards for hardware and load. System keeps settings, updates,
    # drivers and firmware. Vitals is a top-bar Shell extension with no launcher,
    # so it cannot live in a folder.
    print_status "info" "Creating Monitoring folder..."
    local monitoring_apps=()

    local monitoring_app_names=(
        'io.missioncenter.MissionCenter.desktop' 'mission-center.desktop'
        'gnome-system-monitor.desktop' 'org.gnome.SystemMonitor.desktop'
        'org.gnome.PowerStats.desktop' 'gnome-power-statistics.desktop' 'power-statistics.desktop'
        'cpu-x.desktop' 'cpux.desktop' 'io.github.thetumultuousunicornofdarkness.cpu-x.desktop'
        'htop.desktop'
    )

    for app in "${monitoring_app_names[@]}"; do
        if result=$(find_app_desktop_file "$app"); then
            monitoring_apps+=("'$result'")
        fi
    done

    shopt -s nullglob
    for desktop_file in /var/lib/flatpak/exports/share/applications/*missioncenter*.desktop \
                        /var/lib/flatpak/exports/share/applications/*cpu-x*.desktop \
                        "$HOME/.local/share/applications"/*missioncenter*.desktop \
                        "$HOME/.local/share/applications"/*cpu-x*.desktop; do
        if [ -f "$desktop_file" ]; then
            local basename
            basename=$(basename "$desktop_file")
            if [[ ! " ${monitoring_apps[*]} " == *" '$basename' "* ]]; then
                monitoring_apps+=("'$basename'")
            fi
        fi
    done
    shopt -u nullglob

    _merge_registry_into_folder "Monitoring" monitoring_apps
    mapfile -t monitoring_apps < <(printf '%s\n' "${monitoring_apps[@]}" | sort -u)
    if [ ${#monitoring_apps[@]} -gt 0 ]; then
        local monitoring_apps_str
        monitoring_apps_str=$(IFS=,; echo "${monitoring_apps[*]}")
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Monitoring/ name 'Monitoring'
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Monitoring/ apps "[${monitoring_apps_str}]"
        folder_ids+=("'Monitoring'")
        print_status "success" "Monitoring folder created with ${#monitoring_apps[@]} apps"
        print_status "config" "  Apps: ${monitoring_apps_str}"
    else
        print_status "warning" "No Monitoring apps found"
    fi

    # ==================== MEDIA FOLDER ====================
    print_status "info" "Creating Media folder..."
    local media_apps=()

    local media_app_names=(
        'vlc.desktop' 'org.videolan.VLC.desktop'
        '4kvideodownloaderplus.desktop'
        'asunder.desktop'
        'rhythmbox.desktop' 'org.gnome.Rhythmbox3.desktop'
        'cheese.desktop' 'org.gnome.Cheese.desktop'
        'org.gnome.Music.desktop'
        'totem.desktop' 'org.gnome.Totem.desktop'
        'org.gnome.SoundRecorder.desktop' 'gnome-sound-recorder.desktop'
        'celluloid.desktop' 'io.github.celluloid_mpv.Celluloid.desktop'
        'mpv.desktop' 'io.mpv.Mpv.desktop'
        'handbrake.desktop' 'fr.handbrake.ghb.desktop'
        'kdenlive.desktop' 'org.kde.kdenlive.desktop'
        'pitivi.desktop' 'org.pitivi.Pitivi.desktop'
    )

    for app in "${media_app_names[@]}"; do
        if result=$(find_app_desktop_file "$app"); then
            media_apps+=("'$result'")
        fi
    done

    shopt -s nullglob
    for desktop_file in /usr/share/applications/*vlc*.desktop \
                        /usr/share/applications/*4kdownload*.desktop \
                        /usr/share/applications/*4kvideo*.desktop \
                        /var/lib/snapd/desktop/applications/*vlc*.desktop \
                        /var/lib/flatpak/exports/share/applications/*vlc*.desktop \
                        /var/lib/flatpak/exports/share/applications/*4kdownload*.desktop \
                        "$HOME/.local/share/applications"/*vlc*.desktop \
                        "$HOME/.local/share/applications"/*4kdownload*.desktop; do
        if [ -f "$desktop_file" ]; then
            local basename
            basename=$(basename "$desktop_file")
            if [[ ! " ${media_apps[*]} " == *" '$basename' "* ]]; then
                media_apps+=("'$basename'")
            fi
        fi
    done
    shopt -u nullglob

    _merge_registry_into_folder "Media" media_apps
    mapfile -t media_apps < <(printf '%s\n' "${media_apps[@]}" | sort -u)
    if [ ${#media_apps[@]} -gt 0 ]; then
        local media_apps_str
        media_apps_str=$(IFS=,; echo "${media_apps[*]}")
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Media/ name 'Media'
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Media/ apps "[${media_apps_str}]"
        folder_ids+=("'Media'")
        print_status "success" "Media folder created with ${#media_apps[@]} apps"
        print_status "config" "  Apps: ${media_apps_str}"
    else
        print_status "warning" "No Media apps found"
    fi

    # ==================== SHARING FOLDER ====================
    print_status "info" "Creating Sharing folder..."
    local sharing_apps=()
    
    for app in 'org.kde.kdeconnect.settings.desktop' 'org.kde.kdeconnect.nonplasma.desktop' \
               'org.kde.kdeconnect.app.desktop' 'org.kde.kdeconnect.sms.desktop' \
               'kdeconnect-settings.desktop' 'kdeconnect.desktop' 'kdeconnect-indicator.desktop' \
               'kdeconnect-sms.desktop' 'org.kde.kdeconnect_open.desktop' \
               'org.localsend.localsend_app.desktop' 'localsend.desktop' 'localsend_app.desktop' \
               'transmission-gtk.desktop' 'transmission.desktop' 'org.transmissionbt.Transmission.desktop' \
               'insync.desktop' 'com.insynchq.insync.desktop' 'insync-app.desktop'; do
        if result=$(find_app_desktop_file "$app"); then
            sharing_apps+=("'$result'")
        fi
    done
    
    shopt -s nullglob
    for desktop_file in /usr/share/applications/*kdeconnect*.desktop "$HOME/.local/share/applications"/*kdeconnect*.desktop \
                        /usr/share/applications/*localsend*.desktop "$HOME/.local/share/applications"/*localsend*.desktop \
                        /usr/share/applications/*transmission*.desktop "$HOME/.local/share/applications"/*transmission*.desktop \
                        /usr/share/applications/*insync*.desktop "$HOME/.local/share/applications"/*insync*.desktop \
                        /var/lib/flatpak/exports/share/applications/*insync*.desktop; do
        if [ -f "$desktop_file" ]; then
            local basename
            basename=$(basename "$desktop_file")
            if [[ ! " ${sharing_apps[*]} " == *" '$basename' "* ]]; then
                sharing_apps+=("'$basename'")
            fi
        fi
    done
    shopt -u nullglob
    
    _merge_registry_into_folder "Sharing" sharing_apps
    mapfile -t sharing_apps < <(printf '%s\n' "${sharing_apps[@]}" | sort -u)
    if [ ${#sharing_apps[@]} -gt 0 ]; then
        local sharing_apps_str
        sharing_apps_str=$(IFS=,; echo "${sharing_apps[*]}")
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Sharing/ name 'Sharing'
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Sharing/ apps "[${sharing_apps_str}]"
        folder_ids+=("'Sharing'")
        print_status "success" "Sharing folder created with ${#sharing_apps[@]} apps"
        print_status "config" "  Apps: ${sharing_apps_str}"
    else
        print_status "warning" "No Sharing apps found"
    fi
    
    # ==================== IRPF FOLDER ====================
    print_status "info" "Creating IRPF folder..."
    local irpf_apps=()
    
    shopt -s nullglob
    for desktop_file in /usr/share/applications/*.desktop "$HOME/.local/share/applications"/*.desktop; do
        if [ -f "$desktop_file" ]; then
            local basename
            basename=$(basename "$desktop_file")
            if [[ "$basename" =~ [Ii][Rr][Pp][Ff] ]] || [[ "$basename" =~ irpf ]]; then
                irpf_apps+=("'$basename'")
            fi
        fi
    done
    shopt -u nullglob
    
    mapfile -t irpf_apps < <(printf '%s\n' "${irpf_apps[@]}" | sort -u)
    if [ ${#irpf_apps[@]} -gt 0 ]; then
        local irpf_apps_str
        irpf_apps_str=$(IFS=,; echo "${irpf_apps[*]}")
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/IRPF/ name 'IRPF'
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/IRPF/ apps "[${irpf_apps_str}]"
        folder_ids+=("'IRPF'")
        print_status "success" "IRPF folder created with ${#irpf_apps[@]} apps"
        print_status "config" "  Apps: ${irpf_apps_str}"
    else
        print_status "warning" "No IRPF apps found"
    fi
    
    # ==================== CODE FOLDER ====================
    print_status "info" "Creating Code folder..."
    local code_apps=()

    local code_app_names=(
        'vim.desktop' 'gvim.desktop' 'org.vim.Vim.desktop'
        'nvim.desktop' 'neovim.desktop' 'org.neovim.nvim.desktop'  # Added Neovim
        'dev.warp.Warp.desktop' 'warp.desktop' 'warp-terminal.desktop'
        'me.iepure.devtoolbox.desktop' 'devtoolbox.desktop' 'dev-toolbox.desktop'
        'cursor.desktop' 'com.cursor.Cursor.desktop' 'cursor-app.desktop'
        'notepadqq.desktop' 'com.notepadqq.Notepadqq.desktop'
    )

    for app in "${code_app_names[@]}"; do
        if result=$(find_app_desktop_file "$app"); then
            code_apps+=("'$result'")
            print_status "config" "Found Code app: $result"
        fi
    done

    # Search for Neovim desktop files in common locations
    print_status "info" "Searching for Neovim desktop files..."
    shopt -s nullglob
    for desktop_file in /usr/share/applications/nvim*.desktop \
                        /usr/share/applications/neovim*.desktop \
                        "$HOME/.local/share/applications"/nvim*.desktop \
                        "$HOME/.local/share/applications"/neovim*.desktop \
                        /var/lib/flatpak/exports/share/applications/*nvim*.desktop \
                        /var/lib/flatpak/exports/share/applications/*neovim*.desktop; do
        if [ -f "$desktop_file" ]; then
            local basename
            basename=$(basename "$desktop_file")
            if [[ ! " ${code_apps[*]} " == *" '$basename' "* ]]; then
                code_apps+=("'$basename'")
                print_status "success" "✓ Added Neovim: $basename"
            fi
        fi
    done
    shopt -u nullglob

    # Check if Neovim is installed but doesn't have a desktop file
    if command -v nvim >/dev/null 2>&1; then
        print_status "info" "Neovim is installed but checking for desktop file..."

        # Check if we already found a desktop file
        local found_nvim_desktop=false
        for app in "${code_apps[@]}"; do
            if [[ "$app" == *"nvim"* ]] || [[ "$app" == *"neovim"* ]]; then
                found_nvim_desktop=true
                break
            fi
        done

        if [ "$found_nvim_desktop" = false ]; then
            print_status "warning" "Neovim is installed but no desktop file found"
            print_status "info" "Creating a desktop file for Neovim..."

            local nvim_desktop_path="$HOME/.local/share/applications/nvim.desktop"
            mkdir -p "$HOME/.local/share/applications"

            cat > "$nvim_desktop_path" << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Neovim
GenericName=Text Editor
Comment=Edit text files
Exec=nvim %F
Icon=nvim
Terminal=true
StartupNotify=true
Categories=Development;TextEditor;
Keywords=Text;Editor;
MimeType=text/plain;
EOF

            if [ -f "$nvim_desktop_path" ]; then
                code_apps+=("'nvim.desktop'")
                print_status "success" "✓ Created and added Neovim desktop file"
            else
                print_status "error" "Failed to create Neovim desktop file"
            fi
        fi
    fi

    # Remove any duplicates that might have been added
    _merge_registry_into_folder "Code" code_apps
    mapfile -t code_apps < <(printf '%s\n' "${code_apps[@]}" | sort -u)
    if [ ${#code_apps[@]} -gt 0 ]; then
        local code_apps_str
        code_apps_str=$(IFS=,; echo "${code_apps[*]}")
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Code/ name 'Code'
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Code/ apps "[${code_apps_str}]"
        folder_ids+=("'Code'")
        print_status "success" "Code folder created with ${#code_apps[@]} apps"
        print_status "config" "  Apps in Code folder:"
        for app in "${code_apps[@]}"; do
            print_status "config" "    - ${app//\'/}"
        done
    else
        print_status "warning" "No Code apps found"
    fi

    # ==================== DATA FOLDER ====================
    print_status "info" "Creating Data folder..."
    local data_apps=()

    local data_app_names=(
        'pgadmin4.desktop' 'pgadmin4_pgadmin4.desktop' 'org.pgadmin.pgAdmin4.desktop'
        'postman_postman.desktop' 'postman.desktop' 'Postman.desktop'
    )

    for app in "${data_app_names[@]}"; do
        if result=$(find_app_desktop_file "$app"); then
            data_apps+=("'$result'")
        fi
    done

    _merge_registry_into_folder "Data" data_apps
    mapfile -t data_apps < <(printf '%s\n' "${data_apps[@]}" | sort -u)
    if [ ${#data_apps[@]} -gt 0 ]; then
        local data_apps_str
        data_apps_str=$(IFS=,; echo "${data_apps[*]}")
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Data/ name 'Data'
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Data/ apps "[${data_apps_str}]"
        folder_ids+=("'Data'")
        print_status "success" "Data folder created with ${#data_apps[@]} apps"
        print_status "config" "  Apps: ${data_apps_str}"
    else
        print_status "warning" "No Data apps found"
    fi

    # ==================== EREADER FOLDER ====================
    print_status "info" "Creating ereader folder..."
    local ereader_apps=()
    
    for app in 'calibre-gui.desktop' 'calibre.desktop' \
               'calibre-ebook-edit.desktop' 'ebook-edit.desktop' \
               'calibre-ebook-viewer.desktop' 'ebook-viewer.desktop' \
               'calibre-lrfviewer.desktop' 'lrfviewer.desktop'; do
        if result=$(find_app_desktop_file "$app"); then
            ereader_apps+=("'$result'")
        fi
    done
    
    shopt -s nullglob
    for desktop_file in /usr/share/applications/*calibre*.desktop "$HOME/.local/share/applications"/*calibre*.desktop \
                        /usr/share/applications/*ebook*.desktop "$HOME/.local/share/applications"/*ebook*.desktop \
                        /usr/share/applications/*lrf*.desktop "$HOME/.local/share/applications"/*lrf*.desktop; do
        if [ -f "$desktop_file" ]; then
            local basename
            basename=$(basename "$desktop_file")
            if [[ ! " ${ereader_apps[*]} " == *" '$basename' "* ]]; then
                ereader_apps+=("'$basename'")
            fi
        fi
    done
    shopt -u nullglob
    
    mapfile -t ereader_apps < <(printf '%s\n' "${ereader_apps[@]}" | sort -u)
    if [ ${#ereader_apps[@]} -gt 0 ]; then
        local ereader_apps_str
        ereader_apps_str=$(IFS=,; echo "${ereader_apps[*]}")
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Ereader/ name 'Ereader'
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Ereader/ apps "[${ereader_apps_str}]"
        folder_ids+=("'Ereader'")
        print_status "success" "Ereader folder created with ${#ereader_apps[@]} apps"
        print_status "config" "  Apps: ${ereader_apps_str}"
    else
        print_status "warning" "No Ereader apps found"
    fi
    
    # ==================== OFFICE FOLDER ====================
    print_status "info" "Creating Office folder..."
    local office_apps=()

    # 'com.github.PintaProject.Pinta.desktop' deliberately absent: Design
    # already claims it via install_pinta's INSTALL_REGISTRY entry (#391).
    # 'pinta.desktop' (the apt-package id) stays — it's a different install
    # path with no registry counterpart, so it isn't a cross-folder duplicate.
    for app in 'libreoffice-calc.desktop' 'libreoffice-draw.desktop' 'libreoffice-impress.desktop' \
            'libreoffice-math.desktop' 'libreoffice-writer.desktop' 'libreoffice-base.desktop' \
            'libreoffice-startcenter.desktop' 'libreoffice-xsltfilter.desktop' \
            'pinta.desktop'; do
        if result=$(find_app_desktop_file "$app"); then
            office_apps+=("'$result'")
        fi
    done

    if [ ${#office_apps[@]} -gt 0 ]; then
        local office_apps_str
        office_apps_str=$(IFS=,; echo "${office_apps[*]}")
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Office/ name 'Office'
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Office/ apps "[${office_apps_str}]"
        folder_ids+=("'Office'")
        print_status "success" "Office folder created with ${#office_apps[@]} apps"
        print_status "config" "  Apps: ${office_apps_str}"
    else
        print_status "warning" "No Office apps found"
    fi
    
    # ==================== PLANNING FOLDER ====================
    print_status "info" "Creating Planning folder..."
    local planning_apps=()

    local planning_app_names=(
        'google-calendar.desktop'
        'notion-calendar.desktop'
        'google-tasks.desktop'
        'linear.desktop'
        'miro.desktop' 'com.miro.Miro.desktop' 'miro-app.desktop' 'RealtimeBoard.desktop'
        'miro_miro.desktop' 'snap-miro_miro.desktop'
    )

    for app in "${planning_app_names[@]}"; do
        if result=$(find_app_desktop_file "$app"); then
            planning_apps+=("'$result'")
        fi
    done

    # SPECIFIC Miro Snap package detection
    print_status "info" "Adding Miro Snap package..."
    if [ -f "/var/lib/snapd/desktop/applications/miro_miro.desktop" ]; then
        if [[ ! " ${planning_apps[*]} " == *" 'miro_miro.desktop' "* ]]; then
            planning_apps+=("'miro_miro.desktop'")
            print_status "success" "✓ Added Miro Snap package: miro_miro.desktop"
        else
            print_status "info" "Miro Snap package already in list"
        fi
    else
        print_status "warning" "Miro Snap package not found at expected location"
    fi

    # SPECIFIC Chrome App Miro detection - using the exact filename we found
    print_status "info" "Adding Miro Chrome app..."
    local miro_chrome_app="chrome-bfldocfmjhokladppcchgfolcnpjlnng-Default.desktop"
    if [ -f "$HOME/.local/share/applications/$miro_chrome_app" ]; then
        if [[ ! " ${planning_apps[*]} " == *" '$miro_chrome_app' "* ]]; then
            planning_apps+=("'$miro_chrome_app'")
            print_status "success" "✓ Added Miro Chrome app: $miro_chrome_app"
        else
            print_status "info" "Miro Chrome app already in list"
        fi
    else
        print_status "warning" "Miro Chrome app not found at: $HOME/.local/share/applications/$miro_chrome_app"
    fi

    # Additional fallback search for any other Miro Chrome apps (in case there are multiple)
    print_status "info" "Searching for additional Miro Chrome shortcuts..."
    shopt -s nullglob
    for desktop_file in "$HOME/.local/share/applications/chrome-"*.desktop; do
        if [ -f "$desktop_file" ]; then
            local basename
            basename=$(basename "$desktop_file")
            # Skip if it's already the one we specifically added
            if [ "$basename" != "$miro_chrome_app" ]; then
                # Check if it's Miro by examining the file content
                if grep -q -i "Name.*=.*Miro" "$desktop_file" ||
                grep -q -i "Exec.*=.*miro" "$desktop_file" ||
                grep -q -i "miro" "$desktop_file" ||
                grep -q -i "realtimeboard" "$desktop_file"; then
                    if [[ ! " ${planning_apps[*]} " == *" '$basename' "* ]]; then
                        planning_apps+=("'$basename'")
                        print_status "success" "✓ Added additional Miro Chrome shortcut: $basename"
                    fi
                fi
            fi
        fi
    done
    shopt -u nullglob

    _merge_registry_into_folder "Planning" planning_apps
    mapfile -t planning_apps < <(printf '%s\n' "${planning_apps[@]}" | sort -u)
    if [ ${#planning_apps[@]} -gt 0 ]; then
        local planning_apps_str
        planning_apps_str=$(IFS=,; echo "${planning_apps[*]}")
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Planning/ name 'Planning'
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Planning/ apps "[${planning_apps_str}]"
        folder_ids+=("'Planning'")
        print_status "success" "Planning folder created with ${#planning_apps[@]} apps"
        print_status "config" "  Apps: ${planning_apps_str}"
    else
        print_status "warning" "No Planning apps found"
    fi
    
    # ==================== INFRA FOLDER ====================
    print_status "info" "Creating Infra folder..."
    local infra_apps=()

    local infra_app_names=(
        'virt-manager.desktop' 'org.virt-manager.virt-manager.desktop'
        'gnome-boxes.desktop' 'org.gnome.Boxes.desktop'
        'virtualbox.desktop' 'org.virtualbox.VirtualBox.desktop' 'virtualbox-qt.desktop'
        'vmware-workstation.desktop' 'vmplayer.desktop'
        'virt-viewer.desktop' 'org.virt-manager.virt-viewer.desktop'
        'remote-viewer.desktop'
        'vinagre.desktop' 'org.gnome.Vinagre.desktop'
        'remmina.desktop' 'org.remmina.Remmina.desktop'
        'rdesktop.desktop' 'xfreerdp.desktop'
        'docker-desktop.desktop'
        'qemu.desktop' 'kvirt.desktop'
        'rustdesk.desktop' 'com.rustdesk.RustDesk.desktop' 'org.rustdesk.RustDesk.desktop'
        'balena-etcher-electron.desktop' 'balena-etcher.desktop'
        'ventoy.desktop' 'ventoy-web.desktop' 'ventoy-plugson.desktop'
        'org.gnome.DiskUtility.desktop' 'gnome-disks.desktop' 'gnome-disk-utility.desktop'
        'org.gnome.baobab.desktop' 'baobab.desktop'
    )

    for app in "${infra_app_names[@]}"; do
        if result=$(find_app_desktop_file "$app"); then
            infra_apps+=("'$result'")
        fi
    done

    shopt -s nullglob
    for desktop_file in /usr/share/applications/*virt*.desktop \
                        /usr/share/applications/*virtual*.desktop \
                        /usr/share/applications/*vmware*.desktop \
                        /usr/share/applications/*qemu*.desktop \
                        /usr/share/applications/*boxes*.desktop \
                        /usr/share/applications/*remote-viewer*.desktop \
                        /usr/share/applications/*vinagre*.desktop \
                        /usr/share/applications/*remmina*.desktop \
                        /usr/share/applications/*rustdesk*.desktop \
                        /var/lib/snapd/desktop/applications/*rustdesk*.desktop \
                        /var/lib/flatpak/exports/share/applications/*rustdesk*.desktop \
                        "$HOME/.local/share/applications"/*virt*.desktop \
                        "$HOME/.local/share/applications"/*virtual*.desktop \
                        "$HOME/.local/share/applications"/*rustdesk*.desktop; do
        if [ -f "$desktop_file" ]; then
            local basename
            basename=$(basename "$desktop_file")
            if [[ ! " ${infra_apps[*]} " == *" '$basename' "* ]]; then
                infra_apps+=("'$basename'")
            fi
        fi
    done
    shopt -u nullglob

    _merge_registry_into_folder "Infra" infra_apps
    mapfile -t infra_apps < <(printf '%s\n' "${infra_apps[@]}" | sort -u)
    if [ ${#infra_apps[@]} -gt 0 ]; then
        local infra_apps_str
        infra_apps_str=$(IFS=,; echo "${infra_apps[*]}")
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Infra/ name 'Infra'
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Infra/ apps "[${infra_apps_str}]"
        folder_ids+=("'Infra'")
        print_status "success" "Infra folder created with ${#infra_apps[@]} apps"
        print_status "config" "  Apps: ${infra_apps_str}"
    else
        print_status "warning" "No Infra apps found"
    fi
    
    # ==================== BROWSERS FOLDER ====================
    print_status "info" "Creating Browsers folder..."
    local browsers_apps=()

    local browser_app_names=(
        'firefox_firefox.desktop' 'firefox.desktop'
        'google-chrome.desktop' 'chrome.desktop'
        'com.opera.Opera.desktop'
        'com.vivaldi.Vivaldi.desktop' 'vivaldi-stable.desktop'
        'com.microsoft.Edge.desktop' 'microsoft-edge.desktop'
        'com.brave.Browser.desktop' 'brave-browser.desktop'
    )

    for app in "${browser_app_names[@]}"; do
        if result=$(find_app_desktop_file "$app"); then
            if [[ ! " ${browsers_apps[*]} " == *" '$result' "* ]]; then
                browsers_apps+=("'$result'")
            fi
        fi
    done

    shopt -s nullglob
    for desktop_file in /var/lib/flatpak/exports/share/applications/com.opera.Opera.desktop \
                        /var/lib/flatpak/exports/share/applications/com.vivaldi.Vivaldi.desktop \
                        /var/lib/flatpak/exports/share/applications/com.microsoft.Edge.desktop \
                        /var/lib/flatpak/exports/share/applications/com.brave.Browser.desktop \
                        "$HOME/.local/share/applications"/com.opera.Opera.desktop \
                        "$HOME/.local/share/applications"/com.vivaldi.Vivaldi.desktop \
                        "$HOME/.local/share/applications"/com.microsoft.Edge.desktop \
                        "$HOME/.local/share/applications"/com.brave.Browser.desktop; do
        if [ -f "$desktop_file" ]; then
            local basename
            basename=$(basename "$desktop_file")
            if [[ ! " ${browsers_apps[*]} " == *" '$basename' "* ]]; then
                browsers_apps+=("'$basename'")
            fi
        fi
    done
    shopt -u nullglob

    mapfile -t browsers_apps < <(printf '%s\n' "${browsers_apps[@]}" | sort -u)
    if [ ${#browsers_apps[@]} -gt 0 ]; then
        local browsers_apps_str
        browsers_apps_str=$(IFS=,; echo "${browsers_apps[*]}")
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Browsers/ name 'Browsers'
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Browsers/ apps "[${browsers_apps_str}]"
        folder_ids+=("'Browsers'")
        print_status "success" "Browsers folder created with ${#browsers_apps[@]} apps"
        print_status "config" "  Apps: ${browsers_apps_str}"
    else
        print_status "warning" "No browser apps found"
    fi

    # ==================== READING FOLDER ====================
    print_status "info" "Creating Reading folder..."
    local reading_apps=()

    local reading_app_names=(
        'io.gitlab.news_flash.NewsFlash.desktop'
        'valor-digital.desktop'
    )

    for app in "${reading_app_names[@]}"; do
        if result=$(find_app_desktop_file "$app"); then
            reading_apps+=("'$result'")
        fi
    done

    _merge_registry_into_folder "Reading" reading_apps
    mapfile -t reading_apps < <(printf '%s\n' "${reading_apps[@]}" | sort -u)
    if [ ${#reading_apps[@]} -gt 0 ]; then
        local reading_apps_str
        reading_apps_str=$(IFS=,; echo "${reading_apps[*]}")
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Reading/ name 'Reading'
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Reading/ apps "[${reading_apps_str}]"
        folder_ids+=("'Reading'")
        print_status "success" "Reading folder created with ${#reading_apps[@]} apps"
        print_status "config" "  Apps: ${reading_apps_str}"
    else
        print_status "warning" "No Reading apps found"
    fi

    # ==================== COMMUNICATION FOLDER ====================
    print_status "info" "Creating Social folder..."
    local social_apps=()

    local social_app_names=(
        'slack.desktop' 'com.slack.Slack.desktop' 'slack_slack.desktop' 'slack-desktop.desktop'
        'org.telegram.desktop.desktop' 'telegram-desktop.desktop' 'telegramdesktop.desktop'
        'thunderbird.desktop' 'thunderbird_thunderbird.desktop'
        'org.mozilla.Thunderbird.desktop' 'mozilla-thunderbird.desktop'
    )

    for app in "${social_app_names[@]}"; do
        if result=$(find_app_desktop_file "$app"); then
            if [[ ! " ${social_apps[*]} " == *" '$result' "* ]]; then
                social_apps+=("'$result'")
            fi
        fi
    done

    shopt -s nullglob
    for desktop_file in /usr/share/applications/*thunderbird*.desktop \
                        /usr/share/applications/*telegram*.desktop \
                        /var/lib/snapd/desktop/applications/*thunderbird*.desktop \
                        /var/lib/snapd/desktop/applications/*telegram*.desktop \
                        /var/lib/snapd/desktop/applications/*slack*.desktop \
                        /var/lib/flatpak/exports/share/applications/*thunderbird*.desktop \
                        /var/lib/flatpak/exports/share/applications/*Thunderbird*.desktop \
                        /var/lib/flatpak/exports/share/applications/org.telegram.desktop.desktop \
                        "$HOME/.local/share/applications"/*thunderbird*.desktop \
                        "$HOME/.local/share/applications"/*telegram*.desktop; do
        if [ -f "$desktop_file" ]; then
            local basename
            basename=$(basename "$desktop_file")
            if [[ ! " ${social_apps[*]} " == *" '$basename' "* ]]; then
                social_apps+=("'$basename'")
            fi
        fi
    done
    shopt -u nullglob

    _merge_registry_into_folder "Social" social_apps
    mapfile -t social_apps < <(printf '%s\n' "${social_apps[@]}" | sort -u)
    if [ ${#social_apps[@]} -gt 0 ]; then
        local social_apps_str
        social_apps_str=$(IFS=,; echo "${social_apps[*]}")
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Social/ name 'Social'
        run_or_echo gsettings set org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Social/ apps "[${social_apps_str}]"
        folder_ids+=("'Social'")
        print_status "success" "Social folder created with ${#social_apps[@]} apps"
        print_status "config" "  Apps: ${social_apps_str}"
    else
        print_status "warning" "No Social apps found"
    fi

    # ==================== UPDATE FOLDER LIST ====================
    # Order the folders alphabetically by the name the Shell DISPLAYS, not by
    # dconf id. Three ids differ from their display name (Seguranca→Security,
    # Sistema→System, Utilitarios→Utilities), so sorting by id would place
    # "System" before "Social" — correct against the dconf keys and wrong
    # against what the user reads on screen.
    #
    # The names are read back from gsettings rather than restated here: this
    # function has just written every one of them, so re-listing them would be
    # a second copy free to drift from the first. Under DRY_RUN the writes are
    # previewed rather than applied, so a name may not resolve — fall back to
    # the bare id, which keeps the ordering deterministic instead of empty.
    local ordered_folder_ids=()
    mapfile -t ordered_folder_ids < <(
        local created_folder bare_id display_name
        for created_folder in "${folder_ids[@]}"; do
            bare_id="${created_folder//\'/}"
            display_name=$(gsettings get \
                "org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/${bare_id}/" \
                name 2>/dev/null | tr -d "'")
            printf '%s\t%s\n' "${display_name:-$bare_id}" "$created_folder"
        done | sort -f | cut -f2
    )

    # Before writing the new folder-children list, reset any id this run no
    # longer produces — otherwise its schema entry (name/apps) survives as an
    # orphan in dconf, invisible until something re-adds the id (#293).
    local current_folder_children
    current_folder_children=$(gsettings get org.gnome.desktop.app-folders folder-children 2>/dev/null) || current_folder_children=""
    _reset_orphaned_app_folders ordered_folder_ids "$current_folder_children"

    if [ ${#ordered_folder_ids[@]} -gt 0 ]; then
        local ordered_folder_ids_str
        ordered_folder_ids_str=$(IFS=,; echo "${ordered_folder_ids[*]}")
        run_or_echo gsettings set org.gnome.desktop.app-folders folder-children "[${ordered_folder_ids_str}]"
        print_status "success" "App folders organized in custom order: ${ordered_folder_ids_str}"
    else
        print_status "warning" "No folders were created"
    fi

    if [ ${#MISSING_DESKTOP_IDS[@]} -gt 0 ]; then
        print_status "warning" "Registry apps not placed — no matching .desktop found (not installed, or wrong id):"
        local missing
        for missing in "${MISSING_DESKTOP_IDS[@]}"; do
            print_status "config" "  $missing"
        done
    fi

    print_status "info" "Application organization complete"
}

configure_vitals() {
    print_status "info" "Configuring Vitals system monitor..."
    
    # First check if Vitals extension is installed
    local vitals_installed=false
    
    # Check for Vitals extension in different locations
    if [ -d "$HOME/.local/share/gnome-shell/extensions/vitals@CoreCoding.com" ] || \
       [ -d "/usr/share/gnome-shell/extensions/vitals@CoreCoding.com" ]; then
        vitals_installed=true
    fi
    
    # Also check via extensions list
    if command -v gnome-extensions &> /dev/null; then
        if gnome-extensions list 2>/dev/null | grep -q "vitals@CoreCoding.com"; then
            vitals_installed=true
        fi
    fi
    
    if [ "$vitals_installed" = false ]; then
        print_status "warning" "Vitals extension is not installed"
        print_status "info" "You can install it from: https://extensions.gnome.org/extension/1460/vitals/"
        print_status "info" "Or run: gnome-extensions install vitals@CoreCoding.com"
        return 1
    fi
    
    print_status "success" "Vitals extension found, configuring..."
    
    # ==================== GENERAL SETTINGS ====================
    print_status "config" "Setting general preferences..."
    
    # Seconds between updates: 60
    run_or_echo gsettings set org.gnome.shell.extensions.vitals refresh-time 60
    
    # Position in panel: Left
    run_or_echo gsettings set org.gnome.shell.extensions.vitals position 0
    
    # Use greater precision
    run_or_echo gsettings set org.gnome.shell.extensions.vitals use-custom-decimals true
    
    # Alphabetize sensors
    run_or_echo gsettings set org.gnome.shell.extensions.vitals alphabetical true
    
    # Hide zero values
    run_or_echo gsettings set org.gnome.shell.extensions.vitals hide-zeros true
    
    # Use fixed widths
    run_or_echo gsettings set org.gnome.shell.extensions.vitals fixed-widths false
    
    # Hide icons in top bar
    run_or_echo gsettings set org.gnome.shell.extensions.vitals hide-icons true
    
    # Menu always centered
    run_or_echo gsettings set org.gnome.shell.extensions.vitals center-values true
    
    # Icon style: Original
    run_or_echo gsettings set org.gnome.shell.extensions.vitals icons-type 0
    
    # ==================== SENSORS ====================
    print_status "config" "Configuring sensors..."
    
    # Enable all sensors
    run_or_echo gsettings set org.gnome.shell.extensions.vitals show-temperature true
    run_or_echo gsettings set org.gnome.shell.extensions.vitals show-voltage true
    run_or_echo gsettings set org.gnome.shell.extensions.vitals show-fan true
    run_or_echo gsettings set org.gnome.shell.extensions.vitals show-memory true
    run_or_echo gsettings set org.gnome.shell.extensions.vitals show-processor true
    run_or_echo gsettings set org.gnome.shell.extensions.vitals show-system true
    run_or_echo gsettings set org.gnome.shell.extensions.vitals show-network true
    run_or_echo gsettings set org.gnome.shell.extensions.vitals show-storage true
    run_or_echo gsettings set org.gnome.shell.extensions.vitals show-battery true
    run_or_echo gsettings set org.gnome.shell.extensions.vitals show-graphics true
    
    # ==================== ADDITIONAL CONFIGURATION ====================
    print_status "config" "Setting additional Vitals preferences..."
    
    # Set temperature unit to Celsius
    run_or_echo gsettings set org.gnome.shell.extensions.vitals temperature-unit 0
    
    # Set network unit to KB/s
    run_or_echo gsettings set org.gnome.shell.extensions.vitals network-unit 1
    
    # Set storage unit to GB
    run_or_echo gsettings set org.gnome.shell.extensions.vitals storage-unit 2
    
    # Show storage in used/total format
    run_or_echo gsettings set org.gnome.shell.extensions.vitals storage-style 1
    
    # Show memory in percentage
    run_or_echo gsettings set org.gnome.shell.extensions.vitals memory-style 0
    
    # Show CPU in percentage
    run_or_echo gsettings set org.gnome.shell.extensions.vitals processor-style 0
    
    # Show battery in watts
    run_or_echo gsettings set org.gnome.shell.extensions.vitals battery-style 2
    
    # Show GPU in percentage
    run_or_echo gsettings set org.gnome.shell.extensions.vitals graphics-style 0
    
    # Show fan in RPM
    run_or_echo gsettings set org.gnome.shell.extensions.vitals fan-style 0
    
    # Show voltage in volts
    run_or_echo gsettings set org.gnome.shell.extensions.vitals voltage-style 0
    
    # ==================== SENSOR ORDER ====================
    print_status "config" "Setting sensor order..."
    run_or_echo gsettings set org.gnome.shell.extensions.vitals order "['temperature','voltage','fan','memory','processor','system','network','storage','battery','graphics']"
    
    # ==================== HOT SENSORS ====================
    print_status "config" "Configuring hot sensors (thresholds)..."
    run_or_echo gsettings set org.gnome.shell.extensions.vitals temperature-warning 80
    run_or_echo gsettings set org.gnome.shell.extensions.vitals temperature-critical 90
    run_or_echo gsettings set org.gnome.shell.extensions.vitals memory-warning 90
    run_or_echo gsettings set org.gnome.shell.extensions.vitals processor-warning 90
    
    # ==================== DISPLAY OPTIONS ====================
    print_status "config" "Setting display options..."
    run_or_echo gsettings set org.gnome.shell.extensions.vitals show-in-panel true
    run_or_echo gsettings set org.gnome.shell.extensions.vitals compact true
    run_or_echo gsettings set org.gnome.shell.extensions.vitals decoration false
    
    # ==================== VERIFY CONFIGURATION ====================
    print_status "info" "Verifying Vitals configuration..."
    local refresh_time
    refresh_time=$(gsettings get org.gnome.shell.extensions.vitals refresh-time)
    local sensors_order
    sensors_order=$(gsettings get org.gnome.shell.extensions.vitals order)
    
    print_status "success" "Vitals configuration complete!"
    print_status "config" "  Update interval: $refresh_time seconds"
    print_status "config" "  Sensor order: $sensors_order"
    
    # Restart GNOME Shell to apply changes
    print_status "info" "Restarting GNOME Shell to apply Vitals changes..."
    
    if command -v busctl &> /dev/null; then
        busctl --user call org.gnome.Shell /org/gnome/Shell org.gnome.Shell Eval s 'Meta.restart("Restarting GNOME Shell for Vitals...")'
        print_status "success" "GNOME Shell restart initiated"
        print_status "info" "Please wait a few seconds for the restart to complete"
    else
        print_status "warning" "Could not restart GNOME Shell automatically"
        print_status "info" "Please log out and log back in to see Vitals changes"
    fi
}

configure_dim_calendar_events() {
    print_status "info" "Configuring Dim Completed Calendar Events..."

    local EXT_UUID="dim-completed-calendar-events@marcinjahn.com"
    local ext_installed=false

    if [ -d "$HOME/.local/share/gnome-shell/extensions/$EXT_UUID" ] || \
       [ -d "/usr/share/gnome-shell/extensions/$EXT_UUID" ]; then
        ext_installed=true
    fi

    if command -v gnome-extensions &> /dev/null; then
        if gnome-extensions list 2>/dev/null | grep -q "$EXT_UUID"; then
            ext_installed=true
        fi
    fi

    if [ "$ext_installed" = false ]; then
        print_status "warning" "Dim Completed Calendar Events not installed"
        print_status "info" "Install it from: https://extensions.gnome.org/extension/5979/"
        print_status "info" "Or run: make install_programs (select Calendar Events Enhancement)"
        return 1
    fi

    print_status "success" "Dim Completed Calendar Events found"

    # Ensure the extension is enabled
    if command -v gnome-extensions &> /dev/null; then
        if ! gnome-extensions info "$EXT_UUID" 2>/dev/null | grep -q "ENABLED"; then
            print_status "info" "Enabling Dim Completed Calendar Events..."
            run_or_echo gnome-extensions enable "$EXT_UUID" 2>/dev/null || true
        fi
    fi

    print_status "success" "Calendar events extension configured"
    print_status "info" "Past events will appear dimmed, ongoing events highlighted"
    print_status "info" "Click the clock in the top bar to see your schedule"
}

main() {
    if [ "$EUID" -eq 0 ]; then
        print_status "error" "This script should NOT be run with sudo!"
        print_status "info" "Please run as: bash $0"
        exit 1
    fi
    
    print_status "info" "Starting Ubuntu appearance configuration"
    echo -e "${MAGENTA}========================================${NC}"
    
    set_dark_mode
    configure_terminal
    configure_mouse
    configure_dock
    set_ubuntu_ui_interface
    configure_workspaces
    apply_additional_tweaks
    configure_inactivity_time_lock
    configure_power_settings
    organize_app_folders
    configure_vitals
    configure_dim_calendar_events

    echo -e "${MAGENTA}========================================${NC}"
    print_status "success" "All appearance settings configured successfully!"
    print_status "info" "Changes should take effect immediately. If not, try logging out and back in."
    print_status "info" "Open 'Mostrar aplicativos' to see your organized folders!"
}

# Execute main only when the script is run directly. Sourcing this file (e.g.
# from a test or to access INSTALL_REGISTRY) must not trigger gsettings calls.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main
fi