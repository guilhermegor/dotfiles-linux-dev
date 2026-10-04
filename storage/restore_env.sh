#!/bin/bash
# Restores an encrypted env bundle (git-ignored .env* files plus, optionally,
# ~/.config/rclone/rclone.conf) produced by storage/backup_env.sh.
# Reads CLAUDE_BACKUP_DIR from ~/.claude/.env for the source.
#
# Every restored file is written mode 600 and NEVER overwrites an existing
# file — an existing file may already hold a newer, working secret, so a
# conflict is reported as skipped rather than clobbered. After restoring
# rclone.conf, a cheap `rclone lsd <remote>: --max-depth 1` check verifies the
# token still works; a failure points at `rclone config reconnect <remote>:`
# rather than leaving a broken mount silently in place — OneDrive refresh
# tokens expire after disuse, so this is expected, not an error
# (dotfiles-linux-dev#367).

GITHUB_DIR="$HOME/github"
RCLONE_CONF_DEST="$HOME/.config/rclone/rclone.conf"

read_backup_dir() {
    grep '^CLAUDE_BACKUP_DIR=' "$HOME/.claude/.env" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]'
}

# Lists encrypted bundles newest-first. Filenames are
# env_bundle_YYYYMMDD_HHMMSS.tar.gpg, so lexical sort is chronological sort.
list_bundles() {
    local bundle_dir="$1"
    find "$bundle_dir" -maxdepth 1 -name 'env_bundle_*.tar.gpg' -type f 2>/dev/null | sort -r
}

# Prompts once for the passphrase (hidden entry). Prints it on stdout for
# command-substitution capture only — never as a CLI argument.
prompt_passphrase_once() {
    zenity --password --title="Restore Env — enter passphrase"
}

# Decrypts $bundle_path into $tar_path. The passphrase is fed over stdin
# (--passphrase-fd 0), never as a CLI argument.
decrypt_bundle() {
    local bundle_path="$1" tar_path="$2" passphrase="$3"
    printf '%s' "$passphrase" | gpg --batch --yes --pinentry-mode loopback \
        --passphrase-fd 0 --decrypt --output "$tar_path" "$bundle_path" 2>/dev/null
}

# Restores one file to $dest with mode 600, never overwriting an existing
# file. Echoes nothing; caller inspects the exit status:
#   0 = restored, 1 = skipped (already exists), 2 = failed to copy
restore_file() {
    local src="$1" dest="$2"
    if [[ -e "$dest" ]]; then
        return 1
    fi
    mkdir -p "$(dirname "$dest")" || return 2
    cp "$src" "$dest" 2>/dev/null || return 2
    chmod 600 "$dest" || return 2
    return 0
}

# Cheap post-restore read of the first configured remote. Prints a
# human-readable note; returns 0 when verified (or nothing to verify), 1 when
# the token looks dead so the caller can surface the reconnect hint.
verify_rclone() {
    local conf_path="$1"
    local remote
    remote=$(RCLONE_CONFIG="$conf_path" rclone listremotes 2>/dev/null | head -n1)
    if [[ -z "$remote" ]]; then
        echo "rclone.conf restored, but it has no configured remotes to verify."
        return 0
    fi
    if RCLONE_CONFIG="$conf_path" rclone lsd "${remote}" --max-depth 1 &>/dev/null; then
        echo "rclone.conf restored and verified against ${remote} (rclone lsd succeeded)."
        return 0
    fi
    echo "rclone.conf restored, but ${remote} could not be reached — the token" \
         "may have expired from disuse. Run: rclone config reconnect ${remote}"
    return 1
}

main() {
    local backup_dir
    backup_dir=$(read_backup_dir)

    if [[ -z "$backup_dir" ]]; then
        zenity --error --title="Restore Env" \
            --text="<b>CLAUDE_BACKUP_DIR</b> is not set.\n\nAdd it to <tt>~/.claude/.env</tt>."
        exit 1
    fi

    local bundle_dir="$backup_dir/env_bundle"

    if [[ ! -d "$bundle_dir" ]]; then
        zenity --error --title="Restore Env" \
            --text="Cannot access source directory:\n<tt>$bundle_dir</tt>\n\nCheck that the drive is mounted."
        exit 1
    fi

    local -a bundles=()
    while IFS= read -r bundle; do
        [[ -z "$bundle" ]] && continue
        bundles+=("$bundle")
    done < <(list_bundles "$bundle_dir")

    if [[ ${#bundles[@]} -eq 0 ]]; then
        zenity --info --title="Restore Env" \
            --text="No encrypted backups found in:\n<tt>$bundle_dir</tt>"
        exit 0
    fi

    local chosen_bundle="${bundles[0]}"
    if [[ ${#bundles[@]} -gt 1 ]]; then
        local -a radio_args=()
        for bundle in "${bundles[@]}"; do
            if [[ "$bundle" == "$chosen_bundle" ]]; then
                radio_args+=(TRUE "$(basename "$bundle")" "$bundle")
            else
                radio_args+=(FALSE "$(basename "$bundle")" "$bundle")
            fi
        done
        chosen_bundle=$(
            zenity --list --radiolist \
                --title="Restore Env — select a backup" \
                --text="Multiple encrypted backups found. Pick one (latest pre-selected):" \
                --column="Pick" --column="Backup" --column="Full path" \
                --hide-column=3 --print-column=3 \
                "${radio_args[@]}"
        ) || exit 0
        [[ -z "$chosen_bundle" ]] && exit 0
    fi

    local passphrase
    passphrase=$(prompt_passphrase_once) || exit 0
    if [[ -z "$passphrase" ]]; then
        zenity --error --title="Restore Env" --text="Passphrase cannot be empty."
        exit 1
    fi

    local staging_dir tar_path
    staging_dir=$(mktemp -d)
    tar_path=$(mktemp)
    trap 'rm -rf "$staging_dir"; rm -f "$tar_path"; unset passphrase' EXIT

    if ! decrypt_bundle "$chosen_bundle" "$tar_path" "$passphrase"; then
        zenity --error --title="Restore Env" \
            --text="Could not decrypt <tt>$(basename "$chosen_bundle")</tt> — wrong passphrase or a corrupted backup."
        exit 1
    fi

    if ! tar -C "$staging_dir" -xf "$tar_path" 2>/dev/null; then
        zenity --error --title="Restore Env" --text="Decrypted, but could not extract the archive."
        exit 1
    fi

    local -a restored=()
    local -a skipped=()
    local -a failed=()
    local -a notes=()

    if [[ -d "$staging_dir/env_files" ]]; then
        while IFS= read -r entry; do
            [[ -z "$entry" ]] && continue
            local name proj_key env_name project_rel dest
            name=$(basename "$entry")
            proj_key="${name%__*}"
            env_name="${name##*__}"
            project_rel="${proj_key//__//}"
            dest="$GITHUB_DIR/$project_rel/.$env_name"

            restore_file "$entry" "$dest"
            case $? in
                0) restored+=(".$env_name ($project_rel) → $dest") ;;
                1) skipped+=(".$env_name ($project_rel): already exists at $dest") ;;
                *) failed+=(".$env_name ($project_rel): could not restore to $dest") ;;
            esac
        done < <(find "$staging_dir/env_files" -maxdepth 1 -type f 2>/dev/null)
    fi

    if [[ -f "$staging_dir/rclone/rclone.conf" ]]; then
        restore_file "$staging_dir/rclone/rclone.conf" "$RCLONE_CONF_DEST"
        case $? in
            0)
                restored+=("rclone.conf → $RCLONE_CONF_DEST")
                local verify_note
                verify_note=$(verify_rclone "$RCLONE_CONF_DEST")
                notes+=("$verify_note")
                ;;
            1) skipped+=("rclone.conf: already exists at $RCLONE_CONF_DEST") ;;
            *) failed+=("rclone.conf: could not restore to $RCLONE_CONF_DEST") ;;
        esac
    fi

    local summary=""
    if [[ ${#restored[@]} -gt 0 ]]; then
        summary+="<b>Restored:</b>"
        for item in "${restored[@]}"; do summary+="\n  $item"; done
        summary+="\n\n"
    fi
    if [[ ${#skipped[@]} -gt 0 ]]; then
        summary+="<b>Skipped (already exists — not overwritten):</b>"
        for item in "${skipped[@]}"; do summary+="\n  $item"; done
        summary+="\n\n"
    fi
    if [[ ${#failed[@]} -gt 0 ]]; then
        summary+="<b>Failed:</b>"
        for item in "${failed[@]}"; do summary+="\n  $item"; done
        summary+="\n\n"
    fi
    if [[ ${#notes[@]} -gt 0 ]]; then
        summary+="<b>Notes:</b>"
        for item in "${notes[@]}"; do summary+="\n  $item"; done
    fi

    notify-send --urgency=normal "Restore Env complete" \
        "${#restored[@]} restored, ${#skipped[@]} skipped, ${#failed[@]} failed" 2>/dev/null || true
    zenity --info --title="Restore Env — done" --text="${summary:-No changes made.}"
}

main
