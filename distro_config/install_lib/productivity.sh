#!/bin/bash
#
# distro_config/install_lib/productivity.sh
#
# Calendars, tasks, email, news, collaboration. Sourced by install_programs.sh.
# Depends on: print_status, command_exists, install_package, setup_flatpak,
#             check_internet, $PACKAGE_MANAGER, $INSTALL_CMD
#
# The PWA install functions (google_calendar, notion_calendar, google_tasks,
# valor_digital, linear, miro) share ~80% of their structure but are kept
# expanded for behavior-preserving migration. A future refactor could DRY
# them via a helper like create_pwa_desktop_entry(name, url, icon_src, cat).

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "productivity.sh is meant to be sourced, not executed." >&2
    exit 1
fi

# ============================================================================
# CHROME PWAs
# ============================================================================

install_google_calendar() {
    print_status "section" "GOOGLE CALENDAR"

    local desktop_dir="$HOME/.local/share/applications"
    local desktop_file="$desktop_dir/google-calendar.desktop"

    local script_root
    script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    local icon_src="$script_root/assets/google_calendar_app.png"
    local icon_theme_dir="$HOME/.local/share/icons/hicolor/256x256/apps"
    local icon_path="$icon_theme_dir/google-calendar.png"
    local icon_value="google-calendar"

    if [ -f "$desktop_file" ]; then
        print_status "info" "Google Calendar desktop entry already exists, updating"
    fi

    if ! command_exists google-chrome; then
        print_status "error" "Google Chrome not found. Google Calendar PWA requires Chrome."
        print_status "info" "Install Chrome first and re-run this step."
        return 1
    fi

    print_status "info" "Creating Google Calendar desktop entry..."
    run_or_echo mkdir -p "$desktop_dir"

    if [ -f "$icon_src" ]; then
        print_status "info" "Installing Google Calendar icon..."
        run_or_echo mkdir -p "$icon_theme_dir"
        cp "$icon_src" "$icon_path"
        if command_exists gtk-update-icon-cache; then
            run_or_echo gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
        fi
        if command_exists update-desktop-database; then
            run_or_echo update-desktop-database "$desktop_dir" 2>/dev/null || true
        fi
        if [ "${XDG_SESSION_TYPE:-}" = "x11" ] && command_exists gdbus; then
            gdbus call --session --dest org.gnome.Shell \
                --object-path /org/gnome/Shell \
                --method org.gnome.Shell.Eval \
                "global.reexec_self()" >/dev/null 2>&1 || true
        else
            print_status "info" "If the icon doesn't update, press Alt+F2 then 'r' (X11) or log out/in (Wayland)."
        fi
    else
        print_status "warning" "Google Calendar icon not found at $icon_src. Using default icon."
        icon_value="calendar"
    fi

    cat > "$desktop_file" << EOF
[Desktop Entry]
Name=Google Calendar
Exec=google-chrome --app=https://calendar.google.com
Terminal=false
Type=Application
Icon=${icon_value}
Categories=Office;Calendar;
EOF
    run_or_echo chmod +x "$desktop_file"

    if command_exists update-desktop-database; then
        run_or_echo update-desktop-database "$desktop_dir" 2>/dev/null || true
    fi

    print_status "success" "Google Calendar desktop entry created"
    print_status "info" "Google Calendar: Chrome PWA for calendar.google.com"
}

install_notion_calendar() {
    print_status "section" "NOTION CALENDAR"

    local desktop_dir="$HOME/.local/share/applications"
    local desktop_file="$desktop_dir/notion-calendar.desktop"

    local script_root
    script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    local icon_src="$script_root/assets/notion_calendar_app.png"
    local icon_theme_dir="$HOME/.local/share/icons/hicolor/256x256/apps"
    local icon_path="$icon_theme_dir/notion-calendar.png"
    local icon_value="notion-calendar"

    if [ -f "$desktop_file" ]; then
        print_status "info" "Notion Calendar desktop entry already exists, updating"
    fi

    if ! command_exists google-chrome; then
        print_status "error" "Google Chrome not found. Notion Calendar PWA requires Chrome."
        print_status "info" "Install Chrome first and re-run this step."
        return 1
    fi

    print_status "info" "Creating Notion Calendar desktop entry..."
    run_or_echo mkdir -p "$desktop_dir"

    if [ -f "$icon_src" ]; then
        print_status "info" "Installing Notion Calendar icon..."
        run_or_echo mkdir -p "$icon_theme_dir"
        cp "$icon_src" "$icon_path"
        if command_exists gtk-update-icon-cache; then
            run_or_echo gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
        fi
        if command_exists update-desktop-database; then
            run_or_echo update-desktop-database "$desktop_dir" 2>/dev/null || true
        fi
        if [ "${XDG_SESSION_TYPE:-}" = "x11" ] && command_exists gdbus; then
            gdbus call --session --dest org.gnome.Shell \
                --object-path /org/gnome/Shell \
                --method org.gnome.Shell.Eval \
                "global.reexec_self()" >/dev/null 2>&1 || true
        else
            print_status "info" "If the icon doesn't update, press Alt+F2 then 'r' (X11) or log out/in (Wayland)."
        fi
    else
        print_status "warning" "Notion Calendar icon not found at $icon_src. Using default icon."
        icon_value="calendar"
    fi

    cat > "$desktop_file" << EOF
[Desktop Entry]
Name=Notion Calendar
Exec=google-chrome --app=https://calendar.notion.so
Terminal=false
Type=Application
Icon=${icon_value}
Categories=Office;Calendar;
EOF
    run_or_echo chmod +x "$desktop_file"

    if command_exists update-desktop-database; then
        run_or_echo update-desktop-database "$desktop_dir" 2>/dev/null || true
    fi

    print_status "success" "Notion Calendar desktop entry created"
    print_status "info" "Notion Calendar: Chrome PWA for calendar.notion.so"
}

install_google_tasks() {
    print_status "section" "GOOGLE TASKS"

    local desktop_dir="$HOME/.local/share/applications"
    local desktop_file="$desktop_dir/google-tasks.desktop"

    local script_root
    script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    local icon_src="$script_root/assets/google_tasks_app.png"
    local icon_theme_dir="$HOME/.local/share/icons/hicolor/256x256/apps"
    local icon_path="$icon_theme_dir/google-tasks.png"
    local icon_value="google-tasks"

    if [ -f "$desktop_file" ]; then
        print_status "info" "Google Tasks desktop entry already exists, updating"
    fi

    if ! command_exists google-chrome; then
        print_status "error" "Google Chrome not found. Google Tasks PWA requires Chrome."
        print_status "info" "Install Chrome first and re-run this step."
        return 1
    fi

    print_status "info" "Creating Google Tasks desktop entry..."
    run_or_echo mkdir -p "$desktop_dir"

    if [ -f "$icon_src" ]; then
        print_status "info" "Installing Google Tasks icon..."
        run_or_echo mkdir -p "$icon_theme_dir"
        cp "$icon_src" "$icon_path"
        if command_exists gtk-update-icon-cache; then
            run_or_echo gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
        fi
        if command_exists update-desktop-database; then
            run_or_echo update-desktop-database "$desktop_dir" 2>/dev/null || true
        fi
        if [ "${XDG_SESSION_TYPE:-}" = "x11" ] && command_exists gdbus; then
            gdbus call --session --dest org.gnome.Shell \
                --object-path /org/gnome/Shell \
                --method org.gnome.Shell.Eval \
                "global.reexec_self()" >/dev/null 2>&1 || true
        else
            print_status "info" "If the icon doesn't update, press Alt+F2 then 'r' (X11) or log out/in (Wayland)."
        fi
    else
        print_status "warning" "Google Tasks icon not found at $icon_src. Using default icon."
        icon_value="emblem-default"
    fi

    cat > "$desktop_file" << EOF
[Desktop Entry]
Name=Google Tasks
Exec=google-chrome --app=https://tasks.google.com
Terminal=false
Type=Application
Icon=${icon_value}
Categories=Office;ProjectManagement;
EOF
    run_or_echo chmod +x "$desktop_file"

    if command_exists update-desktop-database; then
        run_or_echo update-desktop-database "$desktop_dir" 2>/dev/null || true
    fi

    print_status "success" "Google Tasks desktop entry created"
    print_status "info" "Google Tasks: Chrome PWA for tasks.google.com"
}

install_google_keep() {
    print_status "section" "GOOGLE KEEP (PWA)"

    # Google has never shipped a desktop Keep client on any platform — web only.
    install_chrome_pwa "Google Keep" "https://keep.google.com" "google-keep" \
        "google_keep_app.png" "Office;Utility;" 512
}

install_instapaper() {
    print_status "section" "INSTAPAPER (PWA)"

    # Instapaper is mobile + web only; no desktop client has ever existed.
    # Their largest published icon is 145px, so 128 is the nearest hicolor bucket.
    install_chrome_pwa "Instapaper" "https://www.instapaper.com" "instapaper" \
        "instapaper_app.png" "Office;News;Viewer;" 128
}

install_valor_digital() {
    print_status "section" "VALOR DIGITAL (VALOR ECONÔMICO)"

    local desktop_dir="$HOME/.local/share/applications"
    local desktop_file="$desktop_dir/valor-digital.desktop"

    local script_root
    script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    local icon_src="$script_root/assets/valor_app.png"
    local icon_theme_dir="$HOME/.local/share/icons/hicolor/256x256/apps"
    local icon_path="$icon_theme_dir/valor-digital.png"
    local icon_value="valor-digital"

    if [ -f "$desktop_file" ]; then
        print_status "info" "Valor Digital desktop entry already exists, updating"
    fi

    if ! command_exists google-chrome; then
        print_status "error" "Google Chrome not found. Valor Digital PWA requires Chrome."
        print_status "info" "Install Chrome first and re-run this step."
        return 1
    fi

    print_status "info" "Creating Valor Digital desktop entry..."
    run_or_echo mkdir -p "$desktop_dir"

    if [ -f "$icon_src" ]; then
        print_status "info" "Installing Valor Digital icon..."
        run_or_echo mkdir -p "$icon_theme_dir"
        cp "$icon_src" "$icon_path"
        if command_exists gtk-update-icon-cache; then
            run_or_echo gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
        fi
        if command_exists update-desktop-database; then
            run_or_echo update-desktop-database "$desktop_dir" 2>/dev/null || true
        fi
        if [ "${XDG_SESSION_TYPE:-}" = "x11" ] && command_exists gdbus; then
            gdbus call --session --dest org.gnome.Shell \
                --object-path /org/gnome/Shell \
                --method org.gnome.Shell.Eval \
                "global.reexec_self()" >/dev/null 2>&1 || true
        else
            print_status "info" "If the icon doesn't update, press Alt+F2 then 'r' (X11) or log out/in (Wayland)."
        fi
    else
        print_status "warning" "Valor Digital icon not found at $icon_src. Using default icon."
        icon_value="text-html"
    fi

    cat > "$desktop_file" << EOF
[Desktop Entry]
Name=Valor Digital
Exec=google-chrome --app=https://valor.globo.com/impresso/
Terminal=false
Type=Application
Icon=${icon_value}
Categories=News;
EOF
    run_or_echo chmod +x "$desktop_file"

    if command_exists update-desktop-database; then
        run_or_echo update-desktop-database "$desktop_dir" 2>/dev/null || true
    fi

    print_status "success" "Valor Digital desktop entry created"
    print_status "info" "Valor Digital: Chrome PWA for valor.globo.com/impresso"
}

install_linear() {
    print_status "section" "LINEAR"

    local desktop_dir="$HOME/.local/share/applications"
    local desktop_file="$desktop_dir/linear.desktop"

    local script_root
    script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    local icon_src="$script_root/assets/linear_app.png"
    local icon_theme_dir="$HOME/.local/share/icons/hicolor/256x256/apps"
    local icon_path="$icon_theme_dir/linear.png"
    local icon_value="linear"

    if [ -f "$desktop_file" ]; then
        print_status "info" "Linear desktop entry already exists, updating"
    fi

    if ! command_exists google-chrome; then
        print_status "warning" "Google Chrome not found. Linear desktop entry will still be created, but may not launch."
        print_status "info" "Install Chrome and re-run this step if needed."
    fi

    print_status "info" "Creating Linear desktop entry..."
    run_or_echo mkdir -p "$desktop_dir"

    if [ -f "$icon_src" ]; then
        print_status "info" "Installing Linear icon..."
        run_or_echo mkdir -p "$icon_theme_dir"
        cp "$icon_src" "$icon_path"
        icon_value="linear"
        if command_exists gtk-update-icon-cache; then
            run_or_echo gtk-update-icon-cache -f "$HOME/.local/share/icons" 2>/dev/null || true
        fi
        if [ "${XDG_SESSION_TYPE:-}" = "x11" ] && command_exists gdbus; then
            gdbus call --session --dest org.gnome.Shell \
                --object-path /org/gnome/Shell \
                --method org.gnome.Shell.Eval \
                "global.reexec_self()" >/dev/null 2>&1 || true
        else
            print_status "info" "If the icon doesn't update, press Alt+F2 then 'r' (X11) or log out/in (Wayland)."
        fi
    else
        print_status "warning" "Linear icon not found at $icon_src. Using default icon."
        icon_value="web-browser"
    fi

    cat > "$desktop_file" << EOF
[Desktop Entry]
Name=Linear
Exec=google-chrome --app=https://linear.app
Terminal=false
Type=Application
Icon=${icon_value}
Categories=Office;ProjectManagement;
EOF
    run_or_echo chmod +x "$desktop_file"

    if command_exists update-desktop-database; then
        run_or_echo update-desktop-database "$desktop_dir" 2>/dev/null || true
    fi

    print_status "success" "Linear desktop entry created"
}

# ============================================================================
# COLLABORATION
# ============================================================================

install_miro() {
    print_status "section" "MIRO"

    if snap list | grep -q miro; then
        print_status "info" "Miro already installed"
        return 0
    fi

    case "$PACKAGE_MANAGER" in
        apt|dnf|yum|zypper)
            if command_exists snap; then
                print_status "info" "Installing Miro via Snap..."
                run_or_echo sudo snap install miro
                print_status "success" "Miro installed via Snap"
            else
                print_status "warning" "Snap not available. Installing Miro via Flatpak..."
                if command_exists flatpak; then
                    run_or_echo flatpak install -y flathub com.miro.Miro
                    print_status "success" "Miro installed via Flatpak"
                else
                    print_status "error" "Neither Snap nor Flatpak available. Please install one first."
                    return 1
                fi
            fi
            ;;
        pacman)
            if command_exists flatpak; then
                print_status "info" "Installing Miro via Flatpak..."
                run_or_echo flatpak install -y flathub com.miro.Miro
                print_status "success" "Miro installed via Flatpak"
            elif command_exists yay; then
                print_status "info" "Installing Miro from AUR..."
                run_or_echo yay -S --noconfirm miro-bin || yay -S --noconfirm miro
                print_status "success" "Miro installed from AUR"
            else
                print_status "warning" "Please install Miro manually from AUR or via Flatpak"
                return 1
            fi
            ;;
    esac
}

# ============================================================================
# DESIGN
# ============================================================================

# figma-linux (publisher: Chugunov Roman / "youdonthavepermissiony", GPL-2.0,
# description literally "Unofficial desktop application for linux") — there is
# no official Figma desktop client for Linux. This is a community snap, not a
# Figma Inc. product. Keep it as snap (method #4 in the "App Installation
# Preference Order" below), NOT the PWA (#5): the PWA has no Linux font
# helper, and the local-fonts symlink below is the entire reason to prefer
# this over the browser tab. Do not "fix" this to the PWA without re-reading
# this comment.
install_figma() {
    print_status "section" "FIGMA (figma-linux snap — unofficial community client)"

    if command_exists figma-linux || snap list 2>/dev/null | grep -q "^figma-linux "; then
        print_status "info" "figma-linux already installed"
    else
        if ! command_exists snap; then
            print_status "error" "snap not found. figma-linux requires snapd."
            print_status "info" "Install snapd first and re-run this step."
            return 1
        fi

        print_status "info" "Installing figma-linux via Snap..."
        run_or_echo sudo snap install figma-linux
        print_status "success" "figma-linux installed via Snap"
    fi

    _link_figma_fonts
}

# The snap's $HOME/snap/figma-linux/current symlink (to the current revision
# dir) is created by snapd only after the app's FIRST launch, so this cannot
# run immediately after `snap install` — it no-ops until figma-linux has been
# opened once, and is safe to re-run afterward (ln -sfn is idempotent). No
# sudo: the target lives inside the user's own $HOME, and a root-owned
# symlink there is a footgun for later.
_link_figma_fonts() {
    local snap_current="$HOME/snap/figma-linux/current"
    local target_dir="$snap_current/.local/share"
    local target="$target_dir/fonts"
    local source="$HOME/.local/share/fonts"

    if [ ! -d "$snap_current" ]; then
        print_status "info" "figma-linux snap has not been launched yet — skipping local-fonts symlink"
        print_status "config" "Launch figma-linux once, then re-run install_figma to link $source"
        return 0
    fi

    if [ -L "$target" ] && [ "$(readlink -f "$target")" = "$(readlink -f "$source")" ]; then
        print_status "info" "figma-linux fonts already symlinked"
        return 0
    fi

    run_or_echo mkdir -p "$target_dir"
    run_or_echo ln -sfn "$source" "$target"
    print_status "success" "Linked $source into the figma-linux snap sandbox"
}

# ============================================================================
# MESSAGING
# ============================================================================

install_telegram() {
    print_status "section" "TELEGRAM"

    if command_exists telegram-desktop || flatpak list 2>/dev/null | grep -q "org.telegram.desktop"; then
        print_status "info" "Telegram already installed"
        return 0
    fi

    setup_flatpak

    print_status "info" "Installing Telegram via Flatpak..."
    run_or_echo flatpak install -y flathub org.telegram.desktop
    print_status "success" "Telegram installed"
    print_status "config" "Launch: flatpak run org.telegram.desktop"
}

# ============================================================================
# EMAIL / NEWS
# ============================================================================

install_thunderbird() {
    print_status "section" "THUNDERBIRD EMAIL CLIENT"

    if command_exists thunderbird || flatpak list 2>/dev/null | grep -q "org.mozilla.Thunderbird"; then
        print_status "info" "Thunderbird already installed"
        return 0
    fi

    case "$PACKAGE_MANAGER" in
        apt|dnf|yum|pacman)
            print_status "info" "Installing Thunderbird via $PACKAGE_MANAGER..."
            $INSTALL_CMD thunderbird
            print_status "success" "Thunderbird installed"
            ;;
        zypper)
            print_status "info" "Installing Thunderbird via zypper..."
            $INSTALL_CMD MozillaThunderbird
            print_status "success" "Thunderbird installed"
            ;;
        *)
            if command_exists flatpak; then
                print_status "info" "Installing Thunderbird via Flatpak..."
                run_or_echo flatpak install -y flathub org.mozilla.Thunderbird
                print_status "success" "Thunderbird installed via Flatpak"
            else
                print_status "error" "Could not install Thunderbird. Please install manually."
                return 1
            fi
            ;;
    esac

    print_status "success" "Thunderbird email client is ready to use"
    print_status "info" "Thunderbird: Free, open-source email client by Mozilla"
    print_status "config" "Launch with: thunderbird"
}

install_newsflash() {
    print_status "section" "NEWSFLASH RSS READER"

    if flatpak list 2>/dev/null | grep -q "io.gitlab.news_flash.NewsFlash"; then
        print_status "info" "NewsFlash already installed"
        return 0
    fi

    setup_flatpak

    print_status "info" "Installing NewsFlash via Flatpak..."
    run_or_echo flatpak install -y flathub io.gitlab.news_flash.NewsFlash
    print_status "success" "NewsFlash installed"
    print_status "config" "Launch: flatpak run io.gitlab.news_flash.NewsFlash"
}

# ============================================================================
# WEATHER
# ============================================================================

install_mousam() {
    print_status "section" "MOUSAM WEATHER APP"

    if flatpak list 2>/dev/null | grep -q "io.github.amit9838.mousam"; then
        print_status "info" "Mousam already installed"
        return 0
    fi

    setup_flatpak

    print_status "info" "Installing Mousam via Flatpak..."
    run_or_echo flatpak install -y flathub io.github.amit9838.mousam
    print_status "success" "Mousam installed"
    print_status "config" "Launch: flatpak run io.github.amit9838.mousam"
}

# ============================================================================
# EMAIL FILE VIEWER
# ============================================================================

install_mailviewer() {
    print_status "section" "MAILVIEWER (.eml/.msg viewer)"

    if flatpak list 2>/dev/null | grep -q "io.github.alescdb.mailviewer"; then
        print_status "info" "MailViewer already installed"
        return 0
    fi

    setup_flatpak

    print_status "info" "Installing MailViewer via Flatpak..."
    run_or_echo flatpak install -y flathub io.github.alescdb.mailviewer
    print_status "success" "MailViewer installed"
    print_status "config" "Launch: flatpak run io.github.alescdb.mailviewer"
}

# ============================================================================
# ESPANSO (TEXT EXPANDER)
# ============================================================================

install_espanso() {
    print_status "section" "ESPANSO (Text Expander)"

    if command_exists espanso; then
        print_status "success" "espanso is already installed: $(espanso --version 2>/dev/null || echo '')"
        return 0
    fi

    if ! check_internet; then
        print_status "error" "Internet connection required to install espanso"
        print_status "warning" "Skipping espanso installation due to no internet"
        return 1
    fi

    print_status "info" "Installing espanso using the official installer..."

    if command_exists curl; then
        if curl -sS https://get.espanso.org/install.sh | sh; then
            print_status "success" "espanso installer finished"
        else
            print_status "warning" "espanso installer script failed, attempting package fallback"
        fi
    else
        print_status "info" "curl not found; installing curl and retrying installer"
        install_package curl curl curl curl
        if command_exists curl; then
            curl -sS https://get.espanso.org/install.sh | sh || true
        fi
    fi

    if ! command_exists espanso && [ "$PACKAGE_MANAGER" = "apt" ]; then
        print_status "info" "Attempting Debian .deb installation as fallback (requires sudo)"
        local session_type="${XDG_SESSION_TYPE:-}"
        session_type="${session_type,,}"
        if [ -z "$session_type" ]; then
            session_type=$(loginctl show-user "$USER" --property=Display | cut -d= -f2 2>/dev/null || true)
            session_type="${session_type,,}"
        fi
        if [ "$session_type" != "wayland" ]; then
            session_type="x11"
        fi

        local tmp_dir
        tmp_dir=$(mktemp -d)
        cd "$tmp_dir" || true
        local deb_url="https://github.com/espanso/espanso/releases/latest/download/espanso-debian-${session_type}-amd64.deb"
        print_status "info" "Downloading: $deb_url"
        run_or_echo wget --tries=3 --quiet -O espanso.deb "$deb_url" || curl -L --retry 3 -o espanso.deb "$deb_url" || true
        if [ -s espanso.deb ]; then
            print_status "info" "Installing espanso .deb (requires sudo)"
            sudo apt update || true
            run_or_echo sudo apt install -y ./espanso.deb || true
        else
            print_status "warning" "Could not download espanso .deb from $deb_url"
        fi
        cd - >/dev/null 2>&1 || true
        rm -rf "$tmp_dir"
    fi

    if ! command_exists espanso; then
        print_status "info" "Attempting AppImage fallback (will place in ~/opt)"
        run_or_echo mkdir -p "$HOME/opt"
        local app_image_url="https://github.com/espanso/espanso/releases/latest/download/Espanso-X11.AppImage"
        local app_image_path="$HOME/opt/Espanso.AppImage"
        run_or_echo wget --tries=3 -q -O "$app_image_path" "$app_image_url" || curl -L --retry 3 -o "$app_image_path" "$app_image_url" || true
        if [ -s "$app_image_path" ]; then
            chmod u+x "$app_image_path" || true
            "$app_image_path" env-path register || true
        else
            print_status "warning" "AppImage fallback failed to download"
        fi
    fi

    if command_exists espanso; then
        print_status "success" "espanso installed: $(espanso --version 2>/dev/null || echo '')"
        if command_exists setcap && command_exists espanso; then
            run_or_echo sudo setcap "cap_dac_override+p" "$(command -v espanso)" 2>/dev/null || true
        fi
        if command_exists espanso; then
            espanso service register 2>/dev/null || true
            espanso start 2>/dev/null || true
        fi
    else
        print_status "warning" "espanso installation failed or binary not found in PATH"
        print_status "info" "Manual options:"
        print_status "config" "  - Use official installer: curl -sS https://get.espanso.org/install.sh | sh"
        print_status "config" "  - Download .deb: wget https://github.com/espanso/espanso/releases/latest/download/espanso-debian-x11-amd64.deb && sudo apt install ./espanso-debian-x11-amd64.deb"
        print_status "config" "  - Or install the AppImage into ~/opt and run: ~/opt/Espanso.AppImage env-path register"
        return 1
    fi
}

# ============================================================================
# REGISTRY
# ============================================================================

INSTALL_REGISTRY+=(
    "install_telegram:Telegram:Social:org.telegram.desktop.desktop"
    "install_thunderbird:Thunderbird Email Client:Social:thunderbird.desktop"
    "install_newsflash:NewsFlash RSS Reader:Reading:io.gitlab.news_flash.NewsFlash.desktop"
    "install_google_calendar:Google Calendar (PWA):Planning:google-calendar.desktop"
    "install_notion_calendar:Notion Calendar (PWA):Planning:notion-calendar.desktop"
    "install_google_tasks:Google Tasks (PWA):Planning:google-tasks.desktop"
    "install_google_keep:Google Keep (PWA):Planning:google-keep.desktop"
    "install_instapaper:Instapaper (PWA):Reading:instapaper.desktop"
    "install_valor_digital:Valor Digital (Valor Econômico):Reading:valor-digital.desktop"
    "install_linear:Linear (Project Management):Planning:linear.desktop"
    "install_miro:Miro Collaboration Tool:Planning:miro_miro.desktop"
    "install_figma:Figma (via figma-linux snap, unofficial):Design:figma-linux_figma-linux.desktop"
    "install_mousam:Mousam Weather App:Utilitarios:io.github.amit9838.mousam.desktop"
    "install_mailviewer:MailViewer (.eml/.msg viewer):Utilitarios:io.github.alescdb.mailviewer.desktop"
    "install_espanso:Espanso (Text Expander)::"
)
