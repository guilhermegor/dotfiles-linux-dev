#!/usr/bin/env bats
#
# storage/backup_env.sh bundles selected git-ignored .env files (and, when
# present, ~/.config/rclone/rclone.conf) into ONE gpg-encrypted archive and
# must never write a plaintext copy to the backup drive. The passphrase is
# fed to gpg over stdin (--passphrase-fd 0), never as a CLI argument
# (dotfiles-linux-dev#367).
#
# zenity/gpg/notify-send are stubbed on PATH — no real GUI, no real
# encryption, no real backup drive is ever touched.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP="$(mktemp -d)"
    # Source the script for its helpers only: it defines functions, then calls main at the end.
    FUNCS="$TMP/funcs.sh"
    sed '/^main$/d' "$REPO_ROOT/storage/backup_env.sh" > "$FUNCS"

    HOME="$TMP/home"; export HOME
    mkdir -p "$HOME/.claude" "$HOME/github"

    BACKUP_DRIVE="$TMP/backupdrive"
    mkdir -p "$BACKUP_DRIVE"
    echo "CLAUDE_BACKUP_DIR=$BACKUP_DRIVE" > "$HOME/.claude/.env"

    mkdir -p "$HOME/github/proj1"
    (cd "$HOME/github/proj1" && git init -q && echo ".env" > .gitignore && echo "SECRET=1" > .env)

    SELECTED_FILE="$TMP/selected.txt"
    printf '%s\n' "$HOME/github/proj1/.env" > "$SELECTED_FILE"
    export SELECTED_FILE

    ZENITY_DONE_ARGS_FILE="$TMP/zenity_done_args"
    export ZENITY_DONE_ARGS_FILE
    GPG_ARGS_FILE="$TMP/gpg_args"
    export GPG_ARGS_FILE
    PASSPHRASE="hunter2-passphrase"
    export PASSPHRASE

    STUBS="$TMP/stubs"
    mkdir -p "$STUBS"
    PATH="$STUBS:$PATH"

    cat > "$STUBS/notify-send" <<'EOF'
#!/bin/bash
exit 0
EOF

    cat > "$STUBS/gpg" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$GPG_ARGS_FILE"
cat > /dev/null   # consume the passphrase fed on stdin (never read as an arg)
args=("$@")
output=""
for i in "${!args[@]}"; do
    if [[ "${args[$i]}" == "--output" ]]; then
        output="${args[$((i+1))]}"
    fi
done
input="${args[-1]}"
cp "$input" "$output"
EOF

    cat > "$STUBS/zenity" <<'EOF'
#!/bin/bash
case "$*" in
    *"set passphrase"*) echo "$PASSPHRASE" ;;
    *"confirm passphrase"*) echo "$PASSPHRASE" ;;
    *--checklist*) cat "$SELECTED_FILE" ;;
    *"Backup Env — done"*) printf '%s' "$*" > "$ZENITY_DONE_ARGS_FILE" ;;
    *) exit 0 ;;
esac
EOF

    chmod +x "$STUBS/notify-send" "$STUBS/gpg" "$STUBS/zenity"

    source "$FUNCS"
}

teardown() {
    rm -rf "$TMP"
}

@test "backup writes only an encrypted .gpg bundle, never a plaintext file" {
    run main
    [ "$status" -eq 0 ]

    local target="$BACKUP_DRIVE/env_bundle"
    [ -d "$target" ]

    local total gpg_files
    total=$(find "$target" -maxdepth 1 -type f | wc -l)
    gpg_files=$(find "$target" -maxdepth 1 -type f -name '*.tar.gpg' | wc -l)
    [ "$total" -eq 1 ]
    [ "$gpg_files" -eq 1 ]
}

@test "the passphrase never reaches gpg's argv — only --passphrase-fd 0" {
    run main
    [ "$status" -eq 0 ]

    [ -f "$GPG_ARGS_FILE" ]
    run cat "$GPG_ARGS_FILE"
    [[ "$output" == *"--passphrase-fd"* ]]
    [[ "$output" == *"0"* ]]
    [[ "$output" != *"$PASSPHRASE"* ]]
}

@test "existing legacy plaintext copies are reported, never deleted" {
    mkdir -p "$BACKUP_DRIVE/env_files"
    echo "old plaintext" > "$BACKUP_DRIVE/env_files/proj1__env_20260101_000000.gz"

    run main
    [ "$status" -eq 0 ]

    # Never deleted.
    [ -f "$BACKUP_DRIVE/env_files/proj1__env_20260101_000000.gz" ]

    # Reported by exact path in the final summary.
    [ -f "$ZENITY_DONE_ARGS_FILE" ]
    run cat "$ZENITY_DONE_ARGS_FILE"
    [[ "$output" == *"$BACKUP_DRIVE/env_files/proj1__env_20260101_000000.gz"* ]]
    [[ "$output" == *"Legacy plaintext"* ]]
}
