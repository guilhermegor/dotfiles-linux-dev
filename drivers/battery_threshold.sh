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
#   bash drivers/battery_threshold.sh           # apply now + install boot unit
#   battery-charge-threshold --apply            # what the boot unit runs
# Overridable: BATTERY_START_THRESHOLD, BATTERY_END_THRESHOLD,
#              POWER_SUPPLY_DIR, IDEAPAD_DIR (tests point these at a fake sysfs).

set -euo pipefail

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh" 2>/dev/null \
    || print_status() { printf '[%s] %s\n' "$1" "$2"; }  # installed copy runs outside the repo

START_THRESHOLD="${BATTERY_START_THRESHOLD:-75}"
END_THRESHOLD="${BATTERY_END_THRESHOLD:-80}"
POWER_SUPPLY_DIR="${POWER_SUPPLY_DIR:-/sys/class/power_supply}"
IDEAPAD_DIR="${IDEAPAD_DIR:-/sys/bus/platform/drivers/ideapad_acpi}"

INSTALLED_BIN="/usr/local/sbin/battery-charge-threshold"
UNIT_NAME="battery-charge-threshold.service"
UNIT_FILE="/etc/systemd/system/$UNIT_NAME"

write_sysfs() {
    local value="$1" file="$2"
    if [ -w "$file" ]; then
        printf '%s\n' "$value" > "$file"
    else
        printf '%s\n' "$value" | sudo tee "$file" > /dev/null
    fi
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
# values required, the final pair lands.
apply_thresholds() {
    local battery="$1"
    local end_file="$battery/charge_control_end_threshold"
    local start_file="$battery/charge_control_start_threshold"

    write_sysfs "$END_THRESHOLD" "$end_file" 2>/dev/null || true
    [ -e "$start_file" ] && { write_sysfs "$START_THRESHOLD" "$start_file" 2>/dev/null || true; }
    write_sysfs "$END_THRESHOLD" "$end_file"

    if [ "$(cat "$end_file")" != "$END_THRESHOLD" ]; then
        print_status "error" "$(basename "$battery"): stop threshold did not stick (reads $(cat "$end_file"))"
        return 1
    fi
    print_status "success" "$(basename "$battery"): charging stops at ${END_THRESHOLD}%"
}

apply_ideapad_conservation() {
    local mode_file
    for mode_file in "$IDEAPAD_DIR"/*/conservation_mode; do
        [ -e "$mode_file" ] || continue
        write_sysfs 1 "$mode_file"
        print_status "success" "IdeaPad conservation mode on (cap is fixed by firmware, ~60-80%)"
        return 0
    done
    return 1
}

# Returns 0 when a limit was applied, 1 when no battery can be limited here.
apply_all() {
    local batteries applied=0 battery
    mapfile -t batteries < <(list_batteries)
    if [ "${#batteries[@]}" -eq 0 ]; then
        print_status "info" "No battery found (desktop?) — nothing to limit"
        return 1
    fi

    for battery in "${batteries[@]}"; do
        [ -e "$battery/charge_control_end_threshold" ] || continue
        apply_thresholds "$battery"
        applied=1
    done
    [ "$applied" -eq 1 ] && return 0

    apply_ideapad_conservation && return 0

    print_status "warning" "Battery found, but its driver exposes no charge limit — check the BIOS/UEFI setup for a 'battery care' option"
    return 1
}

install_boot_unit() {
    local self
    self="$(readlink -f "${BASH_SOURCE[0]}")"
    sudo install -m 0755 "$self" "$INSTALLED_BIN"
    sudo tee "$UNIT_FILE" > /dev/null <<EOF
[Unit]
Description=Cap battery charging at ${END_THRESHOLD}% (dotfiles-dev drivers/battery_threshold.sh)
After=multi-user.target

[Service]
Type=oneshot
Environment=BATTERY_START_THRESHOLD=${START_THRESHOLD} BATTERY_END_THRESHOLD=${END_THRESHOLD}
ExecStart=${INSTALLED_BIN} --apply

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable "$UNIT_NAME" > /dev/null 2>&1
    if systemctl is-enabled --quiet "$UNIT_NAME"; then
        print_status "success" "Boot unit $UNIT_NAME enabled — limits re-applied on every boot"
    else
        print_status "error" "Boot unit $UNIT_NAME did not enable"
        return 1
    fi
}

main() {
    if [ "${1:-}" = "--apply" ]; then
        apply_all || true
        return 0
    fi

    print_status "section" "BATTERY CHARGE THRESHOLD"
    print_status "config" "start ${START_THRESHOLD}% / stop ${END_THRESHOLD}%"
    apply_all || return 0
    install_boot_unit
}

main "$@"
