#!/usr/bin/env bats
#
# Invariant for issue #114 (GNOME app folders regrouped by artifact produced).
#
# Folder placement is driven by TWO sources that must stay in sync: the
# `gnome_folder` field on INSTALL_REGISTRY entries, and the folder IDs that
# organize_app_folders() actually creates (gsettings folder-children) in
# distro_config/ubuntu_workspace.sh. Renaming/removing a folder in one place
# but not the other silently drops apps from the GNOME app grid — this test
# catches that drift.
#
# Sourcing (not executing) ubuntu_workspace.sh populates INSTALL_REGISTRY
# from install_lib/*.sh + install_coding_lib/*.sh and defines
# organize_app_folders() without running main() or touching gsettings.
#
# Run locally: bats tests/

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    HOME="$(mktemp -d)"
    export HOME
    export DRY_RUN=1

    # Stub the READ paths organize_app_folders hits unconditionally (`gsettings
    # get`, `dconf list`) so the uniqueness test below never depends on, or
    # touches, this machine's real dconf state. DRY_RUN=1 above already routes
    # every mutating `gsettings set` through run_or_echo (printed, never run) —
    # this covers the reads that aren't gated by DRY_RUN.
    gsettings() {
        [ "$1" = "get" ] && { echo "''"; return 0; }
        return 0
    }
    export -f gsettings
    dconf() { return 0; }
    export -f dconf

    # shellcheck source=../distro_config/ubuntu_workspace.sh
    source "$REPO_ROOT/distro_config/ubuntu_workspace.sh"
}

teardown() {
    rm -rf "$HOME"
}

@test "organize_app_folders creates at least one folder" {
    local created
    created=$(declare -f organize_app_folders | grep -oE "folder_ids\+=\(\"'[A-Za-z]+'\"\)")
    [ -n "$created" ]
}

@test "every non-empty INSTALL_REGISTRY gnome_folder is a folder organize_app_folders creates" {
    local created
    created=$(declare -f organize_app_folders \
        | grep -oE "folder_ids\+=\(\"'[A-Za-z]+'\"\)" \
        | grep -oE "'[A-Za-z]+'" \
        | tr -d "'")

    local entry fn _label folder _desktop
    for entry in "${INSTALL_REGISTRY[@]}"; do
        IFS=':' read -r fn _label folder _desktop <<< "$entry"
        [ -z "$folder" ] && continue
        if ! grep -qx "$folder" <<< "$created"; then
            echo "gnome_folder '$folder' (from '$fn') is not created by organize_app_folders" >&2
            return 1
        fi
    done
}

# Issue #342: an uninstall_* entry placed after its install_* counterpart in
# INSTALL_REGISTRY runs during Full Installation too (entry order = run
# order), immediately undoing the install it just did. Uninstallers must stay
# plain functions the user invokes manually, never registry entries.
@test "no INSTALL_REGISTRY entry runs an uninstall_* function in Full Installation" {
    local entry fn _label _folder _desktop
    for entry in "${INSTALL_REGISTRY[@]}"; do
        IFS=':' read -r fn _label _folder _desktop <<< "$entry"
        if [[ "$fn" == uninstall_* ]]; then
            echo "INSTALL_REGISTRY runs '$fn' during Full Installation — uninstallers must not be registered" >&2
            return 1
        fi
    done
}

# A snap's .desktop file is named `<snap>_<app>.desktop`, never `<app>.desktop`. Declaring the
# unmangled name places nothing: figma-linux sat loose in the app grid for as long as the registry
# said `figma-linux.desktop` while snapd had written `figma-linux_figma-linux.desktop`.
# Enforced only where snap is the SOLE install method — when a function can also install via
# flatpak/apt/.deb, which id is correct depends on the path that ran, so it cannot be decided here.
@test "a snap-only registry app declares the snap-mangled <snap>_*.desktop id" {
    local entry fn _label _folder desktop body snap others bad=""
    for entry in "${INSTALL_REGISTRY[@]}"; do
        IFS=':' read -r fn _label _folder desktop <<< "$entry"
        [ -n "$desktop" ] || continue
        body="$(declare -f "$fn" 2>/dev/null)" || continue
        snap="$(grep -oE 'snap install( --classic)? [a-z0-9-]+' <<<"$body" | awk '{print $NF}' | head -n1)"
        [ -n "$snap" ] || continue
        others="$(grep -cE 'flatpak install|apt(-get)? install|dpkg -i|\.deb' <<<"$body" || true)"
        [ "$others" -eq 0 ] || continue
        [[ "$desktop" == "${snap}_"*.desktop ]] || bad+=" $fn($desktop, snap=$snap)"
    done
    [ -z "$bad" ] || { echo "snap-only apps with an unmangled desktop id:$bad"; return 1; }
}

@test "an unresolved registry desktop id is reported, not dropped in silence" {
    local fn_body
    fn_body="$(declare -f organize_app_folders)"
    [[ "$fn_body" == *'MISSING_DESKTOP_IDS+=('* ]]
    [[ "$fn_body" == *'Registry apps not placed'* ]]
}

# Issue #565: Microsoft's .deb renamed VS Code's launcher to the reverse-DNS id
# com.microsoft.VSCode.desktop; the registry still declared the pre-rename
# `code.desktop`, which resolves to nothing on any installed system.

@test "install_vscode's registry entry names the real installed launcher, not the pre-rename id" {
    local entry fn _label _folder desktop found=""
    for entry in "${INSTALL_REGISTRY[@]}"; do
        IFS=':' read -r fn _label _folder desktop <<< "$entry"
        [ "$fn" = "install_vscode" ] || continue
        found="$desktop"
        break
    done
    [ "$found" = "com.microsoft.VSCode.desktop" ]
}

# The resolver (find_app_desktop_file, nested in organize_app_folders) is what
# turns "verify before writing" into "fail loud, don't guess". Asserted
# statically against the function's own source text — the same style already
# used above for MISSING_DESKTOP_IDS — because /usr/share/applications,
# /var/lib/snapd/desktop/applications, and the flatpak export dir are not
# writable from an unprivileged test process.
@test "the resolver searches all four XDG application directories it claims to" {
    local fn_body
    fn_body="$(declare -f organize_app_folders)"
    [[ "$fn_body" == *'$HOME/.local/share/applications/$app_name'* ]]
    [[ "$fn_body" == *'/usr/share/applications/$app_name'* ]]
    [[ "$fn_body" == *'/var/lib/snapd/desktop/applications/$app_name'* ]]
    [[ "$fn_body" == *'/var/lib/flatpak/exports/share/applications/$app_name'* ]]
}

@test "organize_app_folders places the real VS Code launcher and drops the renamed-away code.desktop id" {
    mkdir -p "$HOME/.local/share/applications"
    # The launcher the installed .deb actually ships.
    : > "$HOME/.local/share/applications/com.microsoft.VSCode.desktop"
    # A decoy for the pre-rename id: its mere presence on disk must not be
    # enough to place it — nothing in the registry names it any more, and a
    # reconcile (full overwrite each run) must never append beside a stale id.
    : > "$HOME/.local/share/applications/code.desktop"

    run organize_app_folders
    [ "$status" -eq 0 ]

    [[ "$output" == *"'com.microsoft.VSCode.desktop'"* ]]
    [[ "$output" != *"'code.desktop'"* ]]
}

@test "a dangling registry desktop_file is reported by name and never written into a folder's apps list" {
    mkdir -p "$HOME/.local/share/applications"
    INSTALL_REGISTRY=(
        "install_fake_app:Fake App:Code:definitely-not-installed.desktop"
    )

    run organize_app_folders
    [ "$status" -eq 0 ]

    [[ "$output" == *"definitely-not-installed.desktop (install_fake_app -> Code)"* ]]
    [[ "$output" != *"'definitely-not-installed.desktop'"* ]]
}

# Issue #391: an app landed in two GNOME folders at once, and three
# independent mechanisms can each cause it — hardcoded <folder>_app_names id
# lists, INSTALL_REGISTRY's gnome_folder field, and filename globs — with no
# mechanism able to see what the other two already placed. A check that only
# compared the hardcoded lists would have missed the reported case (rustdesk:
# hardcoded in Infra's list, registry-declared for Sharing), so this test
# runs organize_app_folders() for real and inspects what it actually computed
# for every folder — the real per-folder arrays (hardcoded lists + registry
# merge + globs, post `sort -u`) — instead of a second hand-written model of
# the placement rules.
@test "no desktop id is placed into more than one gnome app folder" {
    mkdir -p "$HOME/.local/share/applications"

    # Touch every id ANY mechanism could place under $HOME, so
    # find_app_desktop_file()'s $HOME-first lookup resolves ALL of them
    # deterministically — independent of what is actually installed on the
    # machine running this suite.
    local id
    while IFS= read -r id; do
        [ -n "$id" ] && : > "$HOME/.local/share/applications/$id"
    done < <(declare -f organize_app_folders | grep -oE "'[A-Za-z0-9_.-]+\.desktop'" | tr -d "'" | sort -u)

    local entry fn _label _folder desktop
    for entry in "${INSTALL_REGISTRY[@]}"; do
        IFS=':' read -r fn _label _folder desktop <<< "$entry"
        [ -n "$desktop" ] && : > "$HOME/.local/share/applications/$desktop"
    done

    run organize_app_folders
    [ "$status" -eq 0 ]

    # Each "[dry-run] gsettings set ...folders/<Folder>/ apps ['a.desktop',...]"
    # line is one folder's FINAL computed membership. Flatten every line to
    # "app<TAB>folder" pairs, then any app with 2+ distinct folders is a
    # cross-folder duplicate.
    local pairs
    pairs=$(printf '%s\n' "$output" \
        | grep -oE "folders/[A-Za-z]+/ apps \[[^]]*\]" \
        | sed -E "s#folders/([A-Za-z]+)/ apps \[(.*)\]#\1"$'\t'"\2#" \
        | while IFS=$'\t' read -r folder apps_csv; do
              IFS=',' read -ra app_arr <<< "$apps_csv"
              local a
              for a in "${app_arr[@]}"; do
                  a="${a//\'/}"
                  printf '%s\t%s\n' "$a" "$folder"
              done
          done)

    local dupes
    dupes=$(printf '%s\n' "$pairs" | sort -u | cut -f1 | sort | uniq -d)

    if [ -n "$dupes" ]; then
        echo "desktop ids placed into 2+ folders:"
        local d
        while IFS= read -r d; do
            awk -F'\t' -v id="$d" '$1==id' <<< "$pairs"
        done <<< "$dupes"
        return 1
    fi
}

# Issue #596: monitoring apps moved out of System into a Monitoring folder, and
# CoolerControl installs through the registry instead of by hand.

@test "install_coolercontrol is registered in Monitoring with the real installed launcher id" {
    local entry fn _label folder desktop found=""
    for entry in "${INSTALL_REGISTRY[@]}"; do
        IFS=':' read -r fn _label folder desktop <<< "$entry"
        [ "$fn" = "install_coolercontrol" ] || continue
        found="$folder:$desktop"
        break
    done
    [ "$found" = "Monitoring:org.coolercontrol.CoolerControl.desktop" ]
}

@test "Monitoring is a historical app-folder id, so its orphan can be reset later" {
    [[ " ${_HISTORICAL_APP_FOLDER_IDS[*]} " == *" Monitoring "* ]]
}

@test "the monitoring apps land in Monitoring and System no longer holds them" {
    mkdir -p "$HOME/.local/share/applications"
    local id
    for id in org.coolercontrol.CoolerControl.desktop io.missioncenter.MissionCenter.desktop \
              gnome-system-monitor.desktop org.gnome.PowerStats.desktop cpu-x.desktop htop.desktop \
              nvidia-settings.desktop; do
        : > "$HOME/.local/share/applications/$id"
    done

    run organize_app_folders
    [ "$status" -eq 0 ]

    local monitoring system
    monitoring=$(grep -oE "folders/Monitoring/ apps \[[^]]*\]" <<< "$output")
    system=$(grep -oE "folders/Sistema/ apps \[[^]]*\]" <<< "$output")
    for id in org.coolercontrol.CoolerControl.desktop io.missioncenter.MissionCenter.desktop \
              gnome-system-monitor.desktop org.gnome.PowerStats.desktop cpu-x.desktop htop.desktop; do
        [[ "$monitoring" == *"'$id'"* ]]
        [[ "$system" != *"'$id'"* ]]
    done
    [[ "$system" == *"'nvidia-settings.desktop'"* ]]
}

# The apt route must write the one fixed sources file (never append a second
# repo line) and must never pipe a remote script into a shell.
@test "install_coolercontrol on apt previews one keyring+sources setup and enables the daemon" {
    PACKAGE_MANAGER=apt
    INSTALL_CMD="run_or_echo sudo apt-get install -y"
    command_exists() { return 1; }
    refresh_apt_keyring() { echo "[stub] keyring $2"; }

    run install_coolercontrol
    [ "$status" -eq 0 ]

    [[ "$output" == *"[stub] keyring /usr/share/keyrings/coolercontrol-archive-keyring.gpg"* ]]
    [[ "$output" == *"[dry-run] sudo tee /etc/apt/sources.list.d/coolercontrol.sources"* ]]
    [[ "$output" == *"[dry-run] sudo apt-get install -y coolercontrol"* ]]
    [[ "$output" == *"[dry-run] sudo systemctl enable --now coolercontrold"* ]]

    local body
    body="$(declare -f install_coolercontrol _coolercontrol_install_apt)"
    [[ "$body" != *"| sudo sh"* && "$body" != *"| sh"* && "$body" != *"| bash"* ]]
}

@test "install_coolercontrol when already installed adds no source" {
    PACKAGE_MANAGER=apt
    command_exists() { return 0; }

    run install_coolercontrol
    [ "$status" -eq 0 ]

    [[ "$output" == *"already installed"* ]]
    [[ "$output" != *"sources.list.d"* ]]
    [[ "$output" == *"[dry-run] sudo systemctl enable --now coolercontrold"* ]]
}

# Issue #597: GSmartControl and nvtop fill the disk-health and per-process-GPU
# gaps. Both ids come from the packages' own file lists (usr/share/applications).
@test "install_gsmartcontrol and install_nvtop are registered in Monitoring with their shipped launcher ids" {
    local entry fn _label folder desktop found=""
    for entry in "${INSTALL_REGISTRY[@]}"; do
        IFS=':' read -r fn _label folder desktop <<< "$entry"
        case "$fn" in
            install_gsmartcontrol|install_nvtop) found+="$fn=$folder:$desktop " ;;
        esac
    done
    [ "$found" = "install_gsmartcontrol=Monitoring:gsmartcontrol.desktop install_nvtop=Monitoring:nvtop.desktop " ]
}

@test "install_gsmartcontrol and install_nvtop install their package once and skip when present" {
    # shellcheck source=../distro_config/install_lib/_common.sh
    source "$REPO_ROOT/distro_config/install_lib/_common.sh"
    local fn
    for fn in gsmartcontrol nvtop; do
        PACKAGE_MANAGER=apt
        INSTALL_CMD="run_or_echo sudo apt-get install -y"
        command_exists() { return 1; }
        run "install_$fn"
        [ "$status" -eq 0 ]
        [[ "$output" == *"[dry-run] sudo apt-get install -y $fn"* ]]

        command_exists() { return 0; }
        run "install_$fn"
        [ "$status" -eq 0 ]
        [[ "$output" == *"already installed"* ]]
        [[ "$output" != *"apt-get install"* ]]
    done
}
