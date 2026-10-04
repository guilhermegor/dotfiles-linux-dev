#!/usr/bin/env bats
#
# storage/restore_env.sh decrypts an env bundle and restores each file mode
# 600, never overwriting an existing file. After restoring rclone.conf it
# runs a cheap `rclone lsd <remote>: --max-depth 1` check and, on failure,
# points at `rclone config reconnect <remote>:` instead of leaving a broken
# mount silently in place (dotfiles-linux-dev#367).
#
# zenity/gpg/rclone/notify-send are stubbed on PATH — no real GUI, no real
# decryption, no real rclone remote is ever touched. gpg's stub performs no
# actual crypto; it just copies the bundle through, so bundle fixtures below
# are plain tars saved with a .tar.gpg name.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP="$(mktemp -d)"
    FUNCS="$TMP/funcs.sh"
    sed '/^main$/d' "$REPO_ROOT/storage/restore_env.sh" > "$FUNCS"

    HOME="$TMP/home"; export HOME
    mkdir -p "$HOME/.claude" "$HOME/github"

    BACKUP_DRIVE="$TMP/backupdrive"
    BUNDLE_DIR="$BACKUP_DRIVE/env_bundle"
    mkdir -p "$BUNDLE_DIR"
    echo "CLAUDE_BACKUP_DIR=$BACKUP_DRIVE" > "$HOME/.claude/.env"

    ZENITY_DONE_ARGS_FILE="$TMP/zenity_done_args"
    export ZENITY_DONE_ARGS_FILE
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
cat > /dev/null   # consume the passphrase fed on stdin
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
    *"enter passphrase"*) echo "$PASSPHRASE" ;;
    *"Restore Env — done"*) printf '%s' "$*" > "$ZENITY_DONE_ARGS_FILE" ;;
    *) exit 0 ;;
esac
EOF

    # Default rclone stub: no remotes, nothing to verify. Individual tests
    # override this when they need remote/lsd behaviour.
    cat > "$STUBS/rclone" <<'EOF'
#!/bin/bash
case "$1" in
    listremotes) ;;
    *) exit 0 ;;
esac
EOF

    chmod +x "$STUBS/notify-send" "$STUBS/gpg" "$STUBS/zenity" "$STUBS/rclone"

    source "$FUNCS"
}

teardown() {
    rm -rf "$TMP"
}

# Builds env_bundle_<ts>.tar.gpg from a staging tree the caller already populated.
build_fixture_bundle() {
    local staging="$1"
    local ts="${2:-20260101_000000}"
    tar -C "$staging" -cf "$BUNDLE_DIR/env_bundle_${ts}.tar.gpg" .
}

@test "restore writes the file mode 600" {
    local staging="$TMP/staging"
    mkdir -p "$staging/env_files"
    echo "SECRET=1" > "$staging/env_files/proj1__env"
    build_fixture_bundle "$staging"

    run main
    [ "$status" -eq 0 ]

    local dest="$HOME/github/proj1/.env"
    [ -f "$dest" ]
    [ "$(grep -c SECRET "$dest")" -eq 1 ]

    local mode
    mode=$(stat -c '%a' "$dest")
    [ "$mode" = "600" ]
}

@test "restore refuses to overwrite an existing file and reports the skip" {
    mkdir -p "$HOME/github/proj1"
    echo "EXISTING=1" > "$HOME/github/proj1/.env"

    local staging="$TMP/staging"
    mkdir -p "$staging/env_files"
    echo "SECRET=1" > "$staging/env_files/proj1__env"
    build_fixture_bundle "$staging"

    run main
    [ "$status" -eq 0 ]

    # Original file untouched.
    run cat "$HOME/github/proj1/.env"
    [[ "$output" == "EXISTING=1" ]]

    # Reported as skipped in the summary.
    [ -f "$ZENITY_DONE_ARGS_FILE" ]
    run cat "$ZENITY_DONE_ARGS_FILE"
    [[ "$output" == *"Skipped"* ]]
    [[ "$output" == *"already exists"* ]]
}

@test "a failed post-restore rclone check prints the reconnect command" {
    cat > "$STUBS/rclone" <<'EOF'
#!/bin/bash
case "$1" in
    listremotes) echo "myremote:" ;;
    lsd) exit 1 ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$STUBS/rclone"

    local staging="$TMP/staging"
    mkdir -p "$staging/rclone"
    echo "[myremote]" > "$staging/rclone/rclone.conf"
    build_fixture_bundle "$staging"

    run main
    [ "$status" -eq 0 ]

    local dest="$HOME/.config/rclone/rclone.conf"
    [ -f "$dest" ]
    local mode
    mode=$(stat -c '%a' "$dest")
    [ "$mode" = "600" ]

    [ -f "$ZENITY_DONE_ARGS_FILE" ]
    run cat "$ZENITY_DONE_ARGS_FILE"
    [[ "$output" == *"rclone config reconnect myremote:"* ]]
}
