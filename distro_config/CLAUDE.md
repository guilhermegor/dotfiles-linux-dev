# distro_config/CLAUDE.md

## Purpose

Distribution-level setup: package installation, coding environment, shell environment, and GNOME keybindings.

## Scripts

| File | What it does |
|------|-------------|
| `install_programs.sh` | Orchestrator — desktop apps (browsers, productivity, media, sharing, VM, system utils) |
| `install_lib/` | Category libs sourced by `install_programs.sh` |
| `install_coding.sh` | Orchestrator — coding env (languages, editors, databases, containers, VCS, AI CLIs) |
| `install_coding_lib/` | Category libs sourced by `install_coding.sh` |
| `setup_env.sh` | Shell environment (PATH, env vars, dotfiles symlinks) |
| `ubuntu_workspace.sh` | GNOME workspace, dock, theme, app-folder organisation |
| `set_custom_shortcuts.sh` | GNOME custom keybindings via gsettings |
| `irpf_download.sh` | Download the Brazilian IRPF tax program |

## Architecture

Both orchestrators follow the same registry-driven pattern:

```
install_programs.sh                 install_coding.sh
├── sources install_lib/_common.sh  ├── sources install_coding_lib/_common.sh (shim)
├── globs install_lib/[!_]*.sh      ├── globs install_coding_lib/[!_]*.sh
├── splices framework steps         ├── splices bootstrappers
├── validates registry              ├── validates registry
└── runs menu (full / custom)       └── runs menu (full / custom)
```

`install_lib/_common.sh` is the **single source of truth** for shared utilities (`print_status`, `detect_distro`, `install_package`, `setup_flatpak`, `INSTALL_REGISTRY` infrastructure). `install_coding_lib/_common.sh` is a thin shim that sources its sibling.

Each category file (e.g. `install_lib/browsers.sh`, `install_coding_lib/editors.sh`) contains:
1. Install functions for one domain.
2. A single `INSTALL_REGISTRY+=( ... )` block at the bottom declaring its entries.

### INSTALL_REGISTRY entry format

```bash
"func:label:gnome_folder:desktop_file"
```

| Field | Required | Meaning |
|-------|----------|---------|
| `func` | yes | The `install_<name>` function defined above in the same file |
| `label` | yes | Human-readable menu label |
| `gnome_folder` | no | One of `Sistema`, `Seguranca`, `Utilitarios`, `Monitoring`, `Media`, `Sharing`, `IRPF`, `Code`, `Data`, `Infra`, `Design`, `Planning`, `Reading`, `Ereader`, `Office`, `Social`, or empty (no folder) |
| `desktop_file` | no | Explicit `.desktop` filename. If empty, derived as `${func#install_}.desktop` |

`ubuntu_workspace.sh` reads the registry at startup and merges the `desktop_file` of every entry whose `gnome_folder` matches into the corresponding folder array, so install registrations are the single source of truth for app placement.

### Failure policy

Both orchestrators use `run_install` from `_common.sh`, which runs each `install_*` in a subshell. A failure inside one install does not abort the run — the failure is collected in `INSTALL_FAILURES` and reported at the end via `report_failures`.

### Install success = packages landed, not exit code

`install_package` (and `install_packages_verified` for multi-package calls) runs `$INSTALL_CMD`,
and on a non-zero exit checks the package database (`dpkg-query -W -f='${Status}'` on apt,
`rpm -q` on dnf/yum/zypper, `pacman -Q`). All requested packages present = success plus a warning
about the leftover broken state; any missing = the original failure. A pre-existing broken package
(e.g. a kernel-module postinst) otherwise fails every install that runs after it (#632). Use these
instead of a bare `$INSTALL_CMD` for package-manager installs; `tests/install_package_verify.bats`.

### Registry validation

Before any install runs, `validate_registry` (from `_common.sh`) checks that every function named in `INSTALL_REGISTRY` is actually defined. A typo or a missing source file fails loudly at startup, not mid-run.

### Dry-run preview

Set `DRY_RUN=1` to preview what an install would do without mutating system state:

```bash
DRY_RUN=1 bash distro_config/install_programs.sh
DRY_RUN=1 bash distro_config/install_coding.sh
```

Coverage:
- `$INSTALL_CMD`, `$UPDATE_CMD`, `$UPGRADE_CMD` (every call site goes through these)
- Direct `sudo dpkg -i`, `sudo apt-get install`, `sudo apt install`, `flatpak install -y`, `sudo snap install`, `brew install`, `npm install -g`, `sudo systemctl enable/start/stop/disable`, `sudo tee`, `sudo add-apt-repository`, `yay -S` calls inside install_lib/* and install_coding_lib/*

What is NOT wrapped: arbitrary `curl`/`wget` downloads, `mkdir -p`, `cd`, file moves outside system paths. These are either idempotent or low-risk to actually execute, but they will still run during a dry-run. The goal is "no real installs and no service mutations," not "zero side effects."

When adding a new install function, wrap any genuinely destructive command in `run_or_echo`:

```bash
run_or_echo sudo dpkg -i "$deb_file"
echo "deb ... main" | run_or_echo sudo tee /etc/apt/sources.list.d/repo.list
```

## Conventions

- **`print_status <level> <msg>`** with the standard color vars defined in `install_lib/_common.sh`.
- Distro detection via `/etc/os-release` (`$ID`); branch on `apt-get`, `dnf`, `pacman`, `zypper`.
- Use `command_exists <tool>` to guard installs; never assume a package is absent.
- Source-only files must guard against direct execution:
  ```bash
  if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
      echo "<file> is meant to be sourced, not executed." >&2
      exit 1
  fi
  ```

## Checklist for Every New Install Function

When asked to install any program, complete **all three steps** before reporting the task as done:

1. **Write `install_<name>()`** in the right category file under `install_lib/` (for desktop apps) or `install_coding_lib/` (for coding tools). Guard with `command_exists`, use `install_package` for multi-distro names.
2. **Register it** — add `"install_<name>:Display Name:<gnome_folder>:<desktop_file>"` to the `INSTALL_REGISTRY+=( ... )` block at the bottom of the same file. Pick the right folder per the table below; leave both folder and desktop fields empty for CLI-only tools.
3. **Confirm placement** — if the app has a GUI, confirm with the user which GNOME folder it should land in (or whether it belongs on the dock instead). For dock pinning, edit `favorite-apps` in `ubuntu_workspace.sh`'s `configure_dock`. For CLI-only tools, leave the registry's `gnome_folder` field empty.

Never declare the task complete if any of these three steps is missing.

### `install_rtk` never patches `settings.json`

`install_rtk` runs `rtk init -g --no-patch </dev/null`: the PreToolUse hook is owned by
`ai_clients/claude/settings.json` (wired through `rtk_worktree_passthrough.sh`), and rtk's
`--auto-patch` would append a direct hook that revives the #417 worktree deadlock. stdin is
closed because rtk asks a telemetry question on the terminal even when its output is
redirected to the log (#633). The re-run guard is `~/.claude/RTK.md`, rtk's own artifact.

### Ventoy launchers (`ventoy/`)

`install_ventoy` (also on the already-installed path) calls `install_ventoy_launchers`, which copies
`ventoy/ventoy-launcher.sh` to `/usr/local/bin/ventoy-web` and `ventoy-plugson` (one script, behaviour
by invoked name) and writes `ventoy-web.desktop` / `ventoy-plugson.desktop`, listed in the `Infra`
folder beside `ventoy.desktop` in `ubuntu_workspace.sh`. Ventoy lives in the root-owned `/opt/ventoy` (populated only from a freshly downloaded release whose tarball is checked against the release's `sha256.txt` before `sudo tar -x`; a missing checksum asset or a mismatch refuses. An old user-writable `~/.local/share/ventoy` is never copied in and never counts as installed: it is reported as removable and a fresh verified install is done). The scripts run under sudo, so the wrappers hardcode that dir (override only under `DRY_RUN=1` via `VENTOY_TEST_DIR`) and refuse unless script and dir are root-owned and not group/world-writable. Each wrapper `cd`s into it
(Ventoy's scripts need cwd = their dir), runs `sudo bash ./Ventoy{Web,Plugson}.sh`, and opens the browser
(`:24680` installer, `:24681` Plugson). `ventoy-plugson` with no arg resolves the disk behind the single
partition labelled `Ventoy` (`lsblk`) and refuses on zero or several. `ventoy-plugson --install-launcher
[mountpoint]` copies `ventoy-pendrive-launcher.sh` onto the stick as `ventoy-plugson.sh`; it finds its own
disk via `findmnt` and calls the host's `ventoy-plugson`, or prints the install command when missing.
The stick copy is a convenience for your own sticks: it sits on a FAT partition anyone with the stick can edit, so whoever modifies it can run code as the user; it calls `/usr/local/bin/ventoy-plugson` by absolute path only. `DRY_RUN=1` prints the command lines; `tests/ventoy_launchers.bats`.

### KillDisk Freeware is a manual install (#703)

Not automated on purpose. The vendor serves a Linux build at a stable URL
(`https://download.lsoft.net/KillDiskLinuxFree.run.tar.gz`, a self-extracting `.run` installer that
runs as root), but publishes no checksum or signature for it (no `.sha256`/`.md5`/`.asc`/`.sig`
sibling, none on the vendor pages), so it cannot be verified before running as root. Install by
hand from https://www.killdisk.com/killdisk-freeware.htm if needed; revisit if the vendor
publishes a hash. Its folder would be `Infra`.

## Where to put a new install function

| New install is… | Goes in |
|---|---|
| Web browser | `install_lib/browsers.sh` |
| Video/audio/CD/DVD tool | `install_lib/media.sh` |
| Calendar / tasks / email / news / collaboration | `install_lib/productivity.sh` |
| Screenshot, launcher, GNOME extension, snap/flatpak rollup | `install_lib/system_utils.sh` |
| File sharing, remote desktop, sync, antivirus | `install_lib/sharing.sh` |
| VM, USB imaging, virtualisation | `install_lib/vm.sh` |
| Container runtime | `install_coding_lib/containers.sh` |
| Editor or terminal emulator | `install_coding_lib/editors.sh` |
| Version control / GitHub workflow tool | `install_coding_lib/vcs.sh` |
| Language runtime, version manager, framework CLI | `install_coding_lib/languages.sh` |
| Database engine / client | `install_coding_lib/databases.sh` |
| AI coding CLI, local AI runtime | `install_coding_lib/ai_clients.sh` |
| Foundation (Homebrew, asdf, pyenv, core deps) | `install_coding_lib/bootstrappers.sh` |

If none fit, add a new category file — the orchestrator globs `[!_]*.sh` so it gets picked up automatically. Avoid filenames starting with `_` (reserved).

## App Installation Preference Order

When adding a new application, choose the installation method using this priority:

1. **Official `.deb` from vendor** — prefer when the software vendor provides an official `.deb` (e.g. download page or GitHub releases). Follow the `install_fastfetch` pattern: `wget`/`curl` to a `mktemp` dir, `apt-get install -y <file>.deb`, then clean up. Always guard with `command_exists` before downloading.
2. **Flatpak** — use when no official `.deb` exists; sandboxed, distro-agnostic, available on all supported distros.
3. **Homebrew** — use when the app has an official Homebrew formula and no `.deb` or Flatpak; works everywhere but adds PATH complexity.
4. **Snap** — acceptable fallback when `.deb` and Flatpak are unavailable; note that snap confinement can cause issues on some systems.
5. **PWA (Chrome `--app=<url>`)** — use for Google/web-first apps with no native Linux package (e.g. Google Calendar, Google Tasks). Requires Chrome; creates a `.desktop` entry under `~/.local/share/applications/`.
6. **AppImage** — last resort for portable binaries with no managed package; download to `$DOWNLOADS_DIR`, `chmod +x`, and symlink into `/usr/local/bin/`.

Each install function must guard against re-installation with `command_exists` or an equivalent check before attempting any download or package operation.

## GNOME App Placement (`ubuntu_workspace.sh`)

App-folder placement is now driven by the `gnome_folder` field in `INSTALL_REGISTRY`. `ubuntu_workspace.sh` sources both `install_lib/*.sh` and `install_coding_lib/*.sh` at startup to populate `INSTALL_REGISTRY`, then `_merge_registry_into_folder` (defined inside `organize_app_folders`) adds each registry-contributed `.desktop` filename to the matching folder array.

Folders are grouped by **artifact produced**, not by tool category. Existing folders and their purpose:

| dconf key | Display name | Typical contents |
|-----------|--------------|-----------------|
| `Sistema` | System | System tools, settings, updates, drivers, firmware, file manager |
| `Monitoring` | Monitoring | Hardware/load dashboards (CoolerControl, GSmartControl, nvtop, Mission Center, GNOME System Monitor, Power Statistics, CPU-X, htop). Vitals is a top-bar extension with no launcher, so it is not a member |
| `Seguranca` | Security | Security, antivirus, backup |
| `Utilitarios` | Utilities | General utilities (screenshots, weather, Flameshot, Rofi…) |
| `Media` | Media | Video players, audio players, media tools |
| `Sharing` | Sharing | File-sharing and remote-desktop apps |
| `IRPF` | IRPF | Brazilian tax program |
| `Code` | Code | IDEs, editors, terminals (Cursor, vim, nvim, Notepadqq, Warp, Devtoolbox) |
| `Data` | Data | DB clients (pgAdmin4, DBeaver) |
| `Infra` | Infra | VMs, containers, USB imaging, disk tools (Docker Desktop, VM Manager, Ventoy, Balena Etcher, GNOME Disks, Baobab) |
| `Design` | Design | Image/graphic design tools (Figma, GIMP, Pinta) |
| `Planning` | Planning | Project/task planning (Linear, Google Calendar, Google Tasks, Notion Calendar, Miro, Google Keep) |
| `Reading` | Reading | Things to read later (Instapaper, NewsFlash, Valor Digital) |
| `Ereader` | Ereader | E-book readers |
| `Office` | Office | LibreOffice suite |
| `Social` | Social | Messaging and email (Slack, Telegram, Thunderbird) |

For **pre-installed system apps** (e.g. `gnome-control-center.desktop`, `gnome-system-monitor.desktop`) that no install function manages, append them to the static `<id>_app_names` arrays inside `organize_app_folders()`. The registry merge runs alongside the static arrays — both contribute to the same folder.

For **dock pinning**: add the `.desktop` filename to the `favorite-apps` gsettings key in `configure_dock`. The registry does not currently model dock placement. VS Code is dock-pinned, not in the `Code` folder: its registry entry keeps the desktop id but leaves the folder empty (#638).

⚠️ **The dock is declared AND merged — removing a pin needs the explicit unpin list, not just a deleted block.** `configure_dock` builds `favorites` from a fixed set of declared blocks, then `_merge_dock_favorites` re-appends every app already in the live `favorite-apps` value that isn't declared — deliberate, so a hand-pinned app survives a `gsettings set` that replaces the key wholesale (#103). This means **deleting an app's declared block does not unpin it**: the app is simply no longer declared, and the merge re-adds it from the live dock on every run, forever. To actually remove a pin, add its `.desktop` id (plus fallback ids, same pattern as everywhere else in this file) to `DOCK_UNPINNED`, the array `_merge_dock_favorites` is passed as its third argument and skips when merging (#392). Read `DOCK_UNPINNED` as a *declaration of intent*, not a permanent blocklist: if the owner pins one of those apps by hand again, this list will silently unpin it again on the next run — that is the surprising, deliberate consequence of stating a removal here instead of just deleting a pin once by hand.

For **CLI-only tools / background services**: leave `gnome_folder` empty in the registry entry. No placement change needed — the empty field is the documentation.

The `.desktop` filename for a PWA is the value used in the install function (e.g. `google-tasks.desktop`). For Flatpak apps it is the app ID with `.desktop` suffix (e.g. `com.slack.Slack.desktop`).

## GNOME Custom Keybindings (`set_custom_shortcuts.sh`)

Bindings are managed through three layers:

1. **`set_keybindings_array`** — declares the indexed list of active custom binding paths in
   dconf. The array size must match the number of `set_individual_keybinding` calls exactly.
2. **`set_individual_keybinding <index> <name> <command> <binding>`** — writes `name`,
   `command`, and `binding` for `custom<index>`.
3. **`verify_keybindings`** — checks for conflicts before applying.

`clear_managed_bindings` runs before any assignment and blanks the `binding` of every slot
`custom0..custom<MANAGED_SLOT_COUNT-1>`. gsd-media-keys refuses a grab while another slot still
holds the accelerator and never retries, and re-writing an identical value emits no change, so
without the blank pass a renumber leaves shortcuts dead (#653). Slots outside the range are left
alone.

### Adding a new shortcut

0. Bump `MANAGED_SLOT_COUNT` at the top of the script.

1. Add the binding string (e.g. `"<Super><Shift>b"`) to the `bindings` array in `set_all_keybindings`.
2. Append `'/org/.../custom<N>/'` to `set_keybindings_array` (increment `N`).
3. Call `set_individual_keybinding <N> "<label>" "<command>" "<binding>"`.
4. If the command needs a helper script, create it in `$HOME/.local/bin/` and call it from
   a `create_<name>_script` function, following the `create_copy_path_script` pattern.
5. Update the summary block at the bottom of `set_all_keybindings`.

### Removing a shortcut

Renumber the later slots down so the array stays gap-free, and `dconf reset -f` the old
highest `custom<N>/` path in `set_all_keybindings` — shrinking the array only orphans the
path, which stays bound on machines that already ran the script.
`tests/custom_shortcuts_slots.bats` enforces array/call parity.

Binding syntax (GDK format): `<Super>`, `<Ctrl>`, `<Shift>`, `<Alt>` + key.

### AI-state shortcuts

Super+Shift+B runs `~/.local/bin/ai-state-sync push` and Super+Alt+B runs `ai-state-sync pull`
(installed by the `state_sync` step, #655; #657). The CLI notifies via `notify-send` when it has no
TTY, including on a pull conflict, which is never auto-resolved. The old Super+B (external SSD
backup) is retired.
