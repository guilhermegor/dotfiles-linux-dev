#!/usr/bin/env bats
#
# Unit tests for drivers/battery_threshold.sh --apply: which charge control it
# picks per hardware shape, against a fake sysfs (no root, no real battery).
#
# Run locally: bats tests/

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$REPO_ROOT/drivers/battery_threshold.sh"
    TMP="$(mktemp -d)"
    export POWER_SUPPLY_DIR="$TMP/power_supply"
    export IDEAPAD_DIR="$TMP/ideapad_acpi"
    mkdir -p "$POWER_SUPPLY_DIR/AC" "$IDEAPAD_DIR"
    echo Mains > "$POWER_SUPPLY_DIR/AC/type"
}

teardown() {
    rm -rf "$TMP"
}

make_battery() {
    mkdir -p "$POWER_SUPPLY_DIR/$1"
    echo Battery > "$POWER_SUPPLY_DIR/$1/type"
}

@test "thinkpad-style battery gets start and stop thresholds" {
    make_battery BAT0
    echo 100 > "$POWER_SUPPLY_DIR/BAT0/charge_control_end_threshold"
    echo 0 > "$POWER_SUPPLY_DIR/BAT0/charge_control_start_threshold"

    run bash "$SCRIPT" --apply

    [ "$status" -eq 0 ]
    [ "$(cat "$POWER_SUPPLY_DIR/BAT0/charge_control_end_threshold")" = 80 ]
    [ "$(cat "$POWER_SUPPLY_DIR/BAT0/charge_control_start_threshold")" = 75 ]
}

@test "end-only battery (asus-style) gets the stop threshold" {
    make_battery BATT
    echo 100 > "$POWER_SUPPLY_DIR/BATT/charge_control_end_threshold"

    BATTERY_END_THRESHOLD=60 run bash "$SCRIPT" --apply

    [ "$status" -eq 0 ]
    [ "$(cat "$POWER_SUPPLY_DIR/BATT/charge_control_end_threshold")" = 60 ]
    [ ! -e "$POWER_SUPPLY_DIR/BATT/charge_control_start_threshold" ]
}

@test "desktop with no battery is a no-op" {
    run bash "$SCRIPT" --apply

    [ "$status" -eq 0 ]
    [[ "$output" == *"No battery found"* ]]
}

@test "desktop with only a wireless mouse battery is a no-op" {
    make_battery hidpp_battery_0
    echo Device > "$POWER_SUPPLY_DIR/hidpp_battery_0/scope"

    run bash "$SCRIPT" --apply

    [ "$status" -eq 0 ]
    [[ "$output" == *"No battery found"* ]]
}

@test "ideapad without thresholds falls back to conservation_mode" {
    make_battery BAT0
    mkdir -p "$IDEAPAD_DIR/VPC2004:00"
    echo 0 > "$IDEAPAD_DIR/VPC2004:00/conservation_mode"

    run bash "$SCRIPT" --apply

    [ "$status" -eq 0 ]
    [ "$(cat "$IDEAPAD_DIR/VPC2004:00/conservation_mode")" = 1 ]
}

@test "battery with no charge control warns instead of failing" {
    make_battery BAT0

    run bash "$SCRIPT" --apply

    [ "$status" -eq 0 ]
    [[ "$output" == *"exposes no charge limit"* ]]
}
