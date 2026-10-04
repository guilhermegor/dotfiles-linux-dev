#!/bin/bash

# Backup a mounted external SSD to a cloud folder on this PC.
#
# GUI flow (zenity — works from GNOME keyboard shortcut):
#   1. Pick the source drive from drives mounted under /media/$USER/
#   2. Enter / confirm the cloud destination path (remembered between runs)
#   3. Pick the zip compression level, 0-9 (remembered between runs, default 6)
#   4. Show a pulsing progress dialog while the drive is zipped
#   5. Notify on success or failure
#
# The backup is written as a single compressed .zip archived directly from the
# source drive — no uncompressed mirror is ever staged, so the cloud folder
# holds one compact file per run instead of a full duplicate of the drive.
#
# Destination structure:
#   <cloud_path>/<source_drive_name>/<yyyymmdd_hhmmss>.zip
#
# Last-used destination is saved to ~/.config/backup-external-ssd.conf

CONF_FILE="$HOME/.config/backup-external-ssd.conf"
CURRENT_USER=$(id -un)
MEDIA_BASE="/media/$CURRENT_USER"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# zip's own compression scale (0=store … 9=max). 6 is zip's balanced default —
# the fallback used when the saved LAST_ZIP_LEVEL is missing or not a single
# digit 0-9, and the pre-selected radio button on the Super+B compression
# dialog. The operator picks the actual level at runtime (see
# choose_zip_level); this constant is only the fallback, never the final value.
DEFAULT_ZIP_LEVEL=6

ZIP_LEVEL_LABELS=(
    "Store — no compression (fastest; best for already-compressed media)"
    "Fastest compression"
    "Compression level 2"
    "Compression level 3"
    "Compression level 4"
    "Compression level 5"
    "Balanced — zip's own default"
    "Compression level 7"
    "Compression level 8"
    "Maximum compression (slowest)"
)

# ── Config helpers ────────────────────────────────────────────────────────────

# Writes/replaces a single KEY=value line in $CONF_FILE without disturbing any
# other key already saved there (LAST_DEST and LAST_ZIP_LEVEL live side by side).
save_conf_value() {
    local key="$1" value="$2"
    local conf_dir
    conf_dir="$(dirname "$CONF_FILE")"
    mkdir -p "$conf_dir"
    local tmp
    tmp="$(mktemp "$conf_dir/.backup-external-ssd.conf.XXXXXX")"
    if [ -f "$CONF_FILE" ]; then
        # grep -v exits 1 when the file held only this key — not an error here.
        grep -v "^${key}=" "$CONF_FILE" > "$tmp" || true
    fi
    echo "${key}=${value}" >> "$tmp"
    mv "$tmp" "$CONF_FILE"
}

load_last_dest() {
    [ -f "$CONF_FILE" ] || return
    grep '^LAST_DEST=' "$CONF_FILE" | cut -d= -f2-
}

# A saved destination whose PARENT no longer exists is stale, and pre-filling it is worse than
# offering nothing: step 3 runs `mkdir -p`, so accepting the prompt silently RE-CREATES the dead
# tree on the local disk and writes the archive there. It looks like a cloud backup and is a
# local one — measured while migrating off Insync (dotfiles-linux-dev#360), where the saved path lived
# under ~/Insync/<account>/OneDrive/... and that whole tree is deleted by the migration.
# The parent, not the leaf: the per-drive subdirectory is created by design on a first run.
last_dest_is_stale() {
    local dest="$1"
    [ -n "$dest" ] || return 1
    [ -d "$(dirname "$dest")" ] && return 1
    return 0
}

save_last_dest() {
    save_conf_value LAST_DEST "$1"
}

load_last_zip_level() {
    [ -f "$CONF_FILE" ] || return
    grep '^LAST_ZIP_LEVEL=' "$CONF_FILE" | cut -d= -f2-
}

save_last_zip_level() {
    save_conf_value LAST_ZIP_LEVEL "$1"
}

# Falls back to DEFAULT_ZIP_LEVEL unless $1 is a single digit 0-9.
normalize_zip_level() {
    local level="$1"
    if [[ "$level" =~ ^[0-9]$ ]]; then
        echo "$level"
    else
        echo "$DEFAULT_ZIP_LEVEL"
    fi
}

# Shows zip's own 0-9 levels as a radio list with $1 pre-selected. Echoes the
# chosen digit; returns non-zero with no output if the operator cancels.
choose_zip_level() {
    local default_level="$1"
    local -a rows=()
    local i mark
    for i in 0 1 2 3 4 5 6 7 8 9; do
        mark=FALSE
        [ "$i" = "$default_level" ] && mark=TRUE
        rows+=("$mark" "$i" "${ZIP_LEVEL_LABELS[$i]}")
    done
    zenity --list --radiolist \
        --title="Backup — compression level" \
        --text="Choose the zip compression level.\nSize reduction depends on the drive's content." \
        --column="" --column="Level" --column="Description" \
        --print-column=2 \
        "${rows[@]}"
}

# Zips $1 into $2 at compression level $3, run from inside $1 so archive
# paths are relative to the drive root.
zip_archive() {
    local src="$1" dest="$2" level="$3"
    ( cd "$src" || exit 1; zip -r -y -q -"$level" "$dest" . -x 'lost+found/*' )
}

# ── Drive discovery ───────────────────────────────────────────────────────────

find_mounted_drives() {
    for drive_path in "$MEDIA_BASE"/*/; do
        [ -d "$drive_path" ] || continue
        basename "$drive_path"
    done
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    # 0. Require zip — the archive step depends on it
    if ! command -v zip >/dev/null 2>&1; then
        zenity --error --title="Backup" \
            --text="<b>zip</b> is not installed.\n\nInstall it with <tt>sudo apt install zip</tt> and try again."
        exit 1
    fi

    # 1. Collect mounted drives
    local -a drives
    mapfile -t drives < <(find_mounted_drives)

    if [ ${#drives[@]} -eq 0 ]; then
        zenity --error --title="Backup" \
            --text="No drives found under <tt>$MEDIA_BASE</tt>.\n\nMount your external SSD first."
        exit 1
    fi

    # 2. Pick source drive
    local source_name
    if [ ${#drives[@]} -eq 1 ]; then
        source_name="${drives[0]}"
        zenity --question --title="Backup" \
            --text="Back up <b>$source_name</b> to the cloud?\n\nPress OK to continue." \
            --ok-label="OK" --cancel-label="Cancel" || exit 0
    else
        source_name=$(
            zenity --list \
                --title="Backup — select source drive" \
                --text="Choose the drive to back up:" \
                --column="Drive" \
                "${drives[@]}"
        ) || exit 0
    fi

    local src="$MEDIA_BASE/$source_name"

    # 3. Ask for destination cloud path (pre-filled with last-used value)
    local last_dest
    last_dest=$(load_last_dest)

    local dest_prompt="Enter the cloud folder path on this PC\n(files will be saved under <b>$source_name/&lt;timestamp&gt;/</b>):"
    if last_dest_is_stale "$last_dest"; then
        dest_prompt="⚠️ The last destination no longer exists:\n<tt>$last_dest</tt>\n\nIt was not re-used — accepting it would create a new local folder and back up to this disk instead of the cloud.\n\n$dest_prompt"
        last_dest=""
    fi

    local dest_base
    dest_base=$(
        zenity --entry \
            --title="Backup — destination" \
            --text="$dest_prompt" \
            --entry-text="${last_dest:-$HOME/}"
    ) || exit 0

    if [ -z "$dest_base" ]; then
        zenity --error --title="Backup" --text="No destination path provided."
        exit 1
    fi

    save_last_dest "$dest_base"

    # 4. Ask for the zip compression level (remembered between runs)
    local last_level
    last_level=$(normalize_zip_level "$(load_last_zip_level)")

    local zip_level
    zip_level=$(choose_zip_level "$last_level") || exit 0
    [ -n "$zip_level" ] || exit 0

    save_last_zip_level "$zip_level"

    local dest_dir="${dest_base%/}/${source_name}"
    local dest="${dest_dir}/${TIMESTAMP}.zip"

    if ! mkdir -p "$dest_dir"; then
        zenity --error --title="Backup" \
            --text="Cannot create destination:\n<tt>$dest_dir</tt>\n\nCheck the path and permissions."
        exit 1
    fi

    # 5. Zip the drive into a single archive with a pulsing progress dialog.
    #    -r recurses, -y stores symlinks as links rather than following them,
    #    -q stays quiet, and lost+found is excluded.
    notify-send --urgency=low "Backup started" \
        "$source_name → $dest_base" 2>/dev/null || true

    zip_archive "$src" "$dest" "$zip_level" &
    local zip_pid=$!

    zenity --progress --pulsate --no-cancel --auto-close \
        --title="Backing up $source_name" \
        --text="Compressing <b>$source_name</b> to:\n<tt>$dest</tt>" 2>/dev/null &
    local zenity_pid=$!

    wait "$zip_pid"
    local exit_code=$?

    kill "$zenity_pid" 2>/dev/null || true
    wait "$zenity_pid" 2>/dev/null || true

    # 6. Report result
    if [ "$exit_code" -eq 0 ]; then
        notify-send --urgency=normal "Backup complete" \
            "$source_name → $dest" 2>/dev/null || true
        zenity --info --title="Backup complete" \
            --text="<b>$source_name</b> backed up successfully.\n\n<tt>$dest</tt>"
    else
        notify-send --urgency=critical "Backup failed" \
            "zip exited with code $exit_code" 2>/dev/null || true
        zenity --error --title="Backup failed" \
            --text="zip exited with error <b>$exit_code</b>.\n\nCheck available space and permissions."
        exit 1
    fi
}

main
