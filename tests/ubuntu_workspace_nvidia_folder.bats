#!/usr/bin/env bats
#
# #796: nvidia-settings.desktop must land in the Sistema (System) folder list
# whenever it exists on disk, and `--folders-only` must re-run just that step.
# Reads are stubbed; DRY_RUN=1 routes every `gsettings set` to stdout.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    STUBS="$(mktemp -d)"
    cat > "$STUBS/gsettings" <<'S'
#!/bin/bash
[ "$1" = "get" ] && { echo "''"; exit 0; }
exit 0
S
    printf '#!/bin/bash\nexit 0\n' > "$STUBS/dconf"
    chmod +x "$STUBS/gsettings" "$STUBS/dconf"
    export HOME="$STUBS/home" DRY_RUN=1 PATH="$STUBS:$PATH"
    mkdir -p "$HOME/.local/share/applications"
    # find_app_desktop_file also checks ~/.local/share/applications, so a stub
    # desktop file there makes the test independent of the host's NVIDIA driver.
    : > "$HOME/.local/share/applications/nvidia-settings.desktop"
}

teardown() { rm -rf "$STUBS"; }

@test "--folders-only puts nvidia-settings in the Sistema apps list" {
    run bash "$REPO_ROOT/distro_config/ubuntu_workspace.sh" --folders-only
    [ "$status" -eq 0 ]
    [[ "$output" == *"Sistema/ apps"*"'nvidia-settings.desktop'"* ]]
}

@test "--folders-only skips the full appearance run" {
    run bash "$REPO_ROOT/distro_config/ubuntu_workspace.sh" --folders-only
    [ "$status" -eq 0 ]
    [[ "$output" != *"Starting Ubuntu appearance configuration"* ]]
}

# --- additive mode + watcher unit (#796) -------------------------------------

additive_stubs() {
    cat > "$STUBS/gsettings" <<'S'
#!/bin/bash
if [ "$1" = "get" ]; then
    case "$2 $3" in
        *Sistema/*" apps") echo "['hand-placed.desktop']" ;;
        "org.gnome.desktop.app-folders folder-children") echo "['Sistema', 'HandMade']" ;;
        *) echo "''" ;;
    esac
fi
exit 0
S
}

@test "additive keeps a hand-placed id AND adds nvidia-settings" {
    additive_stubs
    run bash "$REPO_ROOT/distro_config/ubuntu_workspace.sh" --folders-only --additive
    [ "$status" -eq 0 ]
    sistema=$(grep -a "dry-run.*Sistema/ apps" <<< "$output")
    [[ "$sistema" == *"'hand-placed.desktop'"* ]]
    [[ "$sistema" == *"'nvidia-settings.desktop'"* ]]
}

@test "additive keeps unmanaged folders in folder-children" {
    additive_stubs
    run bash "$REPO_ROOT/distro_config/ubuntu_workspace.sh" --folders-only --additive
    [[ "$output" == *"folder-children"*"'HandMade'"* ]]
}

@test "additive never writes a folder name or resets a folder" {
    additive_stubs
    run bash "$REPO_ROOT/distro_config/ubuntu_workspace.sh" --folders-only --additive
    [ "$status" -eq 0 ]
    [[ "$output" != *"dry-run] gsettings set "*" name "* ]]
    [[ "$output" != *"reset-recursively"* ]]
}

@test "path/service units run --folders-only --additive" {
    grep -q -- "--folders-only --additive" "$REPO_ROOT/distro_config/systemd/app-folders.service"
    grep -q "^PathChanged=/usr/share/applications" "$REPO_ROOT/distro_config/systemd/app-folders.path"
    grep -q "^StartLimitBurst=" "$REPO_ROOT/distro_config/systemd/app-folders.service"
}

@test "installer enables the path unit via systemctl --user" {
    printf '#!/bin/bash\necho "$*" >> "%s/systemctl.log"\n' "$STUBS" > "$STUBS/systemctl"
    chmod +x "$STUBS/systemctl"
    export DRY_RUN=0
    # shellcheck source=/dev/null
    source "$REPO_ROOT/distro_config/ubuntu_workspace.sh" >/dev/null
    install_app_folder_watcher >/dev/null
    grep -q -- "--user enable --now app-folders.path" "$STUBS/systemctl.log"
    grep -q -- "--folders-only --additive" "$HOME/.config/systemd/user/app-folders.service"
    run grep "@WORKSPACE_SCRIPT@" "$HOME/.config/systemd/user/app-folders.service"
    [ "$status" -ne 0 ]
}
