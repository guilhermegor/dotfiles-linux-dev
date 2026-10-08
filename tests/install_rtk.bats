#!/usr/bin/env bats
#
# install_rtk (dotfiles-linux-dev#633): rtk init must not block on its telemetry
# prompt and must never patch the deployed settings.json hooks.
# `rtk` is stubbed on PATH; the real installer is never run.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP="$(mktemp -d)"
    HOME="$TMP/home"
    mkdir -p "$HOME/.claude" "$TMP/bin"
    export HOME LOG_FILE="$TMP/log" TMP
    export PATH="$TMP/bin:$PATH"
    # shellcheck source=../distro_config/install_lib/_common.sh
    source "$REPO_ROOT/distro_config/install_lib/_common.sh"
    # shellcheck source=../distro_config/install_coding_lib/ai_clients.sh
    source "$REPO_ROOT/distro_config/install_coding_lib/ai_clients.sh"

    # Mimics rtk 0.37.2: records whether stdin is /dev/null (an open stdin is what
    # lets the telemetry prompt hang), appends a direct hook under --auto-patch,
    # writes RTK.md.
    cat > "$TMP/bin/rtk" <<'STUB'
#!/bin/bash
[ "$1" = "init" ] || exit 0
readlink /proc/self/fd/0 > "$TMP/stdin_target"
case " $* " in
    *" --auto-patch "*) echo '"rtk hook claude"' >> "$HOME/.claude/settings.json" ;;
esac
echo "# RTK" > "$HOME/.claude/RTK.md"
STUB
    chmod +x "$TMP/bin/rtk"
    echo '{"hooks":"rtk_worktree_passthrough.sh"}' > "$HOME/.claude/settings.json"
}

teardown() {
    rm -rf "$TMP"
}

@test "install_rtk runs rtk init with stdin closed" {
    : > "$TMP/caller_stdin"
    run install_rtk < "$TMP/caller_stdin"
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP/stdin_target")" = "/dev/null" ]
}

@test "install_rtk leaves a passthrough-wired settings.json unchanged" {
    before="$(cat "$HOME/.claude/settings.json")"
    run install_rtk
    [ "$status" -eq 0 ]
    [ "$(cat "$HOME/.claude/settings.json")" = "$before" ]
}

@test "install_rtk skips init when RTK.md already exists" {
    echo "# RTK" > "$HOME/.claude/RTK.md"
    run install_rtk
    [ "$status" -eq 0 ]
    [[ "$output" == *"already initialized"* ]]
    [ ! -e "$TMP/stdin_target" ]
}
