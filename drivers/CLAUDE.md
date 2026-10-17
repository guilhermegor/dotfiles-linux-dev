# drivers/CLAUDE.md

## Purpose

Per-device hardware driver and configuration scripts.

## Scripts

| File | What it does |
|------|-------------|
| `mouse.sh` | MX Master — natural scrolling, xbindkeys workspace buttons |
| `setup_keyboard.sh` | GNOME input sources: merges English (US, first; an existing `us+...` variant is kept) + Portuguese (Brazil, ABNT2 = xkb `br`) into the current list, ensures `<Super>space` in `switch-input-source`, reads each setting back, then cedilla fix (sudo for `/etc/environment`) |
| `bluetooth_adapter.sh` | Bluetooth adapter setup |
| `tplink_wifi_adapter.sh` | TP-Link USB Wi-Fi adapter driver install (skips without the adapter; not in `setup_all_drivers`) |
| `battery_threshold.sh` | Laptop charge cap (`.env` `BATTERY_*_THRESHOLD`, default 75/80) via `charge_control_*_threshold` / IdeaPad `conservation_mode` + boot unit; `--full` lifts it; no-op on desktops |
| `yubikey.sh` | YubiKey — ykman, pcscd, Yubico Authenticator, GPG/SSH, PAM (install-only) |

`setup_all_drivers` may only bundle scripts that are safe on **any** PC (they detect their
hardware and no-op without it). A script that builds a kernel module or reboots for one specific
device gets its own `make` target and stays out of the bundle — `setup_wifi` is the example.

`make run` deliberately does not run any driver script (it only prints `make setup_all_drivers` as a next
step): `setup_keyboard` needs `sudo` for the cedilla edit of `/etc/environment`, and drivers stay an
explicit step (#778).

## Conventions

- Each script targets **one device** — keep them small and focused.
- **`print_status <level> <msg>`** with the standard color vars.
- Guard every `command -v` before installing dependencies; use `sudo apt-get install -y`.
- Backup config files before overwriting: `backup_file()` pattern from `mouse.sh`.
- Scripts that modify system services must verify the service started:
  `pgrep <service>` or `systemctl is-active <service>`.
- Autostart entries go in `$HOME/.config/autostart/<name>.desktop`.

## Adding a new device script

1. Create `drivers/<device>.sh`.
2. Source the standard color vars at the top.
3. Implement `install_dependencies`, `configure_<device>`, `verify_installation`, and `main`.
4. `chmod +x` is handled by `make permissions`.
