#!/usr/bin/env bats
#
# Unit tests for uninstall_insync (issue #360: replace Insync with an
# on-demand rclone mount). The 5-step ordered removal is the whole safety
# story here — deleting ~/Insync while the daemon is still running
# propagates the deletion to the remote account. Every precondition is stubbed
# (pgrep, rclone, sudo, apt, dpkg, insync); no real process is inspected, no
# real package is removed, and nothing under a real $HOME is ever touched.
#
# Issue #577: step 2's rclone check ran with the remote as SOURCE
# (`rclone check "$remote:" "$account_dir" --one-way --dry-run`), which only
# proves remote files exist locally — the wrong guarantee before rm -rf
# "$account_dir". The tests below assert the corrected call: local dir
# first (source), remote second (destination), --one-way --size-only, no
# --dry-run, and a refusal on any non-empty --missing-on-dst/--differ list.
#
# Run locally: bats tests/

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP="$(mktemp -d)"
    HOME="$TMP/home"
    mkdir -p "$HOME"
    export HOME
    export LOG_FILE="$TMP/log"
    mkdir -p "$TMP/bin"
    export PATH="$TMP/bin:$PATH"

    ACCOUNT_DIR="$HOME/Insync/testaccount"
    mkdir -p "$ACCOUNT_DIR"
    echo "remote-backed file" > "$ACCOUNT_DIR/file.txt"

    # No live process by default. Three ways to keep one "alive":
    #   PGREP_INSYNC_RUNNING=1   never exits
    #   PGREP_EXIT_AFTER_POLLS=n exits once pgrep has been called n times
    #   PGREP_EXIT_ON_TERM=1     ignores `insync quit`, exits once kill -TERM ran
    # `-a` prints "pid name" like the real pgrep; without it, just the pid.
    export KILL_LOG="$TMP/kill_invocations.log"
    export PGREP_COUNT_FILE="$TMP/pgrep_count"
    cat > "$TMP/bin/pgrep" <<'STUB'
#!/bin/bash
running=0
[ "${PGREP_INSYNC_RUNNING:-0}" = "1" ] && running=1
if [ "${PGREP_EXIT_AFTER_POLLS:-0}" -gt 0 ]; then
    n=$(cat "$PGREP_COUNT_FILE" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" > "$PGREP_COUNT_FILE"
    [ "$n" -le "$PGREP_EXIT_AFTER_POLLS" ] && running=1
fi
if [ "${PGREP_EXIT_ON_TERM:-0}" = "1" ] && ! grep -q -- '-TERM' "$KILL_LOG" 2>/dev/null; then
    running=1
fi
[ "$running" = "1" ] || exit 1
if [ "$1" = "-a" ]; then echo "12345 insync"; else echo "12345"; fi
exit 0
STUB
    chmod +x "$TMP/bin/pgrep"

    # sleep: record only, so the bounded poll loop never really waits.
    export SLEEP_LOG="$TMP/sleep_invocations.log"
    cat > "$TMP/bin/sleep" <<'STUB'
#!/bin/bash
echo "sleep $*" >> "$SLEEP_LOG"
STUB
    chmod +x "$TMP/bin/sleep"

    # kill is a shell builtin, so a PATH stub would never be reached — shadow
    # it with a function. Records the call; never signals a real process.
    kill() { echo "kill $*" >> "$KILL_LOG"; }

    # rclone: check/lsjson controllable via env; never a real network call.
    # For `check`, honours RCLONE_CHECK_FAIL (generic non-zero exit),
    # RCLONE_CHECK_MISSING and RCLONE_CHECK_DIFFER (write one path into the
    # --missing-on-dst / --differ file rclone was given, then exit 1) so
    # tests can simulate a non-empty list without a real remote.
    cat > "$TMP/bin/rclone" <<'STUB'
#!/bin/bash
echo "$*" >> "$RCLONE_LOG"
case "$1" in
    check)
        missing_file=""
        differ_file=""
        prev=""
        for arg in "$@"; do
            [ "$prev" = "--missing-on-dst" ] && missing_file="$arg"
            [ "$prev" = "--differ" ] && differ_file="$arg"
            prev="$arg"
        done
        [ -n "$missing_file" ] && : > "$missing_file"
        [ -n "$differ_file" ] && : > "$differ_file"
        if [ "${RCLONE_CHECK_MISSING:-0}" = "1" ]; then
            echo "local-only-file.txt" >> "$missing_file"
        fi
        if [ "${RCLONE_CHECK_DIFFER:-0}" = "1" ]; then
            echo "differs.txt" >> "$differ_file"
        fi
        if [ "${RCLONE_CHECK_FAIL:-0}" = "1" ]; then
            echo "ERROR : a/b.html: error reading destination directory: couldn't list files"
            echo "NOTICE: 1 errors while checking"
        fi
        if [ "${RCLONE_CHECK_FAIL:-0}" = "1" ] || [ "${RCLONE_CHECK_MISSING:-0}" = "1" ] \
            || [ "${RCLONE_CHECK_DIFFER:-0}" = "1" ]; then
            exit 1
        fi
        echo "0 differences found"
        exit 0
        ;;
    lsjson) echo "[]"; exit 0 ;;
    *) exit 0 ;;
esac
STUB
    chmod +x "$TMP/bin/rclone"
    export RCLONE_LOG="$TMP/rclone_invocations.log"

    # dpkg -l: report insync present/absent per DPKG_INSYNC_PRESENT.
    cat > "$TMP/bin/dpkg" <<'STUB'
#!/bin/bash
if [ "$1" = "-l" ]; then
    if [ "${DPKG_INSYNC_PRESENT:-0}" = "1" ]; then
        echo "ii  insync  3.9.6  amd64  Insync"
    fi
    exit 0
fi
exit 0
STUB
    chmod +x "$TMP/bin/dpkg"
    export DPKG_INSYNC_PRESENT=0

    # sudo/apt: log only, never a real removal.
    cat > "$TMP/bin/sudo" <<'STUB'
#!/bin/bash
echo "sudo $*" >> "$SUDO_LOG"
"$@"
STUB
    chmod +x "$TMP/bin/sudo"
    cat > "$TMP/bin/apt" <<'STUB'
#!/bin/bash
echo "apt $*" >> "$APT_LOG"
exit 0
STUB
    chmod +x "$TMP/bin/apt"
    export SUDO_LOG="$TMP/sudo_invocations.log"
    export APT_LOG="$TMP/apt_invocations.log"

    # insync quit: a no-op stub, tracked so we can assert it was called.
    cat > "$TMP/bin/insync" <<'STUB'
#!/bin/bash
echo "insync $*" >> "$INSYNC_LOG"
exit 0
STUB
    chmod +x "$TMP/bin/insync"
    export INSYNC_LOG="$TMP/insync_invocations.log"

    # shellcheck source=../distro_config/install_lib/_common.sh
    source "$REPO_ROOT/distro_config/install_lib/_common.sh"
    PACKAGE_MANAGER="apt"

    # shellcheck source=../distro_config/install_lib/sharing.sh
    source "$REPO_ROOT/distro_config/install_lib/sharing.sh"
}

teardown() {
    rm -rf "$TMP"
}

# --- never registered: a registry entry would fight install_insync (#342) --

@test "uninstall_insync is not in INSTALL_REGISTRY" {
    local entry
    for entry in "${INSTALL_REGISTRY[@]}"; do
        [[ "$entry" != uninstall_insync:* ]]
    done
}

@test "no INSTALL_REGISTRY entry runs an uninstall_* function" {
    local entry fn
    for entry in "${INSTALL_REGISTRY[@]}"; do
        IFS=':' read -r fn _ _ _ <<< "$entry"
        [[ "$fn" != uninstall_* ]]
    done
}

# --- step 1: refuses to continue while a live process survives -------------

@test "uninstall_insync refuses when a live insync process is detected" {
    export PGREP_INSYNC_RUNNING=1
    run uninstall_insync gdrive "$ACCOUNT_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"still running"* ]]
    # No deletion path was even reached.
    [ -d "$ACCOUNT_DIR" ]
    [ -f "$ACCOUNT_DIR/file.txt" ]
}

# --- step 2: refuses when the remote comparison fails -----------------------

@test "uninstall_insync refuses when the remote verification step fails" {
    export RCLONE_CHECK_FAIL=1
    run uninstall_insync gdrive "$ACCOUNT_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not fully backed up to the remote"* ]]
    [[ "$output" == *"refusing to delete anything"* ]]
    # Package removal must not have been attempted past this precondition.
    [ ! -f "$APT_LOG" ]
    [ -d "$ACCOUNT_DIR" ]
}

@test "a refusal from rclone errors alone names the cause and keeps the output (#677)" {
    export RCLONE_CHECK_FAIL=1
    run uninstall_insync gdrive "$ACCOUNT_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"exited 1 with no missing/differ entries"* ]]
    [[ "$output" == *"errors while checking"* ]]
    grep -q "error reading destination directory" "$TMP/uninstall_insync_check.log"
    [ -d "$ACCOUNT_DIR" ]
}

@test "the check output is kept next to the lists even with LOG_FILE unset (#677)" {
    export RCLONE_CHECK_FAIL=1
    unset LOG_FILE
    cd "$TMP"
    run uninstall_insync gdrive "$ACCOUNT_DIR"
    [ "$status" -eq 1 ]
    grep -q "errors while checking" "$TMP/uninstall_insync_check.log"
    [[ "$output" == *"Full rclone output: ./uninstall_insync_check.log"* ]]
}

@test "uninstall_insync refuses when the remote name is missing" {
    run uninstall_insync "" "$ACCOUNT_DIR"
    [ "$status" -eq 1 ]
}

@test "uninstall_insync refuses when the local account directory does not exist" {
    run uninstall_insync gdrive "$HOME/Insync/does-not-exist"
    [ "$status" -eq 1 ]
}

# --- issue #577: check direction, flags, and non-empty-list refusal --------

@test "uninstall_insync's rclone check has local dir as source, remote as destination" {
    run uninstall_insync gdrive "$ACCOUNT_DIR"
    [ "$status" -eq 0 ]
    grep -qF "check $ACCOUNT_DIR gdrive: --one-way --size-only" "$RCLONE_LOG"
}

# #667: without this flag rclone hides OneNote notebooks, so every .one/.onetoc2 reads as
# "missing on the remote" and step 2 refuses forever on any account that has notebooks.
@test "uninstall_insync's rclone check exposes OneNote notebooks" {
    run uninstall_insync gdrive "$ACCOUNT_DIR"
    [ "$status" -eq 0 ]
    grep -E "^check .*--onedrive-expose-onenote-files" "$RCLONE_LOG"
}

@test "uninstall_insync's rclone check never passes --dry-run" {
    run uninstall_insync gdrive "$ACCOUNT_DIR"
    [ "$status" -eq 0 ]
    run grep -q -- "--dry-run" "$RCLONE_LOG"
    [ "$status" -ne 0 ]
}

@test "uninstall_insync refuses and deletes nothing when a file is missing on the remote" {
    export RCLONE_CHECK_MISSING=1
    run uninstall_insync gdrive "$ACCOUNT_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"refusing to delete anything"* ]]
    [[ "$output" == *"Files missing on remote:"* ]]
    [[ "$output" == *"Files that differ:"* ]]
    [ ! -f "$APT_LOG" ]
    [ -d "$ACCOUNT_DIR" ]
    [ -f "$ACCOUNT_DIR/file.txt" ]
}

@test "uninstall_insync refuses and deletes nothing when a file differs from the remote" {
    export RCLONE_CHECK_DIFFER=1
    run uninstall_insync gdrive "$ACCOUNT_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"refusing to delete anything"* ]]
    [ ! -f "$APT_LOG" ]
    [ -d "$ACCOUNT_DIR" ]
    [ -f "$ACCOUNT_DIR/file.txt" ]
}

# --- step 4: local deletion requires the explicit opt-in --------------------

@test "uninstall_insync does not delete local data without INSYNC_CONFIRM_DELETE=1" {
    unset INSYNC_CONFIRM_DELETE
    run uninstall_insync gdrive "$ACCOUNT_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"skipped"* ]]
    [ -d "$ACCOUNT_DIR" ]
    [ -f "$ACCOUNT_DIR/file.txt" ]
}

@test "uninstall_insync deletes local data only with INSYNC_CONFIRM_DELETE=1" {
    export INSYNC_CONFIRM_DELETE=1
    run uninstall_insync gdrive "$ACCOUNT_DIR"
    [ "$status" -eq 0 ]
    [ ! -d "$ACCOUNT_DIR" ]
    [ ! -d "$HOME/.config/Insync" ]
}

@test "uninstall_insync full run reaches step 5 and re-checks the remote" {
    export INSYNC_CONFIRM_DELETE=1
    run uninstall_insync gdrive "$ACCOUNT_DIR"
    [ "$status" -eq 0 ]
    grep -q '^lsjson' "$RCLONE_LOG"
}

@test "uninstall_insync quits insync before checking for a surviving process" {
    export INSYNC_CONFIRM_DELETE=1
    run uninstall_insync gdrive "$ACCOUNT_DIR"
    [ -f "$INSYNC_LOG" ]
    grep -qF 'insync quit' "$INSYNC_LOG"
}

# --- issue #599: sharing.sh sourced directly must be self-sufficient --------

@test "sharing.sh sourced on its own defines print_status and command_exists" {
    run bash -c 'source "$1/distro_config/install_lib/sharing.sh"
        declare -F print_status command_exists uninstall_insync' _ "$REPO_ROOT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"print_status"* ]]
    [[ "$output" == *"command_exists"* ]]
}

@test "documented invocation quits insync when sharing.sh is the only file sourced" {
    run bash -c 'source "$1/distro_config/install_lib/sharing.sh"
        uninstall_insync gdrive "$2"' _ "$REPO_ROOT" "$ACCOUNT_DIR"
    [ "$status" -eq 0 ]
    grep -qF 'insync quit' "$INSYNC_LOG"
}

# --- issue #599: step 1 polls, escalates to SIGTERM, never SIGKILL ----------

@test "step 1 waits for a slow insync to exit and sends no signal" {
    export PGREP_EXIT_AFTER_POLLS=5
    run uninstall_insync gdrive "$ACCOUNT_DIR"
    [ "$status" -eq 0 ]
    [ ! -f "$KILL_LOG" ]
    [ "$(wc -l < "$SLEEP_LOG")" -ge 3 ]
}

@test "step 1 sends SIGTERM when insync quit is ignored, then continues" {
    export PGREP_EXIT_ON_TERM=1
    run uninstall_insync gdrive "$ACCOUNT_DIR"
    [ "$status" -eq 0 ]
    grep -qF 'kill -TERM 12345' "$KILL_LOG"
}

@test "step 1 never sends SIGKILL, and refuses when SIGTERM is ignored too" {
    export PGREP_INSYNC_RUNNING=1
    run uninstall_insync gdrive "$ACCOUNT_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"still running"* ]]
    grep -qF 'kill -TERM' "$KILL_LOG"
    run grep -qE -- '-9|-KILL|SIGKILL' "$KILL_LOG"
    [ "$status" -ne 0 ]
    [ -d "$ACCOUNT_DIR" ]
    [ ! -f "$APT_LOG" ]
}

@test "step 1 wait is bounded by INSYNC_QUIT_TIMEOUT plus INSYNC_TERM_TIMEOUT" {
    export PGREP_INSYNC_RUNNING=1 INSYNC_QUIT_TIMEOUT=3 INSYNC_TERM_TIMEOUT=2
    run uninstall_insync gdrive "$ACCOUNT_DIR"
    [ "$status" -eq 1 ]
    [ "$(wc -l < "$SLEEP_LOG")" -eq 5 ]
}

# --- issue #599: provider is named generically ------------------------------

@test "uninstall_insync's own comments do not name a specific cloud provider" {
    local body
    body=$(sed -n '/^# UNINSTALL INSYNC/,/^# CLAMAV ANTIVIRUS/p' \
        "$REPO_ROOT/distro_config/install_lib/sharing.sh")
    [ -n "$body" ]
    [[ "$body" != *"Google Drive"* ]]
}
