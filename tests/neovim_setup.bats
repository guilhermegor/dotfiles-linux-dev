#!/usr/bin/env bats
#
# setup_neovim_config (distro_config/install_coding_lib/editors.sh): headless PlugInstall after
# writing init.vim, guarded colorscheme/NERDTree lines, and backup-before-regenerate (#739).
# nvim is a stub on PATH and HOME is a temp dir; the real config is never touched.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP="$(mktemp -d)"
    export HOME="$TMP/home" NVIM_LOG="$TMP/nvim.log" LOG_FILE="$TMP/log"
    mkdir -p "$HOME" "$TMP/bin"
    printf '#!/bin/bash\necho "$*" >> "$NVIM_LOG"\nexit "${NVIM_EXIT:-0}"\n' > "$TMP/bin/nvim"
    printf '#!/bin/bash\nexit 0\n' > "$TMP/bin/curl"
    chmod +x "$TMP/bin/"*
    export PATH="$TMP/bin:$PATH"
    : > "$NVIM_LOG"
    INIT="$HOME/.config/nvim/init.vim"
    source "$REPO_ROOT/distro_config/install_coding_lib/_common.sh"
    source "$REPO_ROOT/distro_config/install_coding_lib/editors.sh"
}

teardown() {
    rm -rf "$TMP"
}

@test "writes init.vim then runs headless PlugInstall" {
    run setup_neovim_config
    [ "$status" -eq 0 ]
    [ -f "$INIT" ]
    [ "$(cat "$NVIM_LOG")" = "--headless +PlugInstall --sync +qall" ]
}

@test "DRY_RUN leaves an existing init.vim byte-identical" {
    mkdir -p "$(dirname "$INIT")"
    echo "old" > "$INIT"
    cp "$INIT" "$TMP/before"
    DRY_RUN=1 NVIM_REGEN_CONFIG=1 run setup_neovim_config
    [ "$status" -eq 0 ]
    cmp "$INIT" "$TMP/before"
    backups=("$HOME"/.config/nvim/init.vim.bak.*)
    [ ! -e "${backups[0]}" ]
}

@test "DRY_RUN with no init.vim writes no file and does not call nvim" {
    DRY_RUN=1 run setup_neovim_config
    [ "$status" -eq 0 ]
    [ ! -e "$INIT" ]
    [ ! -s "$NVIM_LOG" ]
}

@test "a failed init.vim write returns 1 and skips PlugInstall" {
    # A directory at $INIT fails the write even for root (a read-only parent would not).
    mkdir -p "$INIT"
    run setup_neovim_config
    [ "$status" -eq 1 ]
    [[ "$output" == *"Could not write"* ]]
    [ ! -s "$NVIM_LOG" ]
}

@test "a failing PlugInstall warns but does not fail" {
    NVIM_EXIT=1 run setup_neovim_config
    [ "$status" -eq 0 ]
    [[ "$output" == *"PlugInstall failed"* ]]
}

@test "generated init.vim guards colorscheme and NERDTree" {
    run setup_neovim_config
    grep -q '^silent! colorscheme onedark' "$INIT"
    grep -q "if exists(':NERDTree') | NERDTree" "$INIT"
}

@test "default keeps the existing init.vim and warns" {
    mkdir -p "$(dirname "$INIT")"
    echo "old" > "$INIT"
    run setup_neovim_config
    [ "$status" -eq 0 ]
    [[ "$output" == *"NVIM_REGEN_CONFIG=1"* ]]
    [ "$(cat "$INIT")" = "old" ]
    [ ! -s "$NVIM_LOG" ]
}

@test "existing init.vim is backed up before regeneration" {
    mkdir -p "$(dirname "$INIT")"
    echo "old" > "$INIT"
    NVIM_REGEN_CONFIG=1 run setup_neovim_config
    [ "$status" -eq 0 ]
    backups=("$HOME"/.config/nvim/init.vim.bak.*)
    [ -f "${backups[0]}" ]
    [ "$(cat "${backups[0]}")" = "old" ]
    grep -q '^silent! colorscheme onedark' "$INIT"
}

@test "two regenerations keep the original init.vim in a distinct backup" {
    mkdir -p "$(dirname "$INIT")"
    echo "original" > "$INIT"
    NVIM_REGEN_CONFIG=1 run setup_neovim_config
    [ "$status" -eq 0 ]
    NVIM_REGEN_CONFIG=1 run setup_neovim_config
    [ "$status" -eq 0 ]
    backups=("$INIT".bak.*)
    [ "${#backups[@]}" -eq 2 ]
    grep -lx "original" "${backups[@]}"
}
