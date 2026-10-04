#!/usr/bin/env bats
#
# Invariant for every interactive prompt in the repo (dotfiles-linux-dev#337): no `read` may use
# `-n <count>` to grab a fixed number of characters from an interactive prompt.
#
# Why: `read -p "..." -n 1` puts the tty in non-canonical mode and returns after ONE character,
# so the Enter the operator presses after typing `n` is left in the TTY INPUT QUEUE. That queue
# belongs to the terminal, not the process, so the stray newline survives into the NEXT process
# reading the same tty. On the `make run` chain (lib/run_chain.sh) `set_shortcuts` runs
# immediately before `install_programs`, so the newline left by
# `distro_config/set_custom_shortcuts.sh`'s conflict prompt was consumed by
# `distro_config/install_programs.sh`'s `read -r choice` as an EMPTY LINE — a successful read,
# not EOF. That fell through to `*) Invalid option`, and the menu's `while true` re-printed the
# whole banner, which reads to the operator as the setup restarting.
#
# The fix is to let `read` consume the whole line, newline included. This test is the guard that
# keeps `-n 1` from creeping back in the next time someone wants a "press any key" prompt.
#
# Run locally:  bats tests/            (install with: sudo apt-get install -y bats)

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

# Every tracked *.sh, so the invariant follows new scripts automatically.
tracked_shell_scripts() {
    git -C "$REPO_ROOT" ls-files -- '*.sh'
}

@test "no interactive read consumes a fixed character count (read -n/-N)" {
    local offenders=""
    local f

    while IFS= read -r f; do
        [ -f "$REPO_ROOT/$f" ] || continue
        # `read` on the same line as a -n/-N flag, ignoring comment lines.
        local hits
        hits="$(grep -nE '^[[:space:]]*[^#]*\bread\b[^|]*[[:space:]]-[nN][[:space:]]*[0-9]' \
            "$REPO_ROOT/$f" || true)"
        [ -z "$hits" ] || offenders+="$f:$hits"$'\n'
    done < <(tracked_shell_scripts)

    if [ -n "$offenders" ]; then
        printf 'read -n/-N leaves the operator Enter in the tty queue (see #337):\n%s' "$offenders"
        return 1
    fi
}

@test "the six prompts fixed by #337 still read a full line" {
    local pairs=(
        "distro_config/set_custom_shortcuts.sh|Do you want to continue anyway"
        "distro_config/set_custom_shortcuts.sh|verify for shortcut conflicts"
        "code_editors/vscode_restore.sh|Do you want to restore from backup"
        "code_editors/vscode_restore.sh|Enter choice \[1-3\]"
        "storage/format_neat.sh|Enable encryption"
        "storage/format_hard.sh|Are you absolutely sure"
    )

    local pair file prompt line
    for pair in "${pairs[@]}"; do
        file="${pair%%|*}"
        prompt="${pair#*|}"
        line="$(grep -E "\bread\b.*$prompt" "$REPO_ROOT/$file")"
        [ -n "$line" ]
        [[ "$line" != *" -n "* ]]
    done
}
