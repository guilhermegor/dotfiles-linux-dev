#!/bin/bash
# Removes installed artifacts in ~/.claude/ that no longer exist in this repo.
#
# The install_* steps only ever copy, never delete, so every artifact removed
# from source stays behind in ~/.claude/ indefinitely. Those leftovers are not
# inert: a stale file that later regains a loadable layout silently resurrects
# a deleted artifact. This step is the delete path.
#
# Always interactive — it asks before removing anything. Source is the authority,
# so anything here is recoverable from git history.

# type → "<source subdir>:<source ext>:<dest subdir>:<layout>"
# layout: flat  → <dest>/<name><ext>
#         nested→ <dest>/<name>/SKILL.md
declare -A PRUNE_TARGETS=(
    [commands]="commands:.md:commands:flat"
    [skills]="skills:.md:skills:nested"
    [agents]="agents:.md:agents:flat"
    [rules]="rules:.md:rules:flat"
    [hooks]="hooks:.sh:hooks:flat"
)

# Echoes the installed artifact names for one type, one per line.
_installed_names() {
    local dest="$1" ext="$2" layout="$3"

    [[ -d "$dest" ]] || return 0

    if [[ "$layout" == "nested" ]]; then
        find "$dest" -mindepth 2 -maxdepth 2 -name 'SKILL.md' -printf '%h\n' \
            | xargs -r -n1 basename
        return 0
    fi

    find "$dest" -maxdepth 1 -type f -name "*$ext" -printf '%f\n' \
        | sed "s/${ext//./\\.}\$//"
}

# Echoes the source artifact names for one type, one per line.
_source_names() {
    local src="$1" ext="$2"

    [[ -d "$src" ]] || return 0

    find "$src" -maxdepth 1 -type f -name "*$ext" -printf '%f\n' \
        | sed "s/${ext//./\\.}\$//"
}

prune_orphans() {
    print_status "section" "PRUNING ORPHANED ARTIFACTS"
    _prune_file_artifacts
    prune_settings_keys
}

_prune_file_artifacts() {
    local -a orphan_paths=()
    local -a orphan_labels=()
    local type spec src ext dest layout name

    for type in "${!PRUNE_TARGETS[@]}"; do
        spec="${PRUNE_TARGETS[$type]}"
        IFS=':' read -r src ext dest layout <<< "$spec"
        src="$SCRIPT_DIR/$src"
        dest="$CLAUDE_DIR/$dest"

        while read -r name; do
            [[ -n "$name" ]] || continue
            if [[ "$layout" == "nested" ]]; then
                orphan_paths+=("$dest/$name")
            else
                orphan_paths+=("$dest/$name$ext")
            fi
            orphan_labels+=("$type: $name")
        done < <(comm -13 \
            <(_source_names "$src" "$ext" | sort) \
            <(_installed_names "$dest" "$ext" "$layout" | sort))
    done

    if (( ${#orphan_paths[@]} == 0 )); then
        print_status "success" "No orphaned artifacts — ~/.claude matches source"
        return 0
    fi

    print_status "warning" "Found ${#orphan_paths[@]} artifact(s) installed but absent from source:"
    local label
    for label in "${orphan_labels[@]}"; do
        print_status "info" "  $label"
    done

    local reply
    read -r -p "Remove these? They are recoverable from git history. [y/N] " reply
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
        print_status "info" "Left in place — nothing removed"
        return 0
    fi

    local path
    for path in "${orphan_paths[@]}"; do
        rm -rf "$path"
    done
    print_status "success" "Removed ${#orphan_paths[@]} orphaned artifact(s)"
}

# ── Settings-key pruning (dotfiles-linux-dev#272) ─────────────────────────────────
#
# configure_settings() merges source into ~/.claude/settings.json with
# `jq '. * $base'` — additive only. It can update a key's value but can
# never remove a key that exists only live, because a merge never deletes.
# That same property is what lets legitimate machine-local keys (API
# tokens, per-machine env vars, ...) survive every deploy — so pruning here
# must NOT be "delete anything live that source lacks" (that would destroy
# the very thing the additive merge exists to protect).
#
# Instead, prune only inside object keys that are named below and are
# *entirely* source-owned — every entry under them is expected to trace back
# to source, so anything else found live is stale, not machine-local.
# `enabledPlugins` is the concrete case (#272): plugin entries are only ever
# added by run_plugins() in main.sh, never hand-edited on a live machine.
# Add a key here only when that same guarantee holds; never a top-level key
# that legitimately mixes source and machine-local entries.
declare -ga SETTINGS_PRUNE_KEYS=("enabledPlugins")

# Echoes subkeys present in $settings_file's "$key" object but absent from
# $base_file's, one per line.
_stale_settings_subkeys() {
    local settings_file="$1" base_file="$2" key="$3"

    comm -23 \
        <(jq -r --arg k "$key" '(.[$k] // {}) | keys[]?' "$settings_file" 2>/dev/null | sort) \
        <(jq -r --arg k "$key" '(.[$k] // {}) | keys[]?' "$base_file" 2>/dev/null | sort)
}

prune_settings_keys() {
    local settings_file="$CLAUDE_DIR/settings.json"
    local base_settings_file="$SCRIPT_DIR/settings.json"

    [[ -f "$settings_file" ]] || return 0
    [[ -f "$base_settings_file" ]] || return 0
    jq empty "$settings_file" 2>/dev/null || return 0

    local key subkey
    local -a stale_refs=()    # "key<TAB>subkey", for the jq delete pass
    local -a stale_labels=()

    for key in "${SETTINGS_PRUNE_KEYS[@]}"; do
        while read -r subkey; do
            [[ -n "$subkey" ]] || continue
            stale_refs+=("$key"$'\t'"$subkey")
            stale_labels+=("$key: $subkey")
        done < <(_stale_settings_subkeys "$settings_file" "$base_settings_file" "$key")
    done

    if (( ${#stale_refs[@]} == 0 )); then
        print_status "success" "No stale settings keys — enabledPlugins matches source"
        return 0
    fi

    print_status "warning" "Found ${#stale_refs[@]} settings key(s) live but absent from source:"
    local label
    for label in "${stale_labels[@]}"; do
        print_status "info" "  $label"
    done

    local reply
    read -r -p "Remove these from $settings_file? They are recoverable from git history. [y/N] " reply
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
        print_status "info" "Left in place — nothing removed"
        return 0
    fi

    local ref k sk tmp
    tmp="${settings_file}.tmp"
    cp "$settings_file" "$tmp"
    for ref in "${stale_refs[@]}"; do
        k="${ref%%$'\t'*}"
        sk="${ref#*$'\t'}"
        jq --arg k "$k" --arg sk "$sk" 'del(.[$k][$sk])' "$tmp" > "${tmp}.next" \
            && mv "${tmp}.next" "$tmp"
    done
    mv "$tmp" "$settings_file"
    print_status "success" "Removed ${#stale_refs[@]} stale settings key(s)"
}
