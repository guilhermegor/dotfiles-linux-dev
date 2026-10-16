#!/bin/bash
#
# drivers/battery_threshold.sh
#
# Caps laptop battery charging (default 75% start / 80% stop) so a machine that
# lives on the charger does not sit at 100%, and re-applies it on every boot.
# Safe on any PC: a desktop (no battery) or a battery without a charge control
# is reported and skipped, never an error.
#
# Dispatches on the CAPABILITY the kernel exposes, not on the vendor name: the
# standard power_supply attributes charge_control_{start,end}_threshold are the
# same file for ThinkPad, ASUS, Huawei, Framework, LG, Samsung and recent Dell
# drivers. IdeaPad is the one exception — ideapad_acpi only offers an on/off
# conservation_mode with a firmware-fixed cap.
#
# TLP is deliberately not used: on Ubuntu/GNOME it conflicts with (and apt
# removes) power-profiles-daemon, which backs the power-mode menu.
#
# Usage:
#   bash drivers/battery_threshold.sh           # apply now + persist for boot
#   bash drivers/battery_threshold.sh --full    # lift the cap (charge to 100%)
#   battery-charge-threshold --apply            # what the boot unit runs
#
# Thresholds come from, first match wins: the environment, then the repo's
# .env (BATTERY_START_THRESHOLD / BATTERY_END_THRESHOLD, see .env.example),
# then 75/80. Re-running after editing .env re-persists them; the boot unit
# reads /etc/default/battery-charge-threshold, never the repo, so a moved or
# deleted checkout does not change what boot applies.
# Overridable for tests: BATTERY_ENV_FILE, POWER_SUPPLY_DIR, IDEAPAD_DIR.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh" 2>/dev/null \
    || print_status() { printf '[%s] %s\n' "$1" "$2"; }  # installed copy runs outside the repo

DEFAULT_END_THRESHOLD=80
# With no start configured, charging resumes this many points below the stop,
# so setting only BATTERY_END_THRESHOLD can never produce start >= stop.
START_GAP=5
ENV_FILE="${BATTERY_ENV_FILE:-$REPO_ROOT/.env}"
POWER_SUPPLY_DIR="${POWER_SUPPLY_DIR:-/sys/class/power_supply}"
IDEAPAD_DIR="${IDEAPAD_DIR:-/sys/bus/platform/drivers/ideapad_acpi}"

INSTALLED_BIN="/usr/local/sbin/battery-charge-threshold"
CONFIG_FILE="/etc/default/battery-charge-threshold"
UNIT_NAME="battery-charge-threshold.service"
UNIT_FILE="/etc/systemd/system/$UNIT_NAME"

read_env_value() {
    [ -f "$ENV_FILE" ] || return 0
    grep -E "^$1=" "$ENV_FILE" | tail -n 1 | cut -d= -f2- | tr -d "\"' \r"
}

resolve_threshold() {
    local key="$1" fallback="$2" value
    value="${!key:-}"
    [ -n "$value" ] || value="$(read_env_value "$key")"
    echo "${value:-$fallback}"
}

# Leading zeros are accepted but normalised: bash arithmetic reads "080" as
# octal (an error) and "060" as 48, which would silently shift the cap.
to_decimal() {
    if [[ "$1" =~ ^[0-9]+$ ]]; then echo "$((10#$1))"; else echo "$1"; fi
}

END_THRESHOLD="$(to_decimal "$(resolve_threshold BATTERY_END_THRESHOLD "$DEFAULT_END_THRESHOLD")")"
START_THRESHOLD="$(to_decimal "$(resolve_threshold BATTERY_START_THRESHOLD "")")"
if [ -z "$START_THRESHOLD" ] && [[ "$END_THRESHOLD" =~ ^[0-9]+$ ]]; then
    START_THRESHOLD=$(( END_THRESHOLD > START_GAP ? END_THRESHOLD - START_GAP : 0 ))
fi

# configure_battery's outcomes. A skip (desktop, no charge control) is normal on
# most PCs; a failure means a supported control rejected the write.
APPLIED=0
SKIPPED=1
FAILED=2

# These values are written straight into the battery controller, so a typo in
# .env must stop here rather than reach sysfs.
validate_thresholds() {
    if ! [[ "$START_THRESHOLD" =~ ^[0-9]+$ && "$END_THRESHOLD" =~ ^[0-9]+$ ]]; then
        print_status "error" "Thresholds must be whole numbers (start='$START_THRESHOLD', stop='$END_THRESHOLD')"
        return 1
    fi
    if [ "$END_THRESHOLD" -lt 1 ] || [ "$END_THRESHOLD" -gt 100 ] || [ "$START_THRESHOLD" -ge "$END_THRESHOLD" ]; then
        print_status "error" "Need 0 <= start < stop <= 100 (got start=$START_THRESHOLD, stop=$END_THRESHOLD)"
        return 1
    fi
}

write_sysfs() {
    local value="$1" file="$2"
    if [ -w "$file" ]; then
        printf '%s\n' "$value" > "$file"
    else
        printf '%s\n' "$value" | sudo tee "$file" > /dev/null
    fi
}

# The read-back, not the write's exit code, is the proof: some drivers accept a
# write and clamp or ignore the value.
reads_back() {
    local file="$1" expected="$2"
    [ "$(cat "$file" 2>/dev/null)" = "$expected" ]
}

# Wireless mice/keyboards (hidpp_battery_*) are also type Battery, but the
# kernel marks them scope=Device — only the machine's own batteries qualify.
list_batteries() {
    local supply
    for supply in "$POWER_SUPPLY_DIR"/*; do
        [ "$(cat "$supply/type" 2>/dev/null)" = "Battery" ] || continue
        [ "$(cat "$supply/scope" 2>/dev/null)" = "Device" ] && continue
        echo "$supply"
    done
    return 0
}

# Some drivers reject a start >= the current end (or an end <= the current
# start), so end is written on both sides of start: whichever order the old
# values required, the final pair lands. Intermediate write errors are expected
# for that reason; only the final read-back decides success.
apply_thresholds() {
    local battery="$1" name
    local end_file="$battery/charge_control_end_threshold"
    local start_file="$battery/charge_control_start_threshold"
    name="$(basename "$battery")"

    write_sysfs "$END_THRESHOLD" "$end_file" 2>/dev/null || true
    [ -e "$start_file" ] && { write_sysfs "$START_THRESHOLD" "$start_file" 2>/dev/null || true; }
    write_sysfs "$END_THRESHOLD" "$end_file" 2>/dev/null || true

    if ! reads_back "$end_file" "$END_THRESHOLD"; then
        print_status "error" "$name: stop threshold rejected (reads $(cat "$end_file" 2>/dev/null))"
        return 1
    fi
    if [ -e "$start_file" ] && ! reads_back "$start_file" "$START_THRESHOLD"; then
        print_status "error" "$name: start threshold rejected (reads $(cat "$start_file" 2>/dev/null))"
        return 1
    fi
    print_status "success" "$name: charging stops at ${END_THRESHOLD}%"
}

# conservation_mode is on/off only: any cap below 100% turns it on.
# Returns SKIPPED when this is not an IdeaPad.
apply_ideapad_conservation() {
    local mode_file mode=1
    [ "$END_THRESHOLD" -eq 100 ] && mode=0
    for mode_file in "$IDEAPAD_DIR"/*/conservation_mode; do
        [ -e "$mode_file" ] || continue
        write_sysfs "$mode" "$mode_file" 2>/dev/null || true
        if ! reads_back "$mode_file" "$mode"; then
            print_status "error" "IdeaPad conservation_mode rejected (reads $(cat "$mode_file" 2>/dev/null))"
            return "$FAILED"
        fi
        print_status "success" "IdeaPad conservation mode $([ "$mode" -eq 1 ] && echo "on (cap fixed by firmware, ~60-80%)" || echo off)"
        return "$APPLIED"
    done
    return "$SKIPPED"
}

# Returns APPLIED, SKIPPED (nothing here can be limited) or FAILED (a supported
# control rejected the values — never persisted as if it had worked).
configure_battery() {
    local batteries battery found=0 failed=0
    mapfile -t batteries < <(list_batteries)
    if [ "${#batteries[@]}" -eq 0 ]; then
        print_status "info" "No battery found (desktop?) — nothing to limit"
        return "$SKIPPED"
    fi

    for battery in "${batteries[@]}"; do
        [ -e "$battery/charge_control_end_threshold" ] || continue
        found=1
        apply_thresholds "$battery" || failed=1
    done
    if [ "$found" -eq 1 ]; then
        [ "$failed" -eq 1 ] && return "$FAILED"
        return "$APPLIED"
    fi

    local rc=0
    apply_ideapad_conservation || rc=$?
    [ "$rc" -ne "$SKIPPED" ] && return "$rc"

    print_status "warning" "Battery found, but its driver exposes no charge limit — check the BIOS/UEFI setup for a 'battery care' option"
    return "$SKIPPED"
}

# Root-owned, so the mouse.sh backup_file pattern runs under sudo here.
backup_file() {
    local file="$1" backup
    [ -f "$file" ] || return 0
    backup="${file}.bak-$(date +%Y%m%d%H%M%S)"
    if sudo cp -p "$file" "$backup"; then
        print_status "success" "Backed up ${file} to ${backup}"
    else
        print_status "error" "Failed to back up ${file}"
        return 1
    fi
}

persist_for_boot() {
    local self
    self="$(readlink -f "${BASH_SOURCE[0]}")"
    sudo install -m 0755 "$self" "$INSTALLED_BIN"
    backup_file "$CONFIG_FILE"
    backup_file "$UNIT_FILE"
    printf 'BATTERY_START_THRESHOLD=%s\nBATTERY_END_THRESHOLD=%s\n' "$START_THRESHOLD" "$END_THRESHOLD" \
        | sudo tee "$CONFIG_FILE" > /dev/null
    sudo tee "$UNIT_FILE" > /dev/null <<EOF
[Unit]
Description=Battery charge thresholds from ${CONFIG_FILE} (dotfiles-dev drivers/battery_threshold.sh)
After=multi-user.target

[Service]
Type=oneshot
EnvironmentFile=-${CONFIG_FILE}
ExecStart=${INSTALLED_BIN} --apply

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable "$UNIT_NAME" > /dev/null 2>&1
}

# Enabled is not enough: run the installed unit once, the way boot will, and
# require systemd to record a successful run.
verify_installation() {
    if ! systemctl is-enabled --quiet "$UNIT_NAME"; then
        print_status "error" "Boot unit $UNIT_NAME did not enable"
        return 1
    fi
    sudo systemctl start "$UNIT_NAME" || true
    if [ "$(systemctl show -p Result --value "$UNIT_NAME")" != "success" ]; then
        print_status "error" "Boot unit $UNIT_NAME failed its test run — see: journalctl -u $UNIT_NAME"
        return 1
    fi
    print_status "success" "Boot unit $UNIT_NAME enabled and test-run OK — limits re-applied on every boot"
}

# No install_dependencies step: everything used (coreutils, sudo, systemd) is
# part of the base system this repo targets.
main() {
    local rc=0
    case "${1:-}" in
        --apply)
            validate_thresholds || return 1
            configure_battery || rc=$?
            [ "$rc" -eq "$FAILED" ] && return 1
            return 0
            ;;
        --full) START_THRESHOLD=0 END_THRESHOLD=100 ;;
        "") ;;
        *) print_status "error" "Unknown option: $1 (expected --full or --apply)"; return 1 ;;
    esac

    validate_thresholds
    print_status "section" "BATTERY CHARGE THRESHOLD"
    print_status "config" "start ${START_THRESHOLD}% / stop ${END_THRESHOLD}%"
    configure_battery || rc=$?
    [ "$rc" -eq "$SKIPPED" ] && return 0
    [ "$rc" -eq "$FAILED" ] && { print_status "error" "Charge limit not applied — nothing persisted"; return 1; }
    persist_for_boot
    verify_installation
}

main "$@"
