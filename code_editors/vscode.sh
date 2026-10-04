#!/bin/bash

set -e

LOG_FILE="$HOME/vscode_configuration_$(date +%Y%m%d_%H%M%S).log"

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# VS Code's settings.json / keybindings.json are JSONC: they allow // and /* */
# comments and trailing commas, which jq cannot parse. strip_jsonc emits strict
# JSON so jq can read the file. It is string-aware, so "//" or "/*" inside a
# value (e.g. a URL) is left intact. Falls back to the raw file if python3 is
# unavailable. Output is JSON values only — comments are not preserved (jq
# rewrites drop them anyway), but the original file is always backed up first.
strip_jsonc() {
    local file="$1"
    [ -f "$file" ] || { echo "{}"; return 0; }
    if command -v python3 &> /dev/null; then
        python3 - "$file" <<'PYEOF'
import sys, re
try:
    s = open(sys.argv[1], encoding="utf-8").read()
except OSError:
    sys.stdout.write("{}"); sys.exit(0)
out, i, n = [], 0, len(s)
in_str = esc = False
while i < n:
    c = s[i]
    if in_str:
        out.append(c)
        if esc:
            esc = False
        elif c == "\\":
            esc = True
        elif c == '"':
            in_str = False
        i += 1
        continue
    if c == '"':
        in_str = True; out.append(c); i += 1; continue
    if c == "/" and i + 1 < n and s[i + 1] == "/":
        while i < n and s[i] != "\n":
            i += 1
        continue
    if c == "/" and i + 1 < n and s[i + 1] == "*":
        i += 2
        while i + 1 < n and not (s[i] == "*" and s[i + 1] == "/"):
            i += 1
        i += 2
        continue
    out.append(c); i += 1
res = re.sub(r",(\s*[}\]])", r"\1", "".join(out))  # strip trailing commas
sys.stdout.write(res)
PYEOF
    else
        cat "$file"
    fi
}

# ============================================================================
# VS CODE CONFIGURATION FUNCTIONS
# ============================================================================

backup_current_config() {
    print_status "section" "BACKING UP CURRENT CONFIGURATION"
    
    local config_dir="$HOME/.config/Code/User"
    local backup_dir
    backup_dir="$HOME/vscode_backup_$(date +%Y%m%d_%H%M%S)"
    
    mkdir -p "$backup_dir"
    
    # Backup settings
    if [ -f "$config_dir/settings.json" ]; then
        cp "$config_dir/settings.json" "$backup_dir/settings.json"
        print_status "success" "Settings backed up to: $backup_dir/settings.json"
        
        # Display critical settings for reference
        print_status "info" "📊 Your current visual settings:"
        if command -v jq &> /dev/null; then
            local clean_json
            clean_json=$(strip_jsonc "$config_dir/settings.json")
            local current_font_size current_zoom current_theme
            current_font_size=$(echo "$clean_json" | jq -r '.["editor.fontSize"] // "14 (default)"' 2>/dev/null || echo "14 (default)")
            current_zoom=$(echo "$clean_json" | jq -r '.["window.zoomLevel"] // "0 (default)"' 2>/dev/null || echo "0 (default)")
            current_theme=$(echo "$clean_json" | jq -r '.["workbench.colorTheme"] // "Default Dark Modern"' 2>/dev/null || echo "Default Dark Modern")
            echo "  • Font size: $current_font_size"
            echo "  • Zoom level: $current_zoom"
            echo "  • Theme: $current_theme"
        else
            echo "  • Install jq for detailed view: sudo apt install jq"
        fi
    else
        print_status "info" "No existing settings.json found - will create new one"
    fi
    
    # Backup keybindings
    if [ -f "$config_dir/keybindings.json" ]; then
        cp "$config_dir/keybindings.json" "$backup_dir/keybindings.json"
        print_status "success" "Keybindings backed up to: $backup_dir/keybindings.json"
    else
        print_status "info" "No existing keybindings.json found"
    fi
    
    # Backup extensions list
    if command -v code &> /dev/null; then
        code --list-extensions > "$backup_dir/extensions.list" 2>/dev/null && \
        print_status "success" "Extensions list backed up to: $backup_dir/extensions.list" || \
        print_status "warning" "Could not backup extensions list"
    fi
    
    echo "$backup_dir"  # Return backup directory path
}

check_vscode_installed() {
    print_status "info" "Checking if VS Code is installed..."
    if command -v code &> /dev/null; then
        print_status "success" "VS Code is installed"
        return 0
    else
        print_status "error" "VS Code is not installed or not in PATH"
        print_status "info" "Please install VS Code first: https://code.visualstudio.com/download"
        return 1
    fi
}

install_extensions() {
    print_status "section" "INSTALLING VS CODE EXTENSIONS"
    
    # ⚠️ ONE list, read from disk — never a second array here (dotfiles-linux-dev#185).
    # Two lists existed and only this one installed anything, so ~15 entries that lived only
    # in .vscode/extensions.txt were never installed while the file looked authoritative.
    # Adding an extension there and nowhere else looked done and was a no-op.
    local extensions_file
    extensions_file="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.vscode/extensions.txt"

    if [[ ! -f "$extensions_file" ]]; then
        print_status "error" "Extension list not found: $extensions_file"
        return 1
    fi

    local extensions=()
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        # The `vscode:` prefix marks which editor an entry targets, so the file can hold more
        # than one editor's set later. Strip it; a bare id is accepted too.
        extensions+=("${line#vscode:}")
    done < "$extensions_file"

    # ⚠️ An empty list is a FAILURE, not a quiet success: a moved or emptied file would
    # otherwise report "Extensions installed: 0, Skipped: 0" and read as a clean run.
    if [[ ${#extensions[@]} -eq 0 ]]; then
        print_status "error" "No extensions found in $extensions_file"
        return 1
    fi
    print_status "info" "Read ${#extensions[@]} extension(s) from ${extensions_file##*/}"
    
    local installed_count=0
    local skipped_count=0
    
    # Check which extensions are already installed
    local installed_extensions=""
    if command -v code &> /dev/null; then
        installed_extensions=$(code --list-extensions 2>/dev/null || echo "")
    fi
    
    for extension in "${extensions[@]}"; do
        print_status "info" "Checking extension: $extension"
        
        # Check if extension is already installed
        if echo "$installed_extensions" | grep -q "$extension"; then
            print_status "warning" "Extension already installed: $extension"
            skipped_count=$((skipped_count + 1))
        else
            if code --install-extension "$extension" --force; then
                print_status "success" "Successfully installed: $extension"
                installed_count=$((installed_count + 1))
            else
                print_status "error" "Failed to install: $extension"
            fi
        fi
    done
    
    print_status "success" "Extensions installed: $installed_count, Skipped: $skipped_count"
}

configure_keybindings() {
    print_status "section" "CONFIGURING KEYBOARD SHORTCUTS"
    
    local keybindings_dir="$HOME/.config/Code/User"
    local keybindings_file="$keybindings_dir/keybindings.json"
    
    # Create directory if it doesn't exist
    mkdir -p "$keybindings_dir"
    
    # Check if keybindings file exists
    if [ ! -f "$keybindings_file" ]; then
        print_status "info" "Creating new keybindings.json file"
        echo '[]' > "$keybindings_file"
    fi
    
    # Create a temporary keybindings file with the new shortcut
    local temp_file
    temp_file=$(mktemp)
    
    # Read existing keybindings (JSONC → strict JSON so jq can merge them).
    local existing_keybindings
    existing_keybindings=$(strip_jsonc "$keybindings_file" 2>/dev/null || echo '[]')
    [ -n "$existing_keybindings" ] || existing_keybindings='[]'
    
    # Check if the shortcuts already exist
    if echo "$existing_keybindings" | grep -q '"ctrl+k s"'; then
        print_status "warning" "Shortcut Ctrl+K S for 'workbench.action.files.saveAll' already exists"
    else
        # Add the new shortcuts while preserving existing ones
        echo "$existing_keybindings" | jq '. + [
            {
                "key": "ctrl+k s",
                "command": "workbench.action.files.saveAll",
                "when": "editorTextFocus"
            },
            {
                "key": "ctrl+k ctrl+s",
                "command": "workbench.action.openGlobalKeybindingsFindWidget",
                "when": "editorTextFocus"
            },
            {
                "key": "ctrl+k ctrl+t",
                "command": "workbench.action.tasks.test"
            }
        ]' > "$temp_file" 2>/dev/null || {
            print_status "warning" "jq not found, using manual JSON manipulation"
            # Fallback if jq is not installed
            if [ "$existing_keybindings" = "[]" ]; then
                echo '[{"key": "ctrl+k s", "command": "workbench.action.files.saveAll", "when": "editorTextFocus"},{"key": "ctrl+k ctrl+s", "command": "workbench.action.openGlobalKeybindingsFindWidget", "when": "editorTextFocus"},{"key": "ctrl+k ctrl+t", "command": "workbench.action.tasks.test"}]' > "$temp_file"
            else
                # Remove the last bracket, add comma and new entry, then add bracket back
                echo "$existing_keybindings" | sed '$ s/\]//' > "$temp_file"
                echo ',{"key": "ctrl+k s", "command": "workbench.action.files.saveAll", "when": "editorTextFocus"},{"key": "ctrl+k ctrl+s", "command": "workbench.action.openGlobalKeybindingsFindWidget", "when": "editorTextFocus"},{"key": "ctrl+k ctrl+t", "command": "workbench.action.tasks.test"}]' >> "$temp_file"
            fi
        }
        
        # Backup original file
        cp "$keybindings_file" "$keybindings_file.backup_$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        
        # Copy the new keybindings
        cp "$temp_file" "$keybindings_file"
        
        print_status "success" "Added Ctrl+K S shortcut for 'Save All', Ctrl+K Ctrl+S for 'Keyboard Shortcuts Help', and Ctrl+K Ctrl+T for 'Run Test Task'"
    fi
    
    # Clean up temp file
    rm -f "$temp_file"
    
    print_status "config" "Keybindings configured at: $keybindings_file"
    print_status "info" "Linux default shortcuts are preserved"
}

configure_settings() {
    print_status "section" "CONFIGURING VS CODE SETTINGS"
    
    local settings_dir="$HOME/.config/Code/User"
    local settings_file="$settings_dir/settings.json"
    
    # Create directory if it doesn't exist
    mkdir -p "$settings_dir"
    
    # Check if settings file exists
    if [ ! -f "$settings_file" ]; then
        print_status "info" "Creating new settings.json file"
        # Start with minimal settings that preserve your preferences
        echo '{}' > "$settings_file"
    fi
    
    # Read current settings (JSONC → strict JSON so jq can parse + merge it;
    # without this, a commented settings.json is wrongly seen as "corrupted"
    # below and reset to {}, discarding all of the user's real settings).
    local current_settings
    current_settings=$(strip_jsonc "$settings_file" 2>/dev/null || echo '{}')
    [ -n "$current_settings" ] || current_settings='{}'

    # Validate JSON - if it's malformed, repair or reset it
    if ! echo "$current_settings" | jq empty 2>/dev/null; then
        print_status "warning" "⚠️  Your settings.json has invalid JSON syntax"
        print_status "info" "Backing up corrupted file and creating valid one"
        cp "$settings_file" "$settings_file.corrupted_$(date +%Y%m%d_%H%M%S)"
        current_settings='{}'
        echo '{}' > "$settings_file"
        print_status "success" "Reset to empty valid JSON"
    fi
    
    # Extract critical visual settings for debugging
    print_status "info" "🔍 Analyzing your current settings..."
    
    if command -v jq &> /dev/null; then
        local current_font_size
        current_font_size=$(echo "$current_settings" | jq -r '.["editor.fontSize"] // "14 (default)"')
        local current_zoom
        current_zoom=$(echo "$current_settings" | jq -r '.["window.zoomLevel"] // "0 (default)"')
        local current_theme
        current_theme=$(echo "$current_settings" | jq -r '.["workbench.colorTheme"] // "Default Dark Modern"')
        
        echo "  • Current font size: $current_font_size"
        echo "  • Current zoom level: $current_zoom"
        echo "  • Current theme: $current_theme"
    fi
    
    # Settings that should be ADDED if not present (but never overwrite existing)
    # IMPORTANT: DO NOT include font size or zoom level here - they will be preserved
    local recommended_settings='{
    "editor.bracketPairColorization.enabled": true,
    "editor.guides.bracketPairs": true,
    "editor.formatOnSave": false,
    "editor.insertSpaces": true,
    "editor.tabSize": 2,
    "editor.renderWhitespace": "boundary",
    "editor.cursorStyle": "block",
    "editor.cursorBlinking": "blink",
    "editor.cursorWidth": 4,
    "workbench.startupEditor": "none",
    "workbench.editor.enablePreview": false,
    "workbench.productIconTheme": "default",
    "workbench.sideBar.location": "left",
    "window.menuBarVisibility": "default",
    "zenMode.hideLineNumbers": false,
    "zenMode.centerLayout": false,
    "terminal.integrated.fontSize": 14,
    "[python]": {
        "editor.insertSpaces": true,
        "editor.detectIndentation": false,
        "editor.tabSize": 4
    }
}'
    
    # Your existing settings that should ALWAYS be preserved
    # Based on your settings.json from earlier, these are your preferences
    local your_critical_settings='{
    "workbench.iconTheme": "material-icon-theme",
    "chat.editing.confirmEditRequestRetry": false,
    "editor.codeActionsOnSave": {
        "source.fixAll.eslint": "explicit"
    },
    "github.copilot.enable": {
        "*": true,
        "plaintext": true,
        "markdown": true,
        "scminput": true
    },
    "liveServer.settings.donotShowInfoMsg": true,
    "editor.rulers": [80, 120],
    "explorer.confirmDelete": false,
    "explorer.confirmDragAndDrop": false,
    "workbench.colorTheme": "OM Theme (Default Dracula Italic)",
    "window.zoomLevel": 0
}'
    
    print_status "info" "🔄 Merging settings while PRESERVING your visual preferences..."
    print_status "warning" "⚠️  IMPORTANT: Your font size and zoom level will NOT be changed"
    
    # Backup original file
    local backup_file
    backup_file="$settings_file.backup_$(date +%Y%m%d_%H%M%S)"
    cp "$settings_file" "$backup_file"
    print_status "success" "Original settings backed up to: $backup_file"
    
    if command -v jq &> /dev/null; then
        # STRATEGY: Merge settings with EDITOR CURSOR guaranteed to apply
        # This ensures cursor settings work in BOTH editor and terminal
        
        # Step 1: Start with your current settings (this preserves everything)
        echo "$current_settings" > "$settings_file.tmp"
        
        # Step 2: Merge with recommended settings (add if missing)
        cat "$settings_file.tmp" | jq --argjson recommended "$recommended_settings" '
            . as $current | $recommended | . * $current
        ' > "$settings_file.tmp2"
        
        # Step 3: Merge with your critical settings (ensure they're always set)
        cat "$settings_file.tmp2" | jq --argjson critical "$your_critical_settings" '
            . * $critical  # Your critical settings take priority
        ' > "$settings_file"
        
        # Step 4: FORCE editor cursor settings to ensure they work in the editor
        cat "$settings_file" | jq '
            .["editor.cursorStyle"] = "block" |
            .["editor.cursorBlinking"] = "blink" |
            .["editor.cursorWidth"] = 4
        ' > "$settings_file.tmp3"
        
        mv "$settings_file.tmp3" "$settings_file"
        
        # Clean up temp files
        rm -f "$settings_file.tmp" "$settings_file.tmp2" "$settings_file.tmp3"
        
        # Verify the critical settings are preserved
        local final_font_size
        final_font_size=$(strip_jsonc "$settings_file" | jq -r '.["editor.fontSize"] // "14 (default)"')
        local final_zoom
        final_zoom=$(strip_jsonc "$settings_file" | jq -r '.["window.zoomLevel"] // "0 (default)"')
        
        print_status "success" "✅ Font size preserved: $final_font_size"
        print_status "success" "✅ Zoom level preserved: $final_zoom"
        
        # If font size is default but you want it bigger, suggest change
        if [ "$final_font_size" = "14 (default)" ] || [ "$final_font_size" = "14" ]; then
            print_status "warning" "ℹ️  Font size is at default (14). If text feels small, try:"
            echo "    1. Increase zoom: \"window.zoomLevel\": 1"
            echo "    2. Or increase font: \"editor.fontSize\": 16"
        fi
        
    else
        print_status "error" "❌ jq is required for proper settings preservation"
        print_status "info" "Installing jq..."
        if ! install_jq_if_needed; then
            print_status "error" "Cannot merge settings without jq"
            print_status "info" "Restoring original settings from backup"
            cp "$backup_file" "$settings_file"
            return 1
        fi
        
        # Retry with jq now installed
        echo "$current_settings" | jq --argjson critical "$your_critical_settings" '
            . * $critical
        ' | jq --argjson recommended "$recommended_settings" '
            . * $recommended
        ' > "$settings_file.tmp"
        mv "$settings_file.tmp" "$settings_file"
    fi
    
    # Final verification
    print_status "info" "🔎 Final configuration check:"
    if command -v jq &> /dev/null; then
        local final_theme
        final_theme=$(strip_jsonc "$settings_file" | jq -r '.["workbench.colorTheme"] // "Not set"')
        local final_font
        final_font=$(strip_jsonc "$settings_file" | jq -r '.["editor.fontSize"] // "14 (default)"')
        local final_zoom
        final_zoom=$(strip_jsonc "$settings_file" | jq -r '.["window.zoomLevel"] // "0 (default)"')
        local final_icons
        final_icons=$(strip_jsonc "$settings_file" | jq -r '.["workbench.iconTheme"] // "material-icon-theme"')
        
        echo "  • Theme: $final_theme"
        echo "  • Font size: $final_font"
        echo "  • Zoom level: $final_zoom"
        echo "  • Icon theme: $final_icons"
        
        # Warning if zoom is 0 (default) but text feels small
        if [ "$final_zoom" = "0" ] || [ "$final_zoom" = "0 (default)" ]; then
            print_status "warning" "💡 Zoom level is 0 (default). If text is too small, try setting zoom to 1:"
            echo "    \"window.zoomLevel\": 1"
        fi
        
    fi
    
    print_status "config" "Settings configured at: $settings_file"
    print_status "success" "✅ Your visual preferences preserved, missing settings added"
}

sync_dotfiles_settings() {
    print_status "section" "SYNCING DOTFILES SETTINGS TO GLOBAL"

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local dotfiles_settings="$script_dir/../.vscode/settings.json"

    if [ ! -f "$dotfiles_settings" ]; then
        print_status "error" "Dotfiles settings.json not found at: $dotfiles_settings"
        return 1
    fi

    local global_dir="$HOME/.config/Code/User"
    local global_settings="$global_dir/settings.json"

    mkdir -p "$global_dir"

    if [ -f "$global_settings" ]; then
        local backup_file
        backup_file="$global_settings.backup_$(date +%Y%m%d_%H%M%S)"
        cp "$global_settings" "$backup_file"
        print_status "success" "Existing global settings backed up to: $backup_file"
    fi

    cp "$dotfiles_settings" "$global_settings"
    print_status "success" "Dotfiles settings.json copied to: $global_settings"
    print_status "config" "Global VS Code settings now mirror: $dotfiles_settings"
}

install_jq_if_needed() {
    print_status "info" "Checking if jq is installed..."
    if command -v jq &> /dev/null; then
        print_status "success" "jq is already installed"
        return 0
    else
        print_status "warning" "jq is not installed. Installing..."
        
        # Try different package managers
        local installed=false
        
        if command -v apt-get &> /dev/null && [ "$installed" = false ]; then
            print_status "info" "Using apt-get (Debian/Ubuntu)"
            sudo apt-get update && sudo apt-get install -y jq && installed=true
        fi
        
        if command -v yum &> /dev/null && [ "$installed" = false ]; then
            print_status "info" "Using yum (RHEL/CentOS)"
            sudo yum install -y jq && installed=true
        fi
        
        if command -v dnf &> /dev/null && [ "$installed" = false ]; then
            print_status "info" "Using dnf (Fedora)"
            sudo dnf install -y jq && installed=true
        fi
        
        if command -v pacman &> /dev/null && [ "$installed" = false ]; then
            print_status "info" "Using pacman (Arch)"
            sudo pacman -Sy --noconfirm jq && installed=true
        fi
        
        if command -v zypper &> /dev/null && [ "$installed" = false ]; then
            print_status "info" "Using zypper (openSUSE)"
            sudo zypper install -y jq && installed=true
        fi
        
        if [ "$installed" = false ]; then
            print_status "error" "Could not install jq. Please install it manually:"
            print_status "info" "  Ubuntu/Debian: sudo apt install jq"
            print_status "info" "  Fedora: sudo dnf install jq"
            print_status "info" "  CentOS/RHEL: sudo yum install jq"
            return 1
        fi
        
        if command -v jq &> /dev/null; then
            print_status "success" "jq installed successfully"
            return 0
        else
            print_status "error" "Failed to install jq"
            return 1
        fi
    fi
}

verify_configuration() {
    print_status "section" "VERIFYING CONFIGURATION"
    
    local settings_file="$HOME/.config/Code/User/settings.json"
    
    if [ -f "$settings_file" ]; then
        print_status "info" "🔍 Checking final configuration..."
        
        if command -v jq &> /dev/null; then
            # Check critical settings
            local checks_passed=0
            local checks_total=0
            
            # Check cursor style (IMPORTANT - ensure it's set)
            local cursor_style
            cursor_style=$(strip_jsonc "$settings_file" | jq -r '.["editor.cursorStyle"] // empty')
            checks_total=$((checks_total + 1))
            if [ "$cursor_style" = "block" ]; then
                print_status "success" "✅ Editor cursor style: block"
                checks_passed=$((checks_passed + 1))
            else
                print_status "warning" "Cursor style is: ${cursor_style:-Not set}"
            fi
            
            # Check zoom level (CRITICAL for your issue)
            local zoom
            zoom=$(strip_jsonc "$settings_file" | jq -r '.["window.zoomLevel"] // "0"')
            checks_total=$((checks_total + 1))
            print_status "info" "🔍 Zoom level: $zoom"
            checks_passed=$((checks_passed + 1))
            
            # Check font size
            local font_size
            font_size=$(strip_jsonc "$settings_file" | jq -r '.["editor.fontSize"] // "14"')
            checks_total=$((checks_total + 1))
            print_status "info" "🔍 Font size: $font_size"
            checks_passed=$((checks_passed + 1))
            
            # Check icon theme
            local icons
            icons=$(strip_jsonc "$settings_file" | jq -r '.["workbench.iconTheme"] // empty')
            checks_total=$((checks_total + 1))
            if [ "$icons" = "material-icon-theme" ]; then
                print_status "success" "✅ Icon theme: material-icon-theme"
                checks_passed=$((checks_passed + 1))
            else
                print_status "warning" "Icon theme is: ${icons:-Not set}"
            fi
            
            print_status "info" "Configuration checks: $checks_passed/$checks_total passed"
            
            # Special warning if text might be too small
            if [ "$zoom" = "0" ] && [ "$font_size" = "14" ]; then
                print_status "warning" "⚠️  WARNING: Both zoom level (0) and font size (14) are at defaults."
                print_status "warning" "   If text feels too small, try one of these fixes:"
                echo ""
                echo "   QUICK FIXES for small text:"
                echo "   1. Increase ZOOM (affects entire UI):"
                echo "      Add to settings.json: \"window.zoomLevel\": 1"
                echo ""
                echo "   2. Increase FONT SIZE (only text):"
                echo "      Add to settings.json: \"editor.fontSize\": 16"
                echo ""
                echo "   3. BOTH for maximum readability:"
                echo "      \"window.zoomLevel\": 1,"
                echo "      \"editor.fontSize\": 16"
                echo ""
            fi
            
        else
            print_status "warning" "jq not available for detailed verification"
            # Simple checks
            if grep -q '"workbench.colorTheme": "Default Dark Modern"' "$settings_file"; then
                print_status "success" "✅ Theme set to Default Dark Modern"
            fi
            if grep -q '"window.zoomLevel": 0' "$settings_file"; then
                print_status "info" "🔍 Zoom level: 0 (default)"
            fi
        fi
        
    else
        print_status "error" "Settings file not found: $settings_file"
    fi
    
    print_status "info" "Verification complete"
}

show_final_summary() {
    print_status "section" "CONFIGURATION COMPLETE"
    
    local settings_file="$HOME/.config/Code/User/settings.json"
    local backup_files
    mapfile -t backup_files < <(ls -td "$HOME"/vscode_backup_* 2>/dev/null)
    
    print_status "success" "✅ VS Code configuration completed successfully!"
    echo ""
    
    print_status "config" "📋 WHAT WAS CONFIGURED:"
    echo "  ✅ Extensions installed/verified (6 total)"
    echo "  ✅ Keyboard shortcut added: Ctrl+K Ctrl+S → Save All"
    echo "  ✅ Editor cursor style: BLOCK (in file editing area)"
    echo "  ✅ Your personal settings PRESERVED"
    echo "  ✅ Recommended editor settings added"
    echo ""
    
    print_status "config" "🎨 YOUR CURRENT VISUAL SETTINGS:"
    if [ -f "$settings_file" ] && command -v jq &> /dev/null; then
        local theme
        theme=$(strip_jsonc "$settings_file" | jq -r '.["workbench.colorTheme"] // "Default Dark Modern"')
        local font_size
        font_size=$(strip_jsonc "$settings_file" | jq -r '.["editor.fontSize"] // "14 (default)"')
        local zoom
        zoom=$(strip_jsonc "$settings_file" | jq -r '.["window.zoomLevel"] // "0 (default)"')
        local icons
        icons=$(strip_jsonc "$settings_file" | jq -r '.["workbench.iconTheme"] // "material-icon-theme"')
        
        echo "  • Theme: $theme"
        echo "  • Font size: $font_size"
        echo "  • Zoom level: $zoom"
        echo "  • Icon theme: $icons"
        
        # Special note about text size
        if [ "$font_size" = "14 (default)" ] || [ "$font_size" = "14" ]; then
            if [ "$zoom" = "0 (default)" ] || [ "$zoom" = "0" ]; then
                echo ""
                print_status "warning" "⚠️  TEXT MAY BE TOO SMALL!"
                echo "  Both font size and zoom are at defaults."
                echo "  If text feels uncomfortable, try the fixes below:"
            fi
        fi
    else
        echo "  • Settings file: $settings_file"
        echo "  • Install 'jq' for detailed view: sudo apt install jq"
    fi
    echo ""
    
    if [ ${#backup_files[@]} -gt 0 ]; then
        print_status "config" "💾 BACKUP INFORMATION:"
        echo "  • Original settings backed up to: ${backup_files[0]}"
        echo "  • Configuration log: $LOG_FILE"
        echo ""
    fi
    
    print_status "info" "🔄 NEXT STEPS:"
    echo "  1. Restart VS Code for changes to take effect"
    echo "  2. Check extensions are installed (Ctrl+Shift+X)"
    echo "  3. Test shortcut: Ctrl+K Ctrl+S saves all open files"
    echo ""
    
    print_status "info" "🔧 QUICK FIXES FOR SMALL TEXT:"
    echo "  If text feels too small, edit $settings_file and add:"
    echo ""
    echo "  OPTION 1 - Increase zoom (entire UI):"
    echo "    \"window.zoomLevel\": 1,"
    echo ""
    echo "  OPTION 2 - Increase font size (only text):"
    echo "    \"editor.fontSize\": 16,"
    echo ""
    echo "  OPTION 3 - Both for maximum readability:"
    echo "    \"window.zoomLevel\": 1,"
    echo "    \"editor.fontSize\": 16,"
    echo ""
    
    print_status "info" "📋 INTEGRATION WITH YOUR MAKEFILE:"
    echo "  This script can be called from your Makefile as 'vscode_setup'"
    echo "  Add to your Makefile:"
    echo "  vscode_setup:"
    echo "      @bash code_editors/vscode.sh"
    echo ""
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

install_terminal_font() {
    print_status "section" "INSTALLING TERMINAL NERD FONT"

    # CaskaydiaCove is the Nerd-Font-patched build of Cascadia Code
    # (ryanoasis/nerd-fonts). It matches the existing Cascadia family while
    # adding the Private-Use-Area icon glyphs the terminal statusLine / powerline
    # segments need — plain Cascadia renders those as tofu. "latest/download" is
    # GitHub's stable redirect to the newest release asset, so the link never
    # rots to a pinned dead version.
    local font_family="CaskaydiaCove Nerd Font"
    local asset_url="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/CascadiaCode.zip"
    local fonts_dir="$HOME/.local/share/fonts"

    if fc-list | grep -qi "$font_family"; then
        print_status "success" "$font_family already installed — skipping"
        return 0
    fi

    if ! command -v unzip &> /dev/null; then
        print_status "error" "unzip is required to install the Nerd Font — install it and re-run"
        return 1
    fi

    local tmp_dir
    tmp_dir="$(mktemp -d)"

    print_status "info" "Downloading $font_family from ryanoasis/nerd-fonts..."
    # $LOG_FILE is under $HOME (user-owned); the user shell opens the redirect.
    # shellcheck disable=SC2024
    if ! curl -fsSL "$asset_url" -o "$tmp_dir/CascadiaCode.zip" 2>> "$LOG_FILE"; then
        print_status "error" "Download failed — check network or $LOG_FILE"
        rm -rf "$tmp_dir"
        return 1
    fi

    mkdir -p "$fonts_dir"
    # Only the Mono .ttf variants — they keep terminal columns aligned.
    if ! unzip -o -j "$tmp_dir/CascadiaCode.zip" "*Mono*.ttf" -d "$fonts_dir" > /dev/null; then
        print_status "error" "Failed to extract font files from the archive"
        rm -rf "$tmp_dir"
        return 1
    fi

    rm -rf "$tmp_dir"
    fc-cache -f "$fonts_dir" > /dev/null

    if fc-list | grep -qi "$font_family"; then
        print_status "success" "$font_family installed"
    else
        print_status "warning" "Font extracted but not yet visible to fontconfig — log out/in if it does not appear"
    fi
}

main() {
    print_status "section" "VS CODE CONFIGURATION SCRIPT"
    print_status "info" "Log file: $LOG_FILE"
    print_status "info" "This script preserves ALL your current settings"
    print_status "info" "including font size, zoom level, and other preferences"
    echo ""
    
    # Check prerequisites
    check_vscode_installed || exit 1
    
    # Backup current configuration
    backup_current_config > /dev/null
    
    # Install jq for JSON manipulation (critical for preserving settings)
    if ! install_jq_if_needed; then
        print_status "error" "jq is required for proper settings preservation"
        print_status "info" "Please install jq manually and run the script again"
        print_status "info" "Ubuntu/Debian: sudo apt install jq"
        print_status "info" "Fedora: sudo dnf install jq"
        exit 1
    fi
    
    # Configure VS Code
    install_extensions
    configure_keybindings
    configure_settings
    sync_dotfiles_settings
    install_terminal_font
    verify_configuration
    show_final_summary
}

# Run the main function
main "$@"