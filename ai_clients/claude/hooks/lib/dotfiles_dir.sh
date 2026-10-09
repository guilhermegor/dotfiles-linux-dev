#!/bin/bash
# The ONE source for "where is this dotfiles checkout" (dotfiles-linux-dev#661).
#
# Tracked files must never hardcode the checkout path: renaming the directory then
# silently breaks the source-guard redirect, the permissions allowlist and the global
# CLAUDE.md. Instead a tracked file writes the placeholder @DOTFILES_DIR@ and the
# installers (hooks.sh, settings.sh, claude_md.sh, skills.sh) pass it through
# substitute_dotfiles_dir on its way to ~/.claude. deploy_drift.sh applies the same
# substitution before comparing, so a correct deploy never reads as drift.
#
# Sourced, never executed. Deployed verbatim (everything in hooks/lib/ ships).

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "dotfiles_dir.sh is meant to be sourced, not executed." >&2
    exit 1
fi

# resolve_dotfiles_dir [<any-path-inside-the-checkout>]
# $DOTFILES_DIR wins when set (tests, unusual layouts). Otherwise the MAIN working tree
# of the repo containing the path (default: this file): `--show-toplevel` alone would bake
# a throwaway agent worktree's path into the live config when deployed from one.
# shellcheck disable=SC2120 # optional public arg; callers live in other files (deploy_drift.sh, bin/rename_checkout.sh)
resolve_dotfiles_dir() {
    if [[ -n "${DOTFILES_DIR:-}" ]]; then
        printf '%s\n' "$DOTFILES_DIR"
        return 0
    fi

    local from="${1:-$(dirname "${BASH_SOURCE[0]}")}" common
    common="$(git -C "$from" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    if [[ "$(basename "$common")" == ".git" ]]; then
        dirname "$common"
    else
        git -C "$from" rev-parse --show-toplevel   # bare/odd layout: best available answer
    fi
}

# substitute_dotfiles_dir [<dir>] — stdin to stdout, @DOTFILES_DIR@ -> <dir>
# (default: resolve_dotfiles_dir). Fails, printing nothing, when no dir can be resolved,
# so a deploy never writes the raw placeholder into a live file.
# shellcheck disable=SC2120 # optional public arg; callers live in other files (deploy_drift.sh, bin/rename_checkout.sh)
substitute_dotfiles_dir() {
    local dir="${1:-}" escaped
    [[ -n "$dir" ]] || dir="$(resolve_dotfiles_dir)" || return 1
    escaped="$(printf '%s' "$dir" | sed 's/[|&\\]/\\&/g')"
    sed "s|@DOTFILES_DIR@|$escaped|g"
}

# install_with_dotfiles_dir <src> <dest> — cp, substituting the placeholder when present.
# Renders to a temp file first: a failed resolve must leave the old live file intact,
# not a truncated one.
install_with_dotfiles_dir() {
    local src="$1" dest="$2" tmp
    if ! grep -q '@DOTFILES_DIR@' "$src"; then
        cp "$src" "$dest"
        return
    fi
    tmp="$(mktemp "$dest.XXXXXX")" || return 1
    if substitute_dotfiles_dir < "$src" > "$tmp"; then
        chmod --reference="$src" "$tmp"
        mv "$tmp" "$dest"
    else
        rm -f "$tmp"
        return 1
    fi
}
