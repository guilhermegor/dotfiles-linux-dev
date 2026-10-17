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
