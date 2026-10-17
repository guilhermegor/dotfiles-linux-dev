#!/bin/bash
#
# drivers/nvidia_settings_folder.sh
#
# Place NVIDIA X Server Settings in the GNOME System folder (#796). The driver
# is installed outside this repo (Ubuntu installer / ubuntu-drivers), after
# ubuntu_workspace.sh last ran, so its .desktop never reaches the Sistema list
# until the folders are re-organised. Run this after installing the driver.

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

main() {
    local repo_root
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

    if [ ! -f /usr/share/applications/nvidia-settings.desktop ]; then
        print_status "warning" "nvidia-settings.desktop not found — install the NVIDIA driver first"
        return 0
    fi

    print_status "config" "Re-organising GNOME app folders (folders only)..."
    run_or_echo bash "$repo_root/distro_config/ubuntu_workspace.sh" --folders-only
}

main "$@"
