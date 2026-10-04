#!/bin/bash
# Manages ~/.claude/.env — ensures required environment variables are set.

configure_env() {
    print_status "section" "CONFIGURING CLAUDE ENV"

    local env_file="$CLAUDE_DIR/.env"
    mkdir -p "$CLAUDE_DIR"

    # Load existing .env if present
    local existing_backup_dir=""
    if [ -f "$env_file" ]; then
        existing_backup_dir=$(grep -oP '^CLAUDE_BACKUP_DIR=\K.*' "$env_file" 2>/dev/null || true)
    fi

    if [ -n "$existing_backup_dir" ]; then
        print_status "info" "CLAUDE_BACKUP_DIR already set: $existing_backup_dir"
        read -rp "Keep current path? [Y/n]: " keep_current || keep_current=""
        if [[ "$keep_current" =~ ^[nN]$ ]]; then
            existing_backup_dir=""
        else
            print_status "success" "Kept existing CLAUDE_BACKUP_DIR"
        fi
    fi

    if [ -z "$existing_backup_dir" ]; then
        print_status "info" "CLAUDE_BACKUP_DIR is the path where /export-memory saves backups."
        print_status "info" "Example: /media/user/external-drive/claude-backup"
        echo ""
        read -rp "Enter backup directory path (leave empty to skip): " user_path || user_path=""

        if [ -z "$user_path" ]; then
            print_status "warning" "No backup path provided — skipping CLAUDE_BACKUP_DIR"
            print_status "info" "You can set it later in: $env_file"
            print_status "config" "  Add: CLAUDE_BACKUP_DIR=/your/backup/path"
            _write_env_file "$env_file" ""
            return 0
        fi

        # Validate the path exists or offer to create it
        if [ ! -d "$user_path" ]; then
            read -rp "Directory does not exist. Create it? [Y/n]: " create_dir || create_dir="n"
            if [[ "$create_dir" =~ ^[nN]$ ]]; then
                print_status "warning" "Directory not created — CLAUDE_BACKUP_DIR not set"
                _write_env_file "$env_file" ""
                return 0
            fi
            mkdir -p "$user_path"
            print_status "success" "Created directory: $user_path"
        fi

        existing_backup_dir="$user_path"
    fi

    _write_env_file "$env_file" "$existing_backup_dir"

    if [ -n "$existing_backup_dir" ]; then
        print_status "success" "CLAUDE_BACKUP_DIR=$existing_backup_dir"
        print_status "info" "Use /export-memory to back up your Claude data"
    fi
}

_write_env_file() {
    local env_file="$1"
    local backup_dir="$2"

    # Create timestamped backup before overwriting
    if [ -f "$env_file" ]; then
        local backup_path
        backup_path="${env_file}.backup_$(date +%Y%m%d_%H%M%S)"
        cp "$env_file" "$backup_path"
        print_status "success" "Backed up existing .env → $(basename "$backup_path")"
    fi

    # Preserve any existing variables other than CLAUDE_BACKUP_DIR
    local other_vars=""
    if [ -f "$env_file" ]; then
        other_vars=$(grep -v '^CLAUDE_BACKUP_DIR=' "$env_file" 2>/dev/null | grep -v '^$' || true)
    fi

    {
        if [ -n "$other_vars" ]; then
            echo "$other_vars"
        fi
        if [ -n "$backup_dir" ]; then
            echo "CLAUDE_BACKUP_DIR=$backup_dir"
        fi
    } > "$env_file"

    print_status "config" "Env written to: $env_file"
}
