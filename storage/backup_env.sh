#!/bin/bash
# Backs up git-ignored .env* files (from all git repos under ~/github) and
# ~/.config/rclone/rclone.conf into ONE gpg-encrypted archive on the backup
# drive. Reads CLAUDE_BACKUP_DIR from ~/.claude/.env for the destination.
#
# Never writes a plaintext copy: the only thing written under
# $CLAUDE_BACKUP_DIR/env_bundle/ is the encrypted .tar.gpg file. Encryption is
# a symmetric passphrase (gpg --symmetric --cipher-algo AES256), prompted
# twice via zenity's hidden-entry dialog and fed to gpg over stdin
# (--passphrase-fd 0) so it never appears in argv / `ps` / shell history
# (dotfiles-linux-dev#367).

GITHUB_DIR="$HOME/github"
RCLONE_CONF="$HOME/.config/rclone/rclone.conf"

read_backup_dir() {
    grep '^CLAUDE_BACKUP_DIR=' "$HOME/.claude/.env" 2>/dev/null \
        | cut -d= -f2- \
        | tr -d '[:space:]'
}

find_git_repos() {
    while IFS= read -r gitdir; do
        dirname "$gitdir"
    done < <(find "$GITHUB_DIR" -maxdepth 2 -name ".git" -type d 2>/dev/null)
}

find_ignored_env_files() {
    local repo="$1"
    find "$repo" -maxdepth 1 -name ".env*" ! -name "*.md" 2>/dev/null | \
        while IFS= read -r file; do
            if git -C "$repo" check-ignore --quiet "$file" 2>/dev/null; then
                echo "$file"
            fi
        done
}

# Existing plaintext copies left by the pre-#367 flow (gzip is compression,
# not encryption). Reported with exact paths so the owner can delete them by
# hand — never deleted automatically, they may be the only copy left.
find_legacy_plaintext() {
    local backup_dir="$1"
    local legacy_dir="$backup_dir/env_files"
    [[ -d "$legacy_dir" ]] || return 0
    find "$legacy_dir" -maxdepth 1 -type f 2>/dev/null
}

# Stages one selected git-ignored env file into the bundle under
# env_files/<proj_key>__<env_name> (proj_key = repo path relative to
# $GITHUB_DIR with "/" turned into "__").
stage_env_file() {
    local file_path="$1" staging_dir="$2"
    local repo rel_path proj_key filename env_name
    repo=$(dirname "$file_path")
    rel_path="${repo#$GITHUB_DIR/}"
    proj_key="${rel_path//\//__}"
    filename=$(basename "$file_path")
    env_name="${filename#.}"
    mkdir -p "$staging_dir/env_files"
    cp "$file_path" "$staging_dir/env_files/${proj_key}__${env_name}"
}

# Stages ~/.config/rclone/rclone.conf into the bundle under rclone/rclone.conf.
# Never touches the live file — read-only copy into the staging dir.
stage_rclone_conf() {
    local staging_dir="$1"
    mkdir -p "$staging_dir/rclone"
    cp "$RCLONE_CONF" "$staging_dir/rclone/rclone.conf"
}

# Builds the plaintext tar in a private temp location — never under the
# backup drive. Caller is responsible for removing it after encryption.
build_tar() {
    local staging_dir="$1" tar_path="$2"
    tar -C "$staging_dir" -cf "$tar_path" .
}

# Prompts for the passphrase twice (hidden entry, zenity --password) and
# requires both entries to match and be non-empty. Prints the passphrase on
# stdout for command-substitution capture only — never as a command-line
# argument to any other process.
prompt_passphrase_confirm() {
    local p1 p2
    p1=$(zenity --password --title="Backup Env — set passphrase") || return 1
    p2=$(zenity --password --title="Backup Env — confirm passphrase") || return 1
    if [[ -z "$p1" ]]; then
        return 2
    fi
    if [[ "$p1" != "$p2" ]]; then
        return 3
    fi
    printf '%s' "$p1"
}

# Encrypts $tar_path into $dest_path with a symmetric passphrase. The
# passphrase is fed over stdin (--passphrase-fd 0), never as a CLI argument.
encrypt_bundle() {
    local tar_path="$1" dest_path="$2" passphrase="$3"
    printf '%s' "$passphrase" | gpg --batch --yes --pinentry-mode loopback \
        --passphrase-fd 0 --symmetric --cipher-algo AES256 \
        --output "$dest_path" "$tar_path"
}

main() {
    local backup_dir
    backup_dir=$(read_backup_dir)

    if [[ -z "$backup_dir" ]]; then
        zenity --error --title="Backup Env" \
            --text="<b>CLAUDE_BACKUP_DIR</b> is not set.\n\nAdd it to <tt>~/.claude/.env</tt>."
        exit 1
    fi

    if [[ ! -d "$backup_dir" ]]; then
        zenity --error --title="Backup Env" \
            --text="Backup directory not accessible:\n<tt>$backup_dir</tt>\n\nCheck that the drive is mounted."
        exit 1
    fi

    local -a legacy_plaintext=()
    while IFS= read -r legacy_file; do
        [[ -z "$legacy_file" ]] && continue
        legacy_plaintext+=("$legacy_file")
    done < <(find_legacy_plaintext "$backup_dir")

    local target="$backup_dir/env_bundle"

    if ! mkdir -p "$target" 2>/dev/null; then
        zenity --error --title="Backup Env" \
            --text="Cannot create target directory:\n<tt>$target</tt>\n\nCheck permissions."
        exit 1
    fi

    notify-send --urgency=low "Env Backup" "Scanning repos under $GITHUB_DIR..." 2>/dev/null || true

    local -a checklist_args=()
    local found=0

    while IFS= read -r repo; do
        local rel_path
        rel_path="${repo#$GITHUB_DIR/}"
        while IFS= read -r file; do
            local filename
            filename=$(basename "$file")
            checklist_args+=(TRUE "$rel_path" "$filename" "$file")
            found=$((found + 1))
        done < <(find_ignored_env_files "$repo")
    done < <(find_git_repos)

    if [[ -f "$RCLONE_CONF" ]]; then
        checklist_args+=(TRUE "rclone" "rclone.conf" "$RCLONE_CONF")
        found=$((found + 1))
    fi

    if [[ $found -eq 0 ]]; then
        zenity --info --title="Backup Env" \
            --text="No git-ignored <tt>.env</tt> files (or rclone.conf) found to back up."
        exit 0
    fi

    local selected
    selected=$(
        zenity --list \
            --checklist \
            --title="Backup Env — select files" \
            --text="Found <b>$found</b> file(s). Select what to include in the encrypted bundle:" \
            --column="Backup?" \
            --column="Project" \
            --column="File" \
            --column="Full path" \
            --hide-column=4 \
            --print-column=4 \
            --separator=$'\n' \
            "${checklist_args[@]}"
    ) || exit 0

    if [[ -z "$selected" ]]; then
        zenity --info --title="Backup Env" --text="No files selected. Nothing to back up."
        exit 0
    fi

    local passphrase
    passphrase=$(prompt_passphrase_confirm)
    local pass_status=$?
    if [[ $pass_status -eq 1 ]]; then
        exit 0
    elif [[ $pass_status -eq 2 ]]; then
        zenity --error --title="Backup Env" --text="Passphrase cannot be empty. Nothing was backed up."
        exit 1
    elif [[ $pass_status -eq 3 ]]; then
        zenity --error --title="Backup Env" --text="Passphrases did not match. Nothing was backed up."
        exit 1
    fi

    local staging_dir tar_path
    staging_dir=$(mktemp -d)
    tar_path=$(mktemp)
    trap 'rm -rf "$staging_dir"; rm -f "$tar_path"; unset passphrase' EXIT

    local -a staged=()
    local -a failed=()

    while IFS= read -r file_path; do
        [[ -z "$file_path" ]] && continue
        if [[ "$file_path" == "$RCLONE_CONF" ]]; then
            if stage_rclone_conf "$staging_dir"; then
                staged+=("rclone.conf")
            else
                failed+=("rclone.conf: could not stage")
            fi
        else
            if stage_env_file "$file_path" "$staging_dir"; then
                staged+=("$(basename "$file_path")")
            else
                failed+=("$(basename "$file_path"): could not stage")
            fi
        fi
    done <<< "$selected"

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local dest="$target/env_bundle_${timestamp}.tar.gpg"

    local summary=""

    if [[ ${#staged[@]} -gt 0 ]] && build_tar "$staging_dir" "$tar_path" \
        && encrypt_bundle "$tar_path" "$dest" "$passphrase"; then
        summary="<b>Backed up ${#staged[@]} file(s)</b> into one encrypted bundle:\n<tt>$dest</tt>"
        summary+="\n\n<b>Included:</b>"
        for item in "${staged[@]}"; do summary+="\n  $item"; done
    else
        zenity --error --title="Backup Env" --text="Failed to build or encrypt the backup bundle. Nothing was written."
        exit 1
    fi

    if [[ ${#failed[@]} -gt 0 ]]; then
        summary+="\n\n<b>Failed:</b>"
        for item in "${failed[@]}"; do summary+="\n  $item"; done
    fi

    if [[ ${#legacy_plaintext[@]} -gt 0 ]]; then
        summary+="\n\n<b>Legacy plaintext copies found (delete manually — not removed automatically):</b>"
        for item in "${legacy_plaintext[@]}"; do summary+="\n  $item"; done
    fi

    notify-send --urgency=normal "Env Backup complete" \
        "${#staged[@]} file(s) backed up (encrypted)" 2>/dev/null || true
    zenity --info --title="Backup Env — done" --text="$summary"
}

main
