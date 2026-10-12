#!/usr/bin/env bats
#
# install_claudestatus_bar / uninstall_claudestatus_bar (#734): copy (not symlink) the GNOME
# extension, install the helpers it reads, enable it, and write nothing under DRY_RUN=1.
# gnome-shell / gnome-extensions / node are stubbed on PATH, HOME is a temp dir.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin"
    for t in gnome-shell node; do printf '#!/bin/bash\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/$t"; done
    cat > "$BATS_TEST_TMPDIR/bin/gnome-extensions" <<'STUB'
#!/bin/bash
echo "$*" >> "$BATS_TEST_TMPDIR/ge.log"
[ "$1" = info ] && exit 1
exit 0
STUB
    chmod +x "$BATS_TEST_TMPDIR/bin/"*
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/distro_config/install_lib/_common.sh"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/distro_config/install_lib/system_utils.sh"
    EXT="$HOME/.local/share/gnome-shell/extensions/claudestatus-bar@dotfiles-dev"
    DATA="$HOME/.local/share/claudestatus-bar"
}

@test "copies the extension (a real dir, replacing a dev symlink) and the helpers, then enables it" {
    mkdir -p "$BATS_TEST_TMPDIR/old" "$(dirname "$EXT")"
    ln -s "$BATS_TEST_TMPDIR/old" "$EXT"
    run install_claudestatus_bar
    [ "$status" -eq 0 ]
    [ ! -L "$EXT" ]
    [ -f "$EXT/extension.js" ] && [ -f "$EXT/metadata.json" ]
    [ -f "$DATA/claudestatus_bar/model.mjs" ]
    [ -f "$DATA/claudestatus_bar/refresh.mjs" ]
    [ -f "$DATA/lib/claudestatus_billing.mjs" ]
    grep -qx "enable claudestatus-bar@dotfiles-dev" "$BATS_TEST_TMPDIR/ge.log"
    [[ "$output" == *"Restart GNOME Shell"* ]]
}

@test "extension.js reads the helpers from the installed data dir, not the repo" {
    run grep -F '/claudestatus-bar/claudestatus_bar' "$REPO_ROOT/ai_clients/claude/claudestatus_bar/gnome-extension/extension.js"
    [ "$status" -eq 0 ]
}

@test "DRY_RUN=1 writes nothing and never calls gnome-extensions enable" {
    DRY_RUN=1 run install_claudestatus_bar
    [ "$status" -eq 0 ]
    [ ! -e "$DATA" ]
    [ ! -e "$HOME/.local/share/gnome-shell" ]
    ! grep -q '^enable' "$BATS_TEST_TMPDIR/ge.log" 2>/dev/null
}

@test "uninstall removes the extension and the helpers" {
    install_claudestatus_bar
    run uninstall_claudestatus_bar
    [ "$status" -eq 0 ]
    [ ! -e "$EXT" ] && [ ! -e "$DATA" ]
    grep -qx "disable claudestatus-bar@dotfiles-dev" "$BATS_TEST_TMPDIR/ge.log"
}

@test "registered with an empty GNOME folder" {
    run grep -F '"install_claudestatus_bar:claudestatus top-bar (GNOME extension)::"' \
        "$REPO_ROOT/distro_config/install_lib/system_utils.sh"
    [ "$status" -eq 0 ]
}
