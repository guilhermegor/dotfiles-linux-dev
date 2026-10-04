#!/bin/bash
#
# ai_clients/lib/restore_env_prompt.sh
#
# Offers to restore git-ignored .env files from an external backup drive
# before downstream installs run. On a fresh Ubuntu install the per-project
# .env files do not exist (they are git-ignored), so installs that read .env
# values would otherwise run without them.
#
# Dual-mode: sourced by ai_clients/main.sh (which calls prompt_restore_env
# itself, gated by $DOTFILES_INIT_IN_PROGRESS) AND executed directly by
# `make restore_env_prompt` / `make run` (runs the prompt on execution).

_rep_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$_rep_dir/../.." && pwd)"
unset _rep_dir

# When executed standalone, print_status is not yet defined — pull it in.
# When sourced by ai_clients/main.sh (after utils.sh), it already exists,
# so this avoids a redundant second source of lib/common.sh.
if ! declare -F print_status >/dev/null 2>&1; then
    # shellcheck source=../../lib/common.sh
    source "$REPO_ROOT/lib/common.sh"
fi

# Ask whether to restore .env files, then (on yes) a second time to confirm before
# anything is replaced; only then delegate to the installed restore-env.sh binary,
# falling back to the in-repo storage/restore_env.sh. Both prompts' defaults adapt to
# the repo-root .env (the file downstream installs read): present → default no (don't
# clobber an existing config); absent → default yes (a fresh setup needs values before
# installs run). Bare Enter takes the default. Never aborts the caller — returns instead.
prompt_restore_env() {
    local reply confirm
    local env_exists=0
    [[ -f "$REPO_ROOT/.env" ]] && env_exists=1

    if [[ $env_exists -eq 1 ]]; then
        read -rp "Restore .env files from an external drive? [y/N]: " reply || [[ -n "$reply" ]] || reply="n"
        reply="${reply:-n}"
    else
        print_status "info" "No .env at $REPO_ROOT — restore recommended on a fresh setup"
        read -rp "Restore .env files from an external drive? [Y/n]: " reply || [[ -n "$reply" ]] || reply="n"
        reply="${reply:-y}"
    fi

    if [[ ! "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        print_status "info" "Skipping .env restore."
        return 0
    fi

    # Second guard before a restore that could clobber an existing config. The default
    # tracks the risk: an existing .env means an overwrite is possible (default no); none
    # present means there is nothing to lose (default yes). Per-file conflicts are then
    # resolved individually by the restore script (overwrite / back up first / skip).
    if [[ $env_exists -eq 1 ]]; then
        print_status "warning" "A .env already exists at $REPO_ROOT and may be replaced."
        read -rp "Are you sure you want to replace existing .env file(s)? [y/N]: " confirm || [[ -n "$confirm" ]] || confirm="n"
        confirm="${confirm:-n}"
    else
        read -rp "Are you sure you want to restore .env file(s)? [Y/n]: " confirm || [[ -n "$confirm" ]] || confirm="n"
        confirm="${confirm:-y}"
    fi

    if [[ ! "$confirm" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        print_status "info" "Skipping .env restore."
        return 0
    fi

    local installed="$HOME/.local/bin/restore-env.sh"
    local fallback="$REPO_ROOT/storage/restore_env.sh"

    if [[ -x "$installed" ]]; then
        print_status "info" "Running $installed"
        "$installed"
    elif [[ -f "$fallback" ]]; then
        print_status "warning" "$installed not found; running repo fallback"
        bash "$fallback"
    else
        print_status "error" "No restore-env script found. Skipping."
        return 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    prompt_restore_env
fi
